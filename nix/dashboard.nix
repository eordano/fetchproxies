{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.services.fetchproxies.dashboard;
  archiverCfg = config.services.fetchproxies.archiver;
  nitterCfg = config.services.fetchproxies.nitter-mint;
  dashboardPackage = pkgs.callPackage ./dashboard-package.nix { };
in
{
  options.services.fetchproxies.dashboard = with lib; {
    enable = mkEnableOption "fetchproxies dashboard";

    port = mkOption {
      type = types.port;
      default = 8080;
      description = "Listen port";
    };

    envFile = mkOption {
      type = types.path;
      default = archiverCfg.envFile or "/var/lib/fp-secrets/db-and-s3-env";
      description = ''
        EnvironmentFile= path holding DATABASE_URL (and ignored AWS_*).
        Shares the worker's env file by default.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.fetchproxies-dashboard = {
      description = "Fetchproxies dashboard";
      after = [ "fetchproxies-schema.service" ];
      requires = [ "fetchproxies-schema.service" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        PROXY_HEALTH_PATH = config.services.fetchproxies.proxy-probe.healthPath;
        NITTER_MINT_TRIGGER = nitterCfg.triggerFile or "/var/lib/fetchproxies/nitter-mint.trigger";
        DASHBOARD_PORT = toString cfg.port;
        DASHBOARD_STATIC_DIR = "${dashboardPackage}/share/fetchproxies-dashboard/static";
        RUST_LOG = "info";
      };

      serviceConfig = {
        ExecStart = "${dashboardPackage}/bin/fetchproxies-dashboard";
        EnvironmentFile = cfg.envFile;
        User = "fetchproxies";
        Group = "fetchproxies";
        SupplementaryGroups = [ "systemd-journal" ];
        Restart = "always";
        RestartSec = 5;
        ReadWritePaths = [ "/var/lib/fetchproxies" ];
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };
  };
}
