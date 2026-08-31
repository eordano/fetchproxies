{
  config,
  lib,
  pkgs,
  colmenaBasePath,
  ...
}:
let
  cfg = config.services.fetchproxies.invidious;
in
{
  options.services.fetchproxies.invidious = with lib; {
    enable = mkEnableOption "Invidious YouTube frontend behind the fetchproxies proxy chain";

    port = mkOption {
      type = types.port;
      default = 1316;
      description = "TCP port invidious listens on.";
    };

    companionPort = mkOption {
      type = types.port;
      default = 8282;
      description = "TCP port for invidious-companion sidecar.";
    };

    domain = mkOption {
      type = types.str;
      default = "youtube.example.com";
      description = "Public hostname for invidious.";
    };

    proxyChainPort = mkOption {
      type = types.port;
      default = 1084;
      description = "SOCKS5 chain port for invidious traffic.";
    };

    httpBridgePort = mkOption {
      type = types.port;
      default = 1184;
      description = "HTTP-to-SOCKS bridge port for invidious + companion.";
    };

    companionKey = mkOption {
      type = types.str;
      default = "CHANGEME-dev-key";
      description = ''
        Dev-only fallback for the shared secret between invidious and
        companion. Must be exactly 16 characters (invidious-companion's
        SERVER_SECRET_KEY). Only used when companionKeyFile is absent or
        empty; real deployments populate companionKeyFile instead.
      '';
    };

    companionKeyFile = mkOption {
      type = types.str;
      default = "/var/lib/fp-secrets/invidious-companion-env";
      description = ''
        EnvironmentFile (`SERVER_SECRET_KEY=<16 chars>`, e.g. from
        `openssl rand -hex 8`) holding the real shared secret on the
        deployment host. Read at service start by both sides: the companion
        loads it as an EnvironmentFile, and an ExecStartPre renders it into
        an extraSettingsFile for invidious. The secret never enters the nix
        store or this repo.
      '';
    };

    companionUid = mkOption {
      type = types.int;
      default = 880;
      description = "UID for the invidious-companion user.";
    };

    popularChannels = mkOption {
      type = types.listOf types.str;
      default = [
        "UCeqc9aYVAZcRQq9Ey0x26AQ"
        "UCGq-a57w-aPwyi3pW7XLiHw"
        "UCPBwZWChghNODkWGWDga-tw"
        "UC8wNHsXmEuoikbwRdLeoJQg"
        "UCNv6_j9csOWXOIouOG_GZVA"
        "UCMSoRpgXRxhiSna6FkhTGeg"
        "UCeSzBq64-KiOOM9Eq_2lxIQ"
        "UCkiOutDcOG0KRLQc71Pd-Fg"
      ];
      description = "YouTube channel IDs for the popular page.";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = [
      cfg.port
      cfg.companionPort
    ];

    users.groups.invidious-companion.gid = cfg.companionUid;
    users.users.invidious-companion = {
      isSystemUser = true;
      uid = cfg.companionUid;
      group = "invidious-companion";
      home = "/var/lib/invidious-companion";
      createHome = false;
    };

    services.invidious = {
      enable = true;
      package = pkgs.invidious.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          (colmenaBasePath + "/overlays/invidious-fix-shortdescription-nil.patch")
        ];
      });
      inherit (cfg) port;
      address = "0.0.0.0";
      inherit (cfg) domain;
      nginx.enable = false;
      database.createLocally = true;
      settings = {
        https_only = true;
        external_port = 443;
        popular_enabled = true;
        popular_channels = cfg.popularChannels;
        statistics_enabled = false;
        check_tables = true;
        comments = [
          ""
          ""
        ];
        http_proxy = {
          user = "";
          password = "";
          host = "127.0.0.1";
          port = cfg.httpBridgePort;
        };
        default_user_preferences = {
          local = true;
          autoplay = false;
        };
        invidious_companion_key = cfg.companionKey;
        invidious_companion = [
          {
            private_url = "http://127.0.0.1:${toString cfg.companionPort}/companion";
            public_url = "https://${cfg.domain}/companion";
          }
        ];
      };
      extraSettingsFile = "/var/lib/invidious/companion-key.json";
    };

    systemd.services.invidious = {
      after = [
        "proxy-chain.service"
        "invidious-http-bridge.service"
        "invidious-companion.service"
      ];
      wants = [
        "proxy-chain.service"
        "invidious-http-bridge.service"
        "invidious-companion.service"
      ];
      serviceConfig.ExecStartPre =
        "+"
        + pkgs.writeShellScript "invidious-companion-key-render" ''
          set -eu
          key=""
          if [ -s ${cfg.companionKeyFile} ]; then
            key=$(set -a; . ${cfg.companionKeyFile}; printf %s "''${SERVER_SECRET_KEY:-}")
          fi
          [ -n "$key" ] || key='${cfg.companionKey}'
          umask 027
          ${pkgs.jq}/bin/jq -n --arg k "$key" '{invidious_companion_key: $k}' \
            > /var/lib/invidious/companion-key.json
          chown --reference=/var/lib/invidious /var/lib/invidious/companion-key.json
        '';
    };

    systemd.services.invidious-http-bridge = {
      description = "HTTP->SOCKS5 bridge for invidious + companion";
      after = [
        "network-online.target"
        "proxy-chain.service"
      ];
      wants = [
        "network-online.target"
        "proxy-chain.service"
      ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.gost}/bin/gost -L 'http://127.0.0.1:${toString cfg.httpBridgePort}' -F 'socks5://127.0.0.1:${toString cfg.proxyChainPort}'";
        DynamicUser = true;
        Restart = "always";
        RestartSec = 5;
      };
    };

    systemd.services.invidious-companion = {
      description = "Invidious companion -- YouTube video stream / signature sidecar";
      after = [
        "network-online.target"
        "invidious-http-bridge.service"
      ];
      wants = [
        "network-online.target"
        "invidious-http-bridge.service"
      ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        HOST = "0.0.0.0";
        PORT = toString cfg.companionPort;
        SERVER_BASE_PATH = "/companion";
        SERVER_BASE_URL = "https://${cfg.domain}/companion";
        SERVER_SECRET_KEY = cfg.companionKey;
        SERVER_VERIFY_REQUESTS = "true";
        PROXY = "http://127.0.0.1:${toString cfg.httpBridgePort}";
        HTTP_PROXY = "http://127.0.0.1:${toString cfg.httpBridgePort}";
        HTTPS_PROXY = "http://127.0.0.1:${toString cfg.httpBridgePort}";
        NO_PROXY = "127.0.0.1,localhost";
        CACHE_DIRECTORY = "/var/lib/invidious-companion";
        JOBS_YOUTUBE_SESSION_PO_TOKEN_ENABLED = "true";
        NETWORKING_FETCH_RETRY_ENABLED = "true";
        NETWORKING_FETCH_RETRY_TIMES = "5";
        NETWORKING_FETCH_RETRY_INITIAL_DEBOUNCE = "1000";
        NETWORKING_FETCH_RETRY_DEBOUNCE_MULTIPLIER = "2";
        NIX_LD = "/run/current-system/sw/share/nix-ld/lib/ld.so";
        NIX_LD_LIBRARY_PATH = "/run/current-system/sw/share/nix-ld/lib";
      };
      serviceConfig = {
        ExecStart = "${pkgs.invidious-companion}/bin/invidious-companion";
        EnvironmentFile = [
          "-/var/lib/fetchproxies/companion-overrides.env"
          "-${cfg.companionKeyFile}"
        ];
        User = "invidious-companion";
        Group = "invidious-companion";
        Restart = "always";
        RestartSec = 5;
        ProtectSystem = "strict";
        ReadWritePaths = [ "/var/lib/invidious-companion" ];
        ProtectHome = true;
        PrivateTmp = true;
        BindPaths = [ "/var/lib/invidious-companion:/var/tmp/youtubei.js" ];
        NoNewPrivileges = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        LogFilterPatterns = [
          "~Not implemented: HTMLCanvasElement"
          ''~"Not implemented: HTMLCanvasElement''
          ''~/jsdom/[^/]+/lib/jsdom/.*not-implemented\.js''
          ''~/jsdom/[^/]+/lib/jsdom/.*HTMLCanvasElement(-impl)?\.js''
          ''~deno-compile-invidious-companion/src/lib/jobs/worker\.ts:193''
        ];
      };
    };

    systemd.paths.companion-overrides-reload = {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathChanged = "/var/lib/fetchproxies/companion-overrides.env";
        Unit = "companion-overrides-reload.service";
      };
    };

    systemd.services.companion-overrides-reload = {
      description = "Restart invidious-companion when its dashboard override env changes";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.systemd}/bin/systemctl restart invidious-companion.service";
      };
    };

    programs.nix-ld.enable = true;
  };
}
