{
  hostName,
  workerCount,
  archiverBackends,
  extraAuthorizedKeys ? [ ],
}:
{
  config,
  lib,
  pkgs,
  colmenaBasePath,
  ...
}:
{
  system.stateVersion = "24.11";

  security.pki.certificateFiles = [
    (colmenaBasePath + "/projects/fetchproxies/brightdata-ca.crt")
  ];
  boot.kernel.sysctl = {
    "net.ipv6.conf.all.disable_ipv6" = 1;
    "net.ipv6.conf.default.disable_ipv6" = 1;
    "net.ipv6.conf.lo.disable_ipv6" = 1;
  };

  networking = {
    inherit hostName;
    useDHCP = lib.mkForce true;
    nameservers = [ "10.0.2.3" ];
    resolvconf.enable = false;
    nftables.enable = true;
    firewall = {
      enable = true;
      checkReversePath = "loose";
      allowedTCPPorts = [
        config.services.fetchproxies.dashboard.port
        config.services.fetchproxies.proxy-chain.chains.archiver.port
        22
      ];
    };
  };

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };
  users.users.root.openssh.authorizedKeys.keys =
    (import (colmenaBasePath + "/globals/keys")).users ++ extraAuthorizedKeys;

  services.resolved.enable = false;

  environment.etc."resolv.conf".text = ''
    nameserver 10.0.2.3
    options edns0
  '';

  fileSystems."/srv/archive" = {
    device = "archive";
    fsType = "virtiofs";
  };

  fileSystems."/srv/torrents" = {
    device = "torrents";
    fsType = "virtiofs";
  };

  fileSystems."/srv/done" = {
    device = "done";
    fsType = "virtiofs";
  };

  fileSystems."/srv/kiwix" = {
    device = "kiwix";
    fsType = "virtiofs";
  };

  services.fetchproxies.proxy-probe.enable = true;

  services.fetchproxies.mullvad = {
    enable = true;
    locations = {
      ar-bue = {
        configZipPath = "/var/lib/fp-secrets/mullvad-ar-bue.zip";
        socksPort = 10810;
      };
      at-vie = {
        configZipPath = "/var/lib/fp-secrets/mullvad-at-vie.zip";
        socksPort = 10811;
      };
      br-all = {
        configZipPath = "/var/lib/fp-secrets/mullvad-br-all.zip";
        socksPort = 10812;
      };
      ch-zrh = {
        configZipPath = "/var/lib/fp-secrets/mullvad-ch-zrh.zip";
        socksPort = 10813;
      };
      co-bog = {
        configZipPath = "/var/lib/fp-secrets/mullvad-co-bog.zip";
        socksPort = 10814;
      };
      de-dus = {
        configZipPath = "/var/lib/fp-secrets/mullvad-de-dus.zip";
        socksPort = 10815;
      };
      us-bos = {
        configZipPath = "/var/lib/fp-secrets/mullvad-us-bos.zip";
        socksPort = 10816;
      };
      us-mia = {
        configZipPath = "/var/lib/fp-secrets/mullvad-us-mia.zip";
        socksPort = 10817;
      };
      us-sjc = {
        configZipPath = "/var/lib/fp-secrets/mullvad-us-sjc.zip";
        socksPort = 10818;
      };
    };
  };

  services.fetchproxies.proxy-chain = {
    enable = true;
    enableTor = false;
    allowedDnsResolvers = [
      "10.0.2.3"
      "127.0.0.1"
    ];
    allowedHostSocks = [
      {
        ip = "10.0.2.2";
        port = 10890;
      }
      {
        ip = "10.0.2.2";
        port = 15432;
      }
      {
        ip = "10.0.2.2";
        port = 3900;
      }
    ];
    allowedDirectUids = [
      880
      881
      882
    ];
    backends = {
      vpn-exit = {
        type = "socks";
        upstream = "10.0.2.2:10890";
      };
      brightdata = {
        type = "socks";
        upstream = "127.0.0.1:10819";
      };
    };
    chains = {
      nitter = {
        port = 1081;
        backends = [
          "mullvad-br-all"
          "mullvad-us-mia"
          "mullvad-us-bos"
          "mullvad-de-dus"
          "mullvad-ch-zrh"
          "mullvad-at-vie"
        ];
      };
      redlib = {
        port = 1082;
        backends = [
          "mullvad-us-bos"
          "mullvad-us-mia"
          "mullvad-us-sjc"
          "mullvad-de-dus"
          "mullvad-ch-zrh"
          "mullvad-at-vie"
        ];
      };
      invidious = {
        port = 1084;
        retries = 1;
        backends = [
          "mullvad-ar-bue"
        ];
      };
      archiver = {
        port = 1083;
        retries = 12;
        backends = archiverBackends;
      };
    };
  };

  services.fetchproxies.archiver = {
    enable = true;
    inherit workerCount;
    archiveDir = "/srv/archive";
    proxySocks = "socks5://127.0.0.1:1083";
  };

  services.fetchproxies.dashboard.enable = true;
  services.fetchproxies.nitter-mint.enable = true;
  services.fetchproxies.nitter.enable = true;
  services.fetchproxies.redlib.enable = true;
  services.fetchproxies.invidious.enable = true;
  services.postgresql.enable = true;
  services.fetchproxies.kiwix.enable = true;

  services.fetchproxies.transmission-vpn = {
    enable = true;
    backend = "us-bos";
    downloadDir = "/srv/torrents";
    completedDir = "/srv/done";
  };

  services.fetchproxies.firecrawl.enable = true;

  systemd.services.brightdata-relay = {
    description = "SOCKS5 relay through Bright Data (auth-injecting)";
    after = [
      "network-online.target"
      "var-lib-fp\\x2dsecrets.mount"
    ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      EnvironmentFile = "/var/lib/fp-secrets/brightdata-env";
      ExecStart = "${pkgs.bash}/bin/sh -c 'exec ${pkgs.gost}/bin/gost -L \"socks5://127.0.0.1:10819\" -F \"$BRIGHTDATA_PROXY_URL\"'";
      DynamicUser = true;
      Restart = "always";
      RestartSec = 5;
    };
  };

  virtualisation.podman = {
    enable = true;
    extraPackages = [ pkgs.gvisor ];
  };
  virtualisation.containers.containersConf.settings = {
    engine.runtimes.runsc = [
      "${pkgs.writeShellScript "runsc-rootless" ''exec ${pkgs.gvisor}/bin/runsc --ignore-cgroups "$@"''}"
    ];
    engine.runtimes.runsc-host = [
      "${pkgs.writeShellScript "runsc-host" ''exec ${pkgs.gvisor}/bin/runsc --ignore-cgroups --network=host "$@"''}"
    ];
  };

  environment.systemPackages = with pkgs; [
    postgresql
    awscli2
    curl
    jq
    gvisor
  ];
}
