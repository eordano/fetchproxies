{
  config,
  lib,
  pkgs,
  colmenaBasePath,
  ...
}:

let
  cfg = config.services.fetchproxies.nitter-mint;
  archiverCfg = config.services.fetchproxies.archiver;

  localEnvFile = "/var/lib/fetchproxies/.nitter-env";
  localBrightDataEnvFile = "/var/lib/fetchproxies/.brightdata-env";

  nitter-cookie-mint =
    let
      pyEnv = pkgs.python3.withPackages (
        ps: with ps; [
          pyotp
          playwright
        ]
      );
    in
    pkgs.writeShellApplication {
      name = "nitter-cookie-mint";
      runtimeInputs = [
        pyEnv
        pkgs.coreutils
      ];
      text = ''
        export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
        exec python3 ${colmenaBasePath + "/bin/nitter-cookie-mint.py"}
      '';
    };

  mintScript = pkgs.writeShellApplication {
    name = "nitter-mint";
    runtimeInputs = with pkgs; [
      postgresql
      coreutils
      nitter-cookie-mint
    ];
    excludeShellChecks = [ "SC1090" ];
    text = ''
      set -euo pipefail

      ENV_FILE=${lib.escapeShellArg localEnvFile}
      BRIGHTDATA_ENV_FILE=${lib.escapeShellArg localBrightDataEnvFile}
      SESSIONS_FILE=${lib.escapeShellArg cfg.sessionsFile}
      COOLDOWN=${toString cfg.cooldownSeconds}

      : "''${DATABASE_URL:?DATABASE_URL must be set in env-file}"

      log() { echo "nitter-mint: $*" >&2; }
      sql() { psql -X -P pager=off -A -t --no-psqlrc -v ON_ERROR_STOP=1 "$DATABASE_URL" "$@"; }

      sqlesc() { printf '%s' "$1" | sed "s/'/'''/g"; }

      if [ -r "$ENV_FILE" ]; then
        env_hash=$(sha256sum "$ENV_FILE" | cut -d' ' -f1)
      else
        env_hash=""
      fi

      decision=$(sql -c "SELECT env_decision FROM nitter_creds_override WHERE id=1;" 2>/dev/null || true)
      src="env"
      if [ "$decision" = "use_override" ]; then
        src="override"
      fi

      force=0
      if [ -e /run/nitter-mint/force ]; then
        force=1
        rm -f /run/nitter-mint/force
      fi

      now_ts=$(date +%s)
      last_ok=$(sql -c "SELECT COALESCE(EXTRACT(EPOCH FROM last_success_at)::bigint, 0) FROM nitter_mint_status WHERE id=1;" 2>/dev/null || echo 0)
      age=$(( now_ts - last_ok ))

      if [ "$force" = "0" ] && [ "$age" -lt "$COOLDOWN" ] && [ -s "$SESSIONS_FILE" ]; then
        log "within ''${age}s of last success (<''${COOLDOWN}s cooldown); skipping"
        exit 0
      fi

      src_esc=$(sqlesc "$src")
      hash_esc=$(sqlesc "$env_hash")
      sql -c "INSERT INTO nitter_mint_status (id, last_attempt_at, last_source, last_env_hash, updated_at)
           VALUES (1, (now() AT TIME ZONE 'UTC'), '$src_esc', '$hash_esc', (now() AT TIME ZONE 'UTC'))
           ON CONFLICT(id) DO UPDATE SET
             last_attempt_at = EXCLUDED.last_attempt_at,
             last_source     = EXCLUDED.last_source,
             last_env_hash   = EXCLUDED.last_env_hash,
             updated_at      = EXCLUDED.updated_at;"

      tmp=$(mktemp)
      trap 'rm -f "$tmp"' EXIT

      if [ "$src" = "override" ]; then
        username=$(sql -c "SELECT COALESCE(username,''') FROM nitter_creds_override WHERE id=1;")
        password=$(sql -c "SELECT COALESCE(password,''') FROM nitter_creds_override WHERE id=1;")
        totp=$(sql -c "SELECT COALESCE(totp_secret,''') FROM nitter_creds_override WHERE id=1;")
        ( set -a
          if [ -r "$BRIGHTDATA_ENV_FILE" ]; then
            . "$BRIGHTDATA_ENV_FILE"
          fi
          set +a
          USERNAME="$username" PASSWORD="$password" TOTP_SECRET="$totp" \
            nitter-cookie-mint > "$tmp" 2>/tmp/nitter-mint-err
        ) && outcome=ok || outcome=fail
      else
        if [ ! -r "$ENV_FILE" ]; then
          err="no env file at $ENV_FILE and no dashboard override"
          log "$err"
          esc=$(sqlesc "$err")
          sql -c "UPDATE nitter_mint_status SET last_error='$esc', updated_at=(now() AT TIME ZONE 'UTC') WHERE id=1;"
          exit 1
        fi
        ( set -a
          . "$ENV_FILE"
          if [ -r "$BRIGHTDATA_ENV_FILE" ]; then
            . "$BRIGHTDATA_ENV_FILE"
          fi
          set +a
          nitter-cookie-mint > "$tmp" 2>/tmp/nitter-mint-err
        ) && outcome=ok || outcome=fail
      fi

      if [ "$outcome" = "ok" ]; then
        staged="''${SESSIONS_FILE}.new"
        install -m 0400 "$tmp" "$staged"
        mv -f "$staged" "$SESSIONS_FILE"
        sql -c "UPDATE nitter_mint_status SET
               last_success_at = (now() AT TIME ZONE 'UTC'),
               last_error      = NULL,
               updated_at      = (now() AT TIME ZONE 'UTC')
             WHERE id=1;"
        if [ "$src" = "env" ] && [ -n "$decision" ] && [ -n "$env_hash" ]; then
          hash_esc=$(sqlesc "$env_hash")
          sql -c "UPDATE nitter_creds_override SET
                 env_hash_seen = '$hash_esc',
                 updated_at    = (now() AT TIME ZONE 'UTC')
               WHERE id=1;"
        fi
        log "minted fresh session (source=$src)"
      else
        err=$(head -c 500 /tmp/nitter-mint-err | tr '\n' ' ')
        err_esc=$(sqlesc "$err")
        sql -c "UPDATE nitter_mint_status SET
               last_error = '$err_esc',
               updated_at = (now() AT TIME ZONE 'UTC')
             WHERE id=1;"
        log "nitter-oauth-create failed: $err"
        exit 1
      fi
    '';
  };
