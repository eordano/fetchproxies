{
  config,
  lib,
  colmenaBasePath,
  ...
}:
let
  cfg = config.services.fetchproxies.mullvad;
in
{
  imports = [ (colmenaBasePath + "/projects/recipes/modules/wireguard-per-uid-exits") ];

  options.services.fetchproxies.mullvad = with lib; {
    enable = mkEnableOption "Mullvad WireGuard backends for the fetchproxies proxy chain";

    locations = mkOption {
      default = { };
      description = ''
        Named Mullvad locations.  Each creates a WireGuard interface
        wg-<name> and a SOCKS5 relay on the chosen port.  Reference the
        relay from `services.fetchproxies.proxy-chain.backends` as a
        `socks` backend with `upstream = "127.0.0.1:<socksPort>"`.
      '';
      type = types.attrsOf (
        types.submodule (_: {
          options = {
            configZipPath = mkOption {
              type = types.str;
              description = "Path to the Mullvad WireGuard config zip inside the VM (e.g. /run/credentials/mullvad-us.zip).";
            };

            selectConfigs = mkOption {
              type = types.listOf types.str;
              default = [ "*" ];
              description = "Glob patterns to filter .conf entries inside the zip. Defaults to all.";
              example = [ "us-sjc-*" ];
            };

            socksPort = mkOption {
              type = types.port;
              description = "Port the SOCKS5 relay binds to (must be unique across locations).";
            };
          };
        })
      );
    };
  };

  config = lib.mkIf (cfg.enable && cfg.locations != { }) {

    services.fetchproxies.proxy-chain.backends = lib.mapAttrs' (
      name: loc:
      lib.nameValuePair "mullvad-${name}" {
        type = "socks";
        upstream = "127.0.0.1:${toString loc.socksPort}";
      }
    ) cfg.locations;

    networking.nftables.ruleset = lib.mkAfter config.services.wireguardExits.nftRuleset;

    services.wireguardExits = {
      enable = true;
      providerLabel = "Mullvad";
      markBackend = "manual";

      naming = {
        interfacePrefix = "wg-";
        setupUnitPrefix = "mullvad-extract";
        relayUnitPrefix = "mullvad-relay";
        relayUserPrefix = "mullvad-relay";
        relayGroup = "mullvad-relay";
        runtimeDirectory = "fetchproxies/mullvad";
        nftTable = "fetchproxies-mullvad-mark";
      };

      numbering = {
        routeTableBase = 200;
        fwmarkBase = 200;
        tunnelFwmarkBase = 400;
        rulePriorityBase = 2000;
        relayUidBase = 850;
        uidRangeRulePriorityBase = 1500;
      };

      exits = lib.mapAttrs (_name: loc: {
        configBundle = {
          zipPath = loc.configZipPath;
          select = loc.selectConfigs;
        };
        allowedIPs = "0.0.0.0/0";
        mtu = 1280;
        persistentKeepalive = 25;
        trustInterface = true;
        socksRelay = {
          enable = true;
          port = loc.socksPort;
        };
      }) cfg.locations;
    };
  };
}
