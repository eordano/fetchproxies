{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fetchproxies.kiwix;
in
{
  options.services.fetchproxies.kiwix = with lib; {
    enable = mkEnableOption "Kiwix offline knowledge base";

    port = mkOption {
      type = types.port;
      default = 1323;
      description = "TCP port kiwix-serve listens on.";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/srv/kiwix";
      description = "Directory containing .zim files.";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = [ cfg.port ];

    systemd.services.kiwix = {
      description = "Kiwix -- offline knowledge base";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      script = ''
        shopt -s nullglob
        zims=( ${cfg.dataDir}/*.zim )
        if [ ''${#zims[@]} -eq 0 ]; then
          echo "no .zim files in ${cfg.dataDir} -- sleeping to avoid restart storm" >&2
          sleep 3600
          exit 0
        fi
        exec ${pkgs.kiwix-tools}/bin/kiwix-serve --port ${toString cfg.port} "''${zims[@]}"
      '';
      serviceConfig = {
        DynamicUser = true;
        Restart = "always";
        RestartSec = 5;
      };
    };
  };
}
