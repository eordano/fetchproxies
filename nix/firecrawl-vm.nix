{
  config,
  lib,
  pkgs,
  containerImages,
  colmenaBasePath,
  ...
}:
let
  cfg = config.services.fetchproxies.firecrawl;

  apiPort = 3002;
  redisPort = 6378;

  socksProxy = "socks5://127.0.0.1:${toString cfg.archiverChainPort}";

  databaseUrl = "postgresql://firecrawl@127.0.0.1:5432/firecrawl";

  runtimeOpts = [
    "--runtime=runsc-host"
    "--network=host"
  ];

  nodeContainerEnvironment = {
    PROXY_SERVER = socksProxy;
    PLAYWRIGHT_MICROSERVICE_URL = lib.mkForce "http://127.0.0.1:3000";
    DATABASE_URL = databaseUrl;
    NUQ_DATABASE_URL = databaseUrl;
    NODE_OPTIONS = "--require /app/firecrawl-cpu-fix.js";
  };

  cpuFixVolumes = [ "${./firecrawl-cpu-fix.js}:/app/firecrawl-cpu-fix.js:ro" ];
in
{
  imports = [ (colmenaBasePath + "/modules/services/firecrawl.nix") ];

  options.services.fetchproxies.firecrawl = {
    enable = lib.mkEnableOption "firecrawl inside the fetchproxies VM";
    archiverChainPort = lib.mkOption {
      type = lib.types.port;
      default = 1083;
      description = "Local SOCKS5 chain port routing to Mullvad backends.";
    };
  };

  config = lib.mkIf cfg.enable {
    modules.services.firecrawl = {
      enable = true;
      domain = null;
      acmeHost = null;
      dataDir = "/var/lib/firecrawl";
      useDbAuthentication = false;
      numWorkersPerQueue = 4;
      redisUrl = "redis://127.0.0.1:${toString redisPort}";
      initSchema = true;
      databaseName = "firecrawl";
    };

    services.redis.servers."firecrawl" = {
      port = lib.mkForce redisPort;
      bind = lib.mkForce "127.0.0.1";
    };

    services.postgresql = {
      ensureDatabases = [ "firecrawl" ];
      ensureUsers = [
        {
          name = "firecrawl";
          ensureDBOwnership = true;
        }
      ];
      authentication = lib.mkAfter ''
        host firecrawl firecrawl 127.0.0.1/32 trust
      '';
      extensions = ps: [ ps.pg_cron ];
      settings = {
        shared_preload_libraries = "pg_cron";
        "cron.database_name" = "firecrawl";
      };
    };

    virtualisation.oci-containers.backend = lib.mkForce "podman";

    virtualisation.oci-containers.containers = {
      firecrawl-playwright = {
        environment = {
          PROXY_SERVER = socksProxy;
          BLOCK_MEDIA = "true";
        };
        ports = lib.mkForce [ ];
        extraOptions = runtimeOpts;
      };
      firecrawl-api = {
        environment = nodeContainerEnvironment;
        volumes = cpuFixVolumes;
        ports = lib.mkForce [ ];
        extraOptions = runtimeOpts;
      };
      firecrawl-worker = {
        environment = nodeContainerEnvironment // {
          PGUSER = "firecrawl";
          PGHOST = "127.0.0.1";
          PGPORT = "5432";
          PGDATABASE = "firecrawl";
        };
        volumes = cpuFixVolumes;
        extraOptions = runtimeOpts;
      };
    };

    systemd.services = lib.listToAttrs (
      map
        (
          role:
          lib.nameValuePair "podman-firecrawl-${role}" {
            after = [ "postgresql.service" ];
            requires = [ "postgresql.service" ];
          }
        )
        [
          "api"
          "worker"
        ]
    );

    networking.firewall.allowedTCPPorts = [ apiPort ];
  };
}
