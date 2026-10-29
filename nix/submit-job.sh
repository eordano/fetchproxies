#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${FETCHPROXIES_URL:-https://fetch.example.com}"

usage() {
  echo "Usage: submit-job [-p profile] [-P priority] [-t tag1,tag2] <url>" >&2
  echo "" >&2
  echo "Profiles: full (default), compare, lightweight, warc_only, media, screenshots, bd_only, agent" >&2
  echo "Env:      FETCHPROXIES_URL (default: https://fetch.example.com)" >&2
  exit 1
}

PROFILE="full"
PRIORITY=0
TAGS=""

while getopts "p:P:t:h" opt; do
  case $opt in
    p) PROFILE="$OPTARG" ;;
    P) PRIORITY="$OPTARG" ;;
    t) TAGS="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))

[ $# -lt 1 ] && usage
URL="$1"

TAGS_JSON=$(printf '%s' "$TAGS" | jq -R -c 'split(",") | map(. | gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')

BODY=$(jq -n \
  --arg url "$URL" \
  --arg profile "$PROFILE" \
  --argjson priority "$PRIORITY" \
  --argjson tags "$TAGS_JSON" \
  '{url: $url, profile: $profile, priority: $priority, tags: $tags}')

curl -fsS -X POST \
  -H 'content-type: application/json' \
  -d "$BODY" \
  "$BASE_URL/api/v1/snapshots"
echo
