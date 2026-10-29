{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.services.fetchproxies.archiver;

  workerScript = pkgs.writeShellApplication {
    name = "fetchproxies-worker";
    runtimeInputs = with pkgs; [
      postgresql
      awscli2
      podman
      coreutils
      findutils
      gawk
    ];
    text = builtins.readFile ./worker.sh;
  };

  workerImageStream = import ./worker-image.nix { inherit pkgs; };
in
{
  options.services.fetchproxies.archiver = with lib; {
    enable = mkEnableOption "fetchproxies archiver";

    workerCount = mkOption {
      type = types.int;
      default = 2;
      description = "Number of concurrent fetch workers";
    };

    archiveDir = mkOption {
      type = types.path;
      default = "/srv/archive";
      description = "Where to keep podman scratch space (artifacts now live in garage S3)";
    };

    proxySocks = mkOption {
      type = types.str;
      default = "socks5://127.0.0.1:1083";
      description = "Default SOCKS5 proxy for fetch workers";
    };

    publicUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "https://fetch.example.com";
      description = "Base URL the archive is browsed at (its /artifacts/results/<id>/ listings); markdown renditions link their archive under it. Null leaves the link relative.";
    };

    envFile = mkOption {
      type = types.path;
      default = "/var/lib/fp-secrets/db-and-s3-env";
      description = ''
        EnvironmentFile= path holding DATABASE_URL, AWS_*, S3_BUCKET.
        Staged by the deployment host from agenix secrets via virtiofs.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.fetchproxies = {
      isSystemUser = true;
      uid = 999;
      group = "fetchproxies";
      home = "/var/lib/fetchproxies";
      createHome = true;
      subUidRanges = [
        {
          startUid = 200000;
          count = 65536;
        }
      ];
      subGidRanges = [
        {
          startGid = 200000;
          count = 65536;
        }
      ];
    };
    users.groups.fetchproxies = {
      gid = 999;
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/fetchproxies 0755 fetchproxies fetchproxies -"
      "d ${cfg.archiveDir} 0755 fetchproxies fetchproxies -"
      "d ${cfg.archiveDir}/podman-tmp 0700 fetchproxies fetchproxies -"
      "d /run/user/999 0700 fetchproxies fetchproxies -"
    ];

    systemd.services = lib.mkMerge [
      {
        fetchproxies-user-linger = {
          description = "Enable systemd linger for fetchproxies (rootless podman)";
          wantedBy = [ "multi-user.target" ];
          before = [
            "fetchproxies-worker-image.service"
            "user@999.service"
          ];
          after = [ "systemd-logind.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            ${pkgs.systemd}/bin/loginctl enable-linger fetchproxies || true
          '';
        };

        fetchproxies-schema = {
          description = "Initialise fetchproxies postgres schema";
          wantedBy = [ "multi-user.target" ];
          after = [
            "network-online.target"
            "postgresql.service"
          ];
          wants = [
            "network-online.target"
            "postgresql.service"
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "fetchproxies";
            Group = "fetchproxies";
            EnvironmentFile = cfg.envFile;
          };
          path = [ pkgs.postgresql ];
          script = ''
            set -u
            for _ in $(seq 1 60); do
              if psql -X --no-psqlrc -v ON_ERROR_STOP=1 \
                      --single-transaction "$DATABASE_URL" \
                      -f ${./schema.sql}; then
                exit 0
              fi
              echo "fetchproxies schema apply not ready (postgres starting/read-only), retrying..." >&2
              sleep 3
            done
            echo "fetchproxies schema apply failed after retries" >&2
            exit 1
          '';
        };

        fetchproxies-worker-image = {
          description = "Load fetchproxies-worker OCI image into podman (rootless, streamed)";
          wantedBy = [ "multi-user.target" ];
          after = [
            "network.target"
            "fetchproxies-user-linger.service"
          ];
          requires = [ "fetchproxies-user-linger.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "fetchproxies";
            Group = "fetchproxies";
            WorkingDirectory = "/var/lib/fetchproxies";
            Environment = [
              "HOME=/var/lib/fetchproxies"
              "XDG_RUNTIME_DIR=/run/user/999"
              "TMPDIR=${cfg.archiveDir}/podman-tmp"
            ];
            StandardOutput = "journal";
            StandardError = "journal";
          };
          path = [
            pkgs.podman
            "/run/wrappers"
          ];
          script = ''
            set -eu
            ${workerImageStream} | podman --log-level=info load
          '';
        };

        fetchproxies-aws-config = {
          description = "Provision ~/.aws/config for fetchproxies workers";
          wantedBy = [ "multi-user.target" ];
          before = lib.genList (i: "fetchproxies-worker-${toString i}.service") cfg.workerCount;
          after = [ "fetchproxies-user-linger.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "fetchproxies";
            Group = "fetchproxies";
          };
          script = ''
            set -eu
            install -d -m 0700 /var/lib/fetchproxies/.aws
            cat > /var/lib/fetchproxies/.aws/config <<'EOF'
            [default]
            s3 =
                addressing_style = path
            EOF
          '';
        };
      }
      (lib.listToAttrs (
        lib.genList (
          i:
          lib.nameValuePair "fetchproxies-worker-${toString i}" {
            description = "Fetchproxies archive worker ${toString i}";
            after = [
              "fetchproxies-schema.service"
              "fetchproxies-worker-image.service"
              "fetchproxies-aws-config.service"
              "proxy-chain.service"
            ];
            requires = [
              "fetchproxies-schema.service"
              "fetchproxies-worker-image.service"
              "fetchproxies-aws-config.service"
            ];
            wantedBy = [ "multi-user.target" ];

            environment = {
              PROXY_SOCKS = cfg.proxySocks;
              ARCHIVE_PUBLIC_URL = lib.optionalString (cfg.publicUrl != null) cfg.publicUrl;
              HOME = "/var/lib/fetchproxies";
              XDG_RUNTIME_DIR = "/run/user/999";
              CONTAINERS_CGROUP_MANAGER = "cgroupfs";
            };

            path = [
              "/run/wrappers"
              pkgs.passt
            ];
            serviceConfig = {
              ExecStart = "${workerScript}/bin/fetchproxies-worker";
              EnvironmentFile = cfg.envFile;
              Restart = "always";
              RestartSec = 10;
              User = "fetchproxies";
              Group = "fetchproxies";
              TasksMax = 2000;
              LimitNOFILE = 65536;
              SupplementaryGroups = [ "podman" ];
              Delegate = true;
              Slice = "user-999.slice";
              ProtectSystem = "strict";
              ReadWritePaths = [
                cfg.archiveDir
                "/var/lib/fetchproxies"
                "/tmp"
              ];
              PrivateTmp = false;
              NoNewPrivileges = true;
              ProtectHome = false;
            };
          }
        ) cfg.workerCount
      ))
    ];
  };
}
