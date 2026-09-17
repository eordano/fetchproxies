{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.fetchproxies.transmission-vpn;

  chosen = config.services.wireguardExits.slots.${cfg.backend} or null;
  backendFwmark = chosen.fwmark;
  backendWgFwmark = chosen.tunnelFwmark;
  backendTable = chosen.routeTable;
  backendSetupUnit = "${chosen.setupUnit}.service";

  nssConf = pkgs.writeText "nsswitch.conf" ''
    hosts: files dns
    networks: files
    services: files
    protocols: files
  '';

  transmissionImage = pkgs.dockerTools.buildLayeredImage {
    name = "fetchproxies-transmission";
    tag = "2";
    contents = with pkgs; [
      transmission_4
      bashInteractive
      coreutils
      cacert
      tzdata
      glibc
    ];
    fakeRootCommands = ''
      mkdir -p etc
      install -m 0644 ${nssConf} etc/nsswitch.conf
    '';
    config = {
      Entrypoint = [
        "${pkgs.transmission_4}/bin/transmission-daemon"
        "--foreground"
        "--config-dir"
        "/config"
        "--download-dir"
        "/done"
        "--incomplete-dir"
        "/downloads"
        "--logfile"
        "/dev/stderr"
      ];
      WorkingDir = "/config";
    };
  };

  defaultSettings = builtins.toJSON {
    rpc-enabled = true;
    rpc-bind-address = "0.0.0.0";
    rpc-port = cfg.webPort;
    rpc-authentication-required = false;
    rpc-whitelist-enabled = false;
    rpc-host-whitelist-enabled = false;
    peer-port = cfg.peerPort;
    peer-port-random-on-start = false;
    port-forwarding-enabled = false;
    dht-enabled = true;
    pex-enabled = true;
    lpd-enabled = false;
    utp-enabled = true;
    download-dir = "/done";
    incomplete-dir = "/downloads";
    incomplete-dir-enabled = true;
    blocklist-enabled = false;
    encryption = 2;
    start-added-torrents = true;
    rename-partial-files = true;
    ratio-limit-enabled = false;
    idle-seeding-limit-enabled = false;
    speed-limit-down-enabled = false;
    speed-limit-up-enabled = false;
    umask = 18;
  };
in
{
  options.services.fetchproxies.transmission-vpn = with lib; {
    enable = mkEnableOption "Transmission torrent daemon pinned to a Mullvad tunnel via skuid/fwmark routing";

    backend = mkOption {
      type = types.str;
      description = ''
        Mullvad location name (a key in
        `services.fetchproxies.mullvad.locations`) whose wg-<name>
        interface will carry ALL transmission traffic. Change requires
        a restart of the transmission service.
      '';
      example = "br-all";
    };

    downloadDir = mkOption {
      type = types.path;
      default = "/srv/torrents";
      description = "Host-visible directory for in-progress downloads (mounted into the container at /downloads; transmission's incomplete-dir).";
    };

    completedDir = mkOption {
      type = types.path;
      default = "/srv/done";
      description = ''
        Host-visible directory finished torrents are moved to (mounted into the
        container at /done; transmission's download-dir). Not pre-created here:
        it is an NFS-backed share owned by the media user on the file server,
        not by the transmission user.
      '';
    };

    configDir = mkOption {
      type = types.path;
      default = "/var/lib/transmission";
      description = "Host-visible directory for transmission's state (settings.json, torrents/, resume/). Mounted at /config.";
    };

    webPort = mkOption {
      type = types.port;
      default = 9091;
      description = "TCP port for the web UI / RPC.";
    };

    peerPort = mkOption {
      type = types.port;
      default = 51413;
      description = "TCP+UDP port announced to peers for incoming connections.";
    };

    user = mkOption {
      type = types.str;
      default = "transmission-vpn";
      description = "Static host user transmission runs as. Its uid is what the nft mangle chain matches.";
    };

    uid = mkOption {
      type = types.int;
      default = 870;
      description = "Numeric uid of the transmission user (nft `meta skuid` wants numeric; /etc/passwd isn't read at ruleset load).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = chosen != null;
        message = "services.fetchproxies.transmission-vpn.backend '${cfg.backend}' is not a key in services.fetchproxies.mullvad.locations. Declare the location first.";
      }
    ];

    users.groups.${cfg.user} = {
      gid = cfg.uid;
    };
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.user;
      inherit (cfg) uid;
      home = cfg.configDir;
      createHome = false;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.configDir} 0750 ${cfg.user} ${cfg.user} -"
      "d ${cfg.downloadDir} 0770 ${cfg.user} ${cfg.user} -"
    ];

    systemd.services."transmission-vpn-bootstrap" = {
      description = "Seed transmission settings.json on first boot";
      wantedBy = [ "podman-transmission.service" ];
      before = [ "podman-transmission.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -eu
        f=${cfg.configDir}/settings.json
        if [ ! -s "$f" ]; then
          install -o ${cfg.user} -g ${cfg.user} -m 0640 \
            ${pkgs.writeText "transmission-settings.json" defaultSettings} \
            "$f"
          echo "seeded $f"
        fi
      '';
    };

    virtualisation.oci-containers.backend = lib.mkDefault "podman";
    virtualisation.oci-containers.containers.transmission = {
      imageFile = transmissionImage;
      image = "fetchproxies-transmission:2";
      user = "${toString cfg.uid}:${toString cfg.uid}";
      volumes = [
        "${cfg.configDir}:/config"
        "${cfg.downloadDir}:/downloads"
        "${cfg.completedDir}:/done"
      ];
      extraOptions = [
        "--runtime=runsc-host"
        "--network=host"
      ];
    };

    networking.nftables.ruleset = lib.mkAfter ''
      table inet fetchproxies-transmission-mark {
        chain output {
          type route hook output priority mangle;
          meta skuid ${toString cfg.uid} meta mark != ${toString backendWgFwmark} meta mark set ${toString backendFwmark}
        }
      }
    '';

    services.fetchproxies.cgroup-exit.units.podman-transmission.backend = cfg.backend;

    systemd.services.podman-transmission = {
      after = [ "transmission-vpn-iprule.service" ];
      requires = [ "transmission-vpn-iprule.service" ];
    };

    systemd.services.transmission-vpn-iprule = {
      description = "Install uidrange ip rule pinning transmission-vpn traffic to ${cfg.backend}";
      wantedBy = [ "multi-user.target" ];
      after = [ backendSetupUnit ];
      requires = [ backendSetupUnit ];
      before = [ "podman-transmission.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.iproute2 ];
      script = ''
        set -eu
        while ip -4 rule del priority 1500 2>/dev/null; do :; done
        ip -4 rule add uidrange ${toString cfg.uid}-${toString cfg.uid} \
          lookup ${toString backendTable} priority 1500
      '';
    };

    networking.firewall.allowedTCPPorts = [ cfg.webPort ];
  };
}