in
{
  options.services.fetchproxies.nitter-mint = with lib; {
    enable = mkEnableOption "Nitter session mint service";

    sessionsFile = mkOption {
      type = types.path;
      default = "/srv/archive/config/nitter-sessions.jsonl";
      description = ''
        Where the minted sessions JSONL is written. Default lives under
        the archive virtiofs share's `config/` dir (=
        the host-side archive dataset's config/), so cookies survive VM
        rebuilds without a separate secret. Seed manually by writing
        this file on the host (owner fetchproxies uid, mode 0400).
        Nitter's ExecStartPre reads it via install(8) as root and
        stages into its RuntimeDirectory.
      '';
    };

    envFile = mkOption {
      type = types.path;
      default = "/var/lib/fp-secrets/nitter-session-login-env";
      description = ''
        Shell-sourcable file with USERNAME / PASSWORD / TOTP_SECRET / EMAIL.
        Staged into the guest from the host-decrypted agenix secret.
      '';
    };

    brightDataEnvFile = mkOption {
      type = types.path;
      default = "/var/lib/fp-secrets/brightdata-env";
      description = ''
        Shell-sourcable file with BRIGHTDATA_BROWSER_WS=wss://...
        pointing at Bright Data's Scraping Browser endpoint. Sourced
        alongside envFile at mint time.
      '';
    };

    triggerFile = mkOption {
      type = types.path;
      default = "/var/lib/fetchproxies/nitter-mint.trigger";
      description = ''
        Presence of this file forces a mint attempt bypassing the cooldown.
        The dashboard (running as the fetchproxies user, which owns
        /var/lib/fetchproxies) touches it to request a retry.
      '';
    };

    cooldownSeconds = mkOption {
      type = types.int;
      default = 24 * 3600;
      description = "Seconds since the last successful mint before the timer-driven refresh is allowed to retry.";
    };

    proxySocks = mkOption {
      type = types.str;
      default = archiverCfg.proxySocks or "socks5://127.0.0.1:1083";
      description = ''
        SOCKS5 proxy to use for the Twitter login flow. Defaults to the
        archiver's chain, which egresses via a Mullvad relay.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.nitter-mint = {
      description = "Mint a fresh Nitter Twitter session";
      after = [ "fetchproxies-schema.service" ];
      requires = [ "fetchproxies-schema.service" ];

      serviceConfig = {
        Type = "oneshot";
        User = "fetchproxies";
        Group = "fetchproxies";
        EnvironmentFile = archiverCfg.envFile or "/var/lib/fp-secrets/db-and-s3-env";
        RuntimeDirectory = "nitter-mint";
        RuntimeDirectoryMode = "0750";
        ExecStartPre =
          "+"
          + (pkgs.writeShellScript "nitter-mint-pre" ''
            set -eu

            if [ -e ${lib.escapeShellArg cfg.triggerFile} ]; then
              rm -f ${lib.escapeShellArg cfg.triggerFile}
              echo 1 > /run/nitter-mint/force
            fi

            if [ -r ${lib.escapeShellArg cfg.envFile} ]; then
              install -m 0400 -o fetchproxies -g fetchproxies \
                ${lib.escapeShellArg cfg.envFile} \
                ${lib.escapeShellArg localEnvFile}
            else
              rm -f ${lib.escapeShellArg localEnvFile}
            fi

            if [ -r ${lib.escapeShellArg cfg.brightDataEnvFile} ]; then
              install -m 0400 -o fetchproxies -g fetchproxies \
                ${lib.escapeShellArg cfg.brightDataEnvFile} \
                ${lib.escapeShellArg localBrightDataEnvFile}
            else
              rm -f ${lib.escapeShellArg localBrightDataEnvFile}
            fi
          '');
        ExecStart = "${mintScript}/bin/nitter-mint";
        ProtectSystem = "strict";
        ReadWritePaths = [
          "/var/lib/fetchproxies"
          (builtins.dirOf cfg.sessionsFile)
          (builtins.dirOf cfg.triggerFile)
          "/tmp"
        ];
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };

    systemd.paths.nitter-mint-trigger = {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathExists = cfg.triggerFile;
        Unit = "nitter-mint.service";
      };
    };

    systemd.timers.nitter-mint = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "24h";
        Unit = "nitter-mint.service";
      };
    };
  };
}
