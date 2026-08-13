{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fetchproxies.redlib;
in
{
  options.services.fetchproxies.redlib = with lib; {
    enable = mkEnableOption "Redlib Reddit frontend behind the fetchproxies proxy chain";

    port = mkOption {
      type = types.port;
      default = 1315;
      description = "TCP port redlib listens on.";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = [ cfg.port ];

    systemd.services.redlib = {
      description = "Redlib -- Reddit frontend";
      after = [
        "network.target"
        "proxy-chain.service"
      ];
      wants = [ "proxy-chain.service" ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        REDLIB_DEFAULT_THEME = "dark";
        REDLIB_ROBOTS_DISABLE_INDEXING = "on";
      };
      serviceConfig = {
        EnvironmentFile = "-/run/proxy-chain/redlib-backends.env";
        ExecStart = "${pkgs.redlib}/bin/redlib --address 0.0.0.0 --port ${toString cfg.port}";
        DynamicUser = true;
        Restart = "always";
        RestartSec = 5;
        LimitNOFILE = 65536;
      };
    };
  };
}
