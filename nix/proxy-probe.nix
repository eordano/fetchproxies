{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.fetchproxies.proxy-probe;
  mullvadCfg = config.services.fetchproxies.mullvad;

  locationsArg = lib.concatMapStringsSep " " (
    name:
    let
      loc = mullvadCfg.locations.${name};
    in
    "${name}:${toString loc.socksPort}"
  ) (lib.attrNames mullvadCfg.locations);

  fallbackProxy = "socks5://127.0.0.1:10819";
  unavailableProxy = "socks5://127.0.0.1:1";

  probeScript = pkgs.writeShellApplication {
    name = "fetchproxies-proxy-probe";
    runtimeInputs = with pkgs; [
      curl
      jq
      coreutils
      systemd
    ];
    text = ''
      set -uo pipefail

      probe_url="''${1:-${cfg.probeUrl}}"
      shift || true

      health='${cfg.healthPath}'
      env_file=/run/proxy-chain/redlib-backends.env
      archiver_env_file=/run/proxy-chain/archiver-forwarder.env
      now=$(date -u +%FT%TZ)

      install -d -m 0755 /run/proxy-chain
      install -d -m 0750 -o fetchproxies -g fetchproxies "$(dirname "$health")"

      results='{}'
      for spec in "$@" brightdata:10819; do
        IFS=':' read -r name socks_port <<< "$spec"

        t0=$(date +%s%N)
        code=$(curl -sS -m 15 --location --max-redirs 3 \
          -x "socks5h://127.0.0.1:''${socks_port}" \
          "$probe_url" -o /dev/null -w '%{http_code}' 2>/dev/null) \
          || code=""
        t1=$(date +%s%N)
        latency_ms=$(( (t1 - t0) / 1000000 ))

        if [ -z "$code" ] || [ "$code" = "000" ] || [ "$code" = "0" ]; then
          status=timeout
          http_code_json=null
          latency_ms=null
        elif [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
          status=ok
          http_code_json="$code"
        else
          status=blocked
          http_code_json="$code"
        fi

        results=$(printf '%s' "$results" | jq \
          --arg n "$name" --arg p "$socks_port" --arg s "$status" \
          --arg c "$http_code_json" --arg l "$latency_ms" --arg t "$now" \
          '. + { ($n): {
            port: ($p | tonumber),
            status: $s,
            http_code: (if $c == "null" then null else ($c | tonumber) end),
            latency_ms: (if $l == "null" then null else ($l | tonumber) end),
            checked_at: $t
          } }')
      done

      printf '%s' "$results" \
        | jq --arg t "$now" --arg url "$probe_url" \
            '{checked_at: $t, target_url: $url, backends: .}' \
        > "$health.tmp"

      ports=$(jq -r '.backends | to_entries
        | map(select(.key != "brightdata" and .value.status == "ok"))
        | sort_by(.value.latency_ms // 9.9e9)
        | map(.value.port) | join(",")' "$health.tmp")

      chown fetchproxies:fetchproxies "$health.tmp" 2>/dev/null || true
      chmod 0644 "$health.tmp"
      mv "$health.tmp" "$health"

      brightdata_ok=$(jq -r '.backends.brightdata.status == "ok"' "$health")
      if [ -z "$ports" ]; then
        if [ "$brightdata_ok" = true ]; then
          all_proxy='${fallbackProxy}'
        else
          all_proxy='${unavailableProxy}'
        fi
      else
        all_proxy=$(printf '%s' "$ports" | tr ',' '\n' \
          | sed 's|^|socks5://127.0.0.1:|' | paste -sd, -)
      fi

      new_env="ALL_PROXY=$all_proxy"
      old_env=$(cat "$env_file" 2>/dev/null || true)
      if [ "$new_env" != "$old_env" ]; then
        printf '%s\n' "$new_env" > "$env_file.tmp"
        mv "$env_file.tmp" "$env_file"
        systemctl --no-block try-restart redlib.service || true
      fi

      archiver_ports="$ports"
      if [ -z "$archiver_ports" ] && [ "$brightdata_ok" = true ]; then
        archiver_ports=10819
      fi
      new_archiver_env=""
      if [ -n "$archiver_ports" ]; then
        archiver_nodes=$(printf '%s' "$archiver_ports" | tr ',' '\n' \
          | sed 's|^|127.0.0.1:|' | paste -sd, -)
        new_archiver_env="PROXY_CHAIN_FORWARDER=socks5://$archiver_nodes?strategy=fifo&maxFails=1&failTimeout=30s"
      fi
      old_archiver_env=$(cat "$archiver_env_file" 2>/dev/null || true)
      if [ "$new_archiver_env" != "$old_archiver_env" ]; then
        if [ -n "$new_archiver_env" ]; then
          printf '%s\n' "$new_archiver_env" > "$archiver_env_file.tmp"
          mv "$archiver_env_file.tmp" "$archiver_env_file"
        else
          rm -f "$archiver_env_file"
        fi
        systemctl --no-block try-restart proxy-chain-archiver.service || true
      fi
    '';
  };
in
{
  options.services.fetchproxies.proxy-probe = {
    enable = lib.mkEnableOption "HTTP-aware Mullvad SOCKS backend probe";
    probeUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://www.reddit.com/r/programming/";
      description = ''
        URL fetched through each SOCKS backend to check connectivity.
        A 2xx final response means the tunnel is live and unblocked.
      '';
    };
    healthPath = lib.mkOption {
      type = lib.types.str;
      default = "/srv/archive/config/proxy-health.json";
      description = ''
        Where to persist the health snapshot. Defaults to a path under
        /srv/archive/config (virtiofs-shared from the host) so the file
        survives microvm restarts; the dashboard's PROXY_HEALTH_PATH
        follows this option automatically.
      '';
    };
    interval = lib.mkOption {
      type = lib.types.str;
      default = "1h";
      description = ''
        Probe interval (passed to systemd OnUnitActiveSec). Every backend
        is checked on each run so a previously healthy tunnel can fail.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.settings."10-fetchproxies-redlib-fallback"."/run/proxy-chain/redlib-backends.env"."f" =
      {
        mode = "0644";
        argument = "ALL_PROXY=${unavailableProxy}";
      };

    systemd.services.fetchproxies-proxy-probe = {
      description = "Probe Mullvad SOCKS backends for HTTP-level health";
      after = [ "proxy-chain.service" ];
      wants = [ "proxy-chain.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${probeScript}/bin/fetchproxies-proxy-probe '${cfg.probeUrl}' ${locationsArg}";
      };
    };

    systemd.timers.fetchproxies-proxy-probe = {
      description = "Periodic Mullvad SOCKS backend probe";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "60s";
        OnUnitActiveSec = cfg.interval;
        AccuracySec = "10s";
      };
    };
  };
}
