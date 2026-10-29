#!/usr/bin/env bash
set -u

emit() {
  local unit="$1" prio="$2" msg="$3"
  local ts_us
  ts_us="$(date +%s%6N 2>/dev/null || echo "$(date +%s)000000")"
  printf '{"__REALTIME_TIMESTAMP":"%s","_SYSTEMD_UNIT":"%s","PRIORITY":"%s","MESSAGE":%s}\n' \
    "$ts_us" "$unit" "$prio" \
    "$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
}

scenario_archiver_burst() {
  local relay="${RELAYS[$RANDOM % ${#RELAYS[@]}]}"
  local relay_port="${RELAY_PORT[$relay]}"
  local target="${TARGETS[$RANDOM % ${#TARGETS[@]}]}"
  local lport=$((40000 + RANDOM % 20000))
  emit "fetchproxies-worker-3.service" 6 "snapshot#47: claimed extractor=monolith pri=0"
  emit "monolith.service" 6 "snapshot#47: fetching $target"
  emit "proxy-chain-archiver.service" 6 "127.0.0.1:$lport ><  $target"
  emit "mullvad-relay-${relay}.service" 6 "127.0.0.1:$lport >--< 127.0.0.1:$relay_port"
  emit "fetchproxies-worker-3.service" 6 "snapshot#47: extractor=monolith done in 3.4s, 412 KB"
}

scenario_redlib_burst() {
  local relay="${RELAYS[$RANDOM % ${#RELAYS[@]}]}"
  local relay_port="${RELAY_PORT[$relay]}"
  local lport=$((40000 + RANDOM % 20000))
  emit "proxy-chain-redlib.service" 6 "127.0.0.1:$lport ><  www.reddit.com:443"
  emit "mullvad-relay-${relay}.service" 6 "127.0.0.1:$lport >--< 127.0.0.1:$relay_port"
  emit "proxy-chain-redlib.service" 6 "127.0.0.1:$lport ><  oauth.reddit.com:443"
  emit "mullvad-relay-${relay}.service" 6 "127.0.0.1:$lport >--< 127.0.0.1:$relay_port"
}

scenario_nitter_burst() {
  local relay="${RELAYS[$RANDOM % ${#RELAYS[@]}]}"
  local relay_port="${RELAY_PORT[$relay]}"
  local lport=$((40000 + RANDOM % 20000))
  emit "proxy-chain-nitter.service" 6 "127.0.0.1:$lport ><  api.twitter.com:443"
  emit "mullvad-relay-${relay}.service" 6 "127.0.0.1:$lport >--< 127.0.0.1:$relay_port"
}

scenario_probe_warn() {
  local stale_relay="${RELAYS[$RANDOM % ${#RELAYS[@]}]}"
  emit "fetchproxies-proxy-probe.service" 4 "${stale_relay}: stale (last_checked > 24h)"
}

scenario_probe_ok() {
  emit "fetchproxies-proxy-probe.service" 6 "all backends within latency budget"
}

scenario_brightdata() {
  local lport=$((40000 + RANDOM % 20000))
  emit "brightdata-relay.service" 6 "127.0.0.1:$lport ><  brd.superproxy.io:44445"
}

scenario_err() {
  emit "fetchproxies-worker-1.service" 3 "snapshot#48: extractor=screenshot failed: chromium timeout after 30s"
}

RELAYS=(US-SJC DE-DUS CH-ZRH AT-VIE BR-ALL US-MIA US-BOS CO-BOG)
declare -A RELAY_PORT=(
  [US - SJC]=10818 [BR - ALL]=10812 [US - MIA]=10817 [AT - VIE]=10811
  [DE - DUS]=10815 [US - BOS]=10816 [CO - BOG]=10814 [CH - ZRH]=10813
)
TARGETS=(
  "news.ycombinator.com:443"
  "www.theverge.com:443"
  "www.reddit.com:443"
  "github.com:443"
  "wikipedia.example.com:443"
  "example.com:443"
)

trap 'exit 0' INT TERM
while true; do
  r=$((RANDOM % 100))
  if ((r < 30)); then
    scenario_archiver_burst
  elif ((r < 55)); then
    scenario_redlib_burst
  elif ((r < 75)); then
    scenario_nitter_burst
  elif ((r < 80)); then
    scenario_brightdata
  elif ((r < 90)); then
    scenario_probe_ok
  elif ((r < 96)); then
    scenario_probe_warn
  else
    scenario_err
  fi
  sleep "0.$((RANDOM % 9 + 1))"
done
