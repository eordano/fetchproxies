#!/usr/bin/env bash
set -euo pipefail

DASH_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DEV_DIR="$DASH_DIR/dev"
SCHEMA_SQL="$DASH_DIR/../nix/schema.sql"
SEED_SQL="$DEV_DIR/seed.sql"
HEALTH_JSON="$DEV_DIR/proxy-health.json"

PG_PORT="${PG_PORT:-54329}" # avoid clashing with a system postgres
PG_DATA="${PG_DATA:-/tmp/fp-pg-data}"
PG_RUN="${PG_RUN:-/tmp/fp-pg-run}"
PG_LOG="${PG_LOG:-/tmp/fp-pg.log}"
PG_DB="${PG_DB:-fetchproxies}"
PG_USER="${PG_USER:-fetchproxies}"
DASH_PORT="${DASH_PORT:-8088}"
DATABASE_URL="postgres://${PG_USER}@127.0.0.1:${PG_PORT}/${PG_DB}"

TMP_STATE="${TMP_STATE:-/tmp/fp-dash-state}"
mkdir -p "$TMP_STATE"

is_running() {
  [[ -f "$PG_DATA/postmaster.pid" ]] &&
    pg_ctl -D "$PG_DATA" status >/dev/null 2>&1
}

cmd_up() {
  if is_running; then
    echo "postgres already running on :${PG_PORT}"
  else
    if [[ ! -d "$PG_DATA/base" ]]; then
      echo "initdb -> $PG_DATA..."
      rm -rf "$PG_DATA" "$PG_RUN"
      mkdir -p "$PG_DATA" "$PG_RUN"
      initdb -D "$PG_DATA" -U "$PG_USER" --auth=trust >/dev/null
    fi
    echo "starting postgres on :${PG_PORT}..."
    pg_ctl -D "$PG_DATA" -l "$PG_LOG" \
      -o "-p $PG_PORT -k $PG_RUN -h 127.0.0.1 -c listen_addresses=127.0.0.1" \
      start >/dev/null
  fi

  if ! psql -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -c 'SELECT 1' >/dev/null 2>&1; then
    psql -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER" -d postgres \
      -c "CREATE DATABASE $PG_DB" >/dev/null
  fi

  echo "applying schema.sql..."
  psql -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
    -v ON_ERROR_STOP=1 -q -f "$SCHEMA_SQL" >/dev/null

  cmd_seed
  echo "ready: DATABASE_URL=$DATABASE_URL"
}

cmd_seed() {
  echo "applying seed.sql..."
  psql -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
    -v ON_ERROR_STOP=1 -q -f "$SEED_SQL" >/dev/null
}

cmd_psql() {
  psql -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" "$@"
}

cmd_logs() {
  tail -F "$PG_LOG"
}

cmd_down() {
  if is_running; then
    pg_ctl -D "$PG_DATA" stop >/dev/null
    echo "stopped postgres"
  else
    echo "postgres not running"
  fi
}

cmd_run() {
  cd "$DASH_DIR"
  export DATABASE_URL
  export DASHBOARD_STATIC_DIR="$DASH_DIR/static"
  export DASHBOARD_PORT="$DASH_PORT"
  export PROXY_HEALTH_PATH="$HEALTH_JSON"
  export NITTER_MINT_TRIGGER="$TMP_STATE/nitter-mint.trigger"
  export COMPANION_OVERRIDES_PATH="$TMP_STATE/companion-overrides.env"
  export NITTER_BRIDGE_ENV_PATH="$TMP_STATE/nitter-bridge.env"
  export JOURNAL_WATCHER_DISABLE=1
  export JOURNAL_COMMAND="$DEV_DIR/fake-journal.sh"
  export RUST_LOG="${RUST_LOG:-fetchproxies_dashboard=debug,tower_http=info}"
  echo "-> http://localhost:${DASH_PORT}"
  echo "  static  : $DASHBOARD_STATIC_DIR"
  echo "  db      : $DATABASE_URL"
  echo "  health  : $PROXY_HEALTH_PATH"
  echo "  journal : $JOURNAL_COMMAND"
  echo "  state   : $TMP_STATE/"
  exec cargo run
}

case "${1:-}" in
  up) cmd_up ;;
  seed) cmd_seed ;;
  run) cmd_run ;;
  psql)
    shift
    cmd_psql "$@"
    ;;
  logs) cmd_logs ;;
  down) cmd_down ;;
  *)
    sed -n '2,21p' "${BASH_SOURCE[0]}"
    exit 1
    ;;
esac
