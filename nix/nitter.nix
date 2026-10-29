{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fetchproxies.nitter;
in
{
  options.services.fetchproxies.nitter = with lib; {
    enable = mkEnableOption "Nitter Twitter frontend behind the fetchproxies proxy chain";

    port = mkOption {
      type = types.port;
      default = 1314;
      description = "TCP port nitter listens on.";
    };

    domain = mkOption {
      type = types.str;
      default = "twitter.example.com";
      description = "Public hostname shown in nitter config.";
    };

    theme = mkOption {
      type = types.str;
      default = "Nitter";
      description = "Default UI theme; must be one the nitter build ships.";
    };

    proxyChainPort = mkOption {
      type = types.port;
      default = 1081;
      description = "SOCKS5 chain port for nitter traffic.";
    };

    httpBridgePort = mkOption {
      type = types.port;
      default = 1180;
      description = "HTTP-to-SOCKS bridge port (Nim httpclient is HTTP-only).";
    };

    sessionsFile = mkOption {
      type = types.path;
      default = "/srv/archive/config/nitter-sessions.jsonl";
      description = "Path to minted Twitter session cookies.";
    };

    oauthEnvFile = mkOption {
      type = types.path;
      default = "/var/lib/fp-secrets/nitter-oauth-env";
      description = "EnvironmentFile with nitter OAuth tokens.";
    };

    hmacKey = mkOption {
      type = types.str;
      default = "CHANGE-ME-dev-only";
      description = ''
        Dev-only fallback for the key nitter uses to sign proxied media URLs
        and preference tokens. Only used when hmacKeyFile is absent or empty;
        real deployments populate hmacKeyFile instead.
      '';
    };

    hmacKeyFile = mkOption {
      type = types.str;
      default = "/var/lib/fp-secrets/nitter-hmac-key";
      description = ''
        File holding the real hmac key on the deployment host (one line,
        e.g. from `openssl rand -hex 16`). Substituted into the rendered
        nitter.conf at service start, so the secret never enters the nix
        store or this repo.
      '';
    };

    uid = mkOption {
      type = types.int;
      default = 882;
      description = "UID for the nitter user.";
    };

    httpBridgeUid = mkOption {
      type = types.int;
      default = 881;
      description = "UID for the nitter-http-bridge user.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.nitter.gid = cfg.uid;
    users.users.nitter = {
      isSystemUser = true;
      inherit (cfg) uid;
      group = "nitter";
    };

    users.groups.nitter-http-bridge.gid = cfg.httpBridgeUid;
    users.users.nitter-http-bridge = {
      isSystemUser = true;
      uid = cfg.httpBridgeUid;
      group = "nitter-http-bridge";
    };

    networking.firewall.allowedTCPPorts = [ cfg.port ];

    environment.etc."nitter.conf".text = ''
      [Server]
      hostname = "${cfg.domain}"
      address = "0.0.0.0"
      port = ${toString cfg.port}
      staticDir = "${pkgs.nitter}/share/nitter/public"

      [Config]
      hmacKey = "@HMAC_KEY@"
      authFile = "/var/lib/nitter/auth.jsonl"
      proxy = "http://127.0.0.1:${toString cfg.httpBridgePort}"
      proxyAuth = ""

      [Cache]
      listMinutes = 240
      rssMinutes = 10
      redisHost = "127.0.0.1"
      redisPort = 6379
      redisPassword = ""
      redisConnections = 20
      redisMaxConnections = 30

      [Preferences]
      theme = "${cfg.theme}"
    '';

    services.redis.servers.nitter = {
      enable = true;
      port = 6379;
      bind = "127.0.0.1";
    };

    systemd.services.nitter =
      let
        runDir = "/run/nitter";
        nitter-lr = pkgs.nitter;
      in
      {
        description = "Nitter -- Twitter frontend";
        after = [
          "network.target"
          "proxy-chain.service"
          "redis-nitter.service"
          "var-lib-fp\\x2dsecrets.mount"
        ];
        wants = [
          "proxy-chain.service"
          "redis-nitter.service"
        ];
        wantedBy = [ "multi-user.target" ];
        unitConfig.ConditionFileNotEmpty = cfg.sessionsFile;
        serviceConfig = {
          User = "nitter";
          Group = "nitter";
          RuntimeDirectory = "nitter";
          RuntimeDirectoryMode = "0750";
          WorkingDirectory = runDir;
          EnvironmentFile = cfg.oauthEnvFile;
          ExecStartPre =
            "+"
            + pkgs.writeShellScript "nitter-stage" ''
              set -eu
              if [ -s ${cfg.hmacKeyFile} ]; then
                hmac=$(cat ${cfg.hmacKeyFile})
              else
                hmac='${cfg.hmacKey}'
              fi
              sed "s|@HMAC_KEY@|$hmac|" /etc/nitter.conf > ${runDir}/nitter.conf
              chown --reference=${runDir} ${runDir}/nitter.conf
              chmod 0640 ${runDir}/nitter.conf
              ln -sfn ${nitter-lr}/share/nitter/public ${runDir}/public
              install -m 0640 ${cfg.sessionsFile} ${runDir}/sessions.jsonl
              chown --reference=${runDir} ${runDir}/sessions.jsonl
            '';
          ExecStart = "${nitter-lr}/bin/nitter";
          Restart = "always";
          RestartSec = 5;
        };
      };

    systemd.services.nitter-http-bridge = {
      description = "HTTP->SOCKS5 bridge for nitter (Nim httpclient is HTTP-only)";
      after = [
        "network-online.target"
        "proxy-chain.service"
      ];
      wants = [
        "network-online.target"
        "proxy-chain.service"
      ];
      wantedBy = [ "multi-user.target" ];
      environment.FORWARDER = "socks5://127.0.0.1:${toString cfg.proxyChainPort}";
      serviceConfig = {
        EnvironmentFile = "-/var/lib/fetchproxies/nitter-bridge.env";
        ExecStart = pkgs.writeShellScript "nitter-http-bridge-launcher" ''
          if [ -n "''${FORWARDER:-}" ]; then
            exec ${pkgs.gost}/bin/gost -L 'http://127.0.0.1:${toString cfg.httpBridgePort}' -F "$FORWARDER"
          else
            exec ${pkgs.gost}/bin/gost -L 'http://127.0.0.1:${toString cfg.httpBridgePort}'
          fi
        '';
        User = "nitter-http-bridge";
        Group = "nitter-http-bridge";
        Restart = "always";
        RestartSec = 5;
      };
    };

    systemd.paths.nitter-sessions-reload = {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathChanged = cfg.sessionsFile;
        Unit = "nitter-sessions-reload.service";
      };
    };

    systemd.services.nitter-sessions-reload = {
      description = "Restart nitter when sessions.jsonl changes on disk";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.systemd}/bin/systemctl restart nitter.service";
      };
    };

    systemd.paths.nitter-bridge-reload = {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathChanged = "/var/lib/fetchproxies/nitter-bridge.env";
        Unit = "nitter-bridge-reload.service";
      };
    };

    systemd.services.nitter-bridge-reload = {
      description = "Restart nitter-http-bridge when its forwarder choice changes";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.systemd}/bin/systemctl restart nitter-http-bridge.service";
      };
    };
  };
}
