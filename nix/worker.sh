#!/usr/bin/env bash
set -euo pipefail

WORKER_ID="worker-$(uname -n)-$$"
PROXY_SOCKS="${PROXY_SOCKS:-socks5://127.0.0.1:1083}"
CONTAINER_PROXY="socks5://10.0.2.2:1083"

: "${DATABASE_URL:?DATABASE_URL must be set (postgres URI)}"
: "${AWS_ENDPOINT_URL:?AWS_ENDPOINT_URL must be set (garage S3 endpoint)}"
: "${S3_BUCKET:?S3_BUCKET must be set}"

log() { echo "$(date -Iseconds) [$WORKER_ID] $*" >&2; }

sql() {
  psql -X -P pager=off -A -t -F '|' --no-psqlrc -v ON_ERROR_STOP=1 "$DATABASE_URL" "$@"
}

sqlesc() { printf '%s' "$1" | sed "s/'/''/g"; }

s3_cp_recursive() {
  aws --endpoint-url "$AWS_ENDPOINT_URL" \
    s3 cp --recursive --quiet "$1" "$2"
}

gen_index() {
  local workdir="$1" result_id="$2"
  {
    echo '<!doctype html><html><head><meta charset="utf-8">'
    echo "<title>Result $result_id -- fetchproxies</title>"
    echo '<style>'
    echo '*,*::before,*::after{box-sizing:border-box}'
    echo 'html,body{margin:0;padding:0}'
    echo 'body{font:14px/1.5 ui-sans-serif,system-ui,sans-serif;background:#0d0f12;color:#e6e6e6;padding:32px;max-width:1100px;margin:0 auto}'
    echo 'h1{font-size:18px;font-weight:600;letter-spacing:-0.01em;margin:0 0 16px}'
    echo 'ul{list-style:none;padding:0;margin:0;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px}'
    echo 'li{padding:4px 8px;border-bottom:1px solid #1f2329}'
    echo 'a{color:#7aa2f7;text-decoration:none}a:hover{text-decoration:underline}'
    echo '.size{color:#888;float:right}'
    echo '</style></head><body>'
    echo "<h1>Result $result_id</h1><ul>"
    (
      cd "$workdir"
      find . -type f ! -name 'index.html' -print | sort | while read -r f; do
        rel="${f#./}"
        size=$(stat -c%s "$f")
        printf '<li><a href="%s">%s</a><span class="size">%d B</span></li>\n' \
          "$rel" "$rel" "$size"
      done
    )
    echo '</ul></body></html>'
  } >"$workdir/index.html"
}

claim_job() {
  sql -c "
WITH claimed AS (
    SELECT id FROM archive_results
     WHERE state = 'pending'
     ORDER BY priority DESC, created_at ASC
     FOR UPDATE SKIP LOCKED
     LIMIT 1
)
UPDATE archive_results ar
   SET state = 'running',
       started_at = (now() AT TIME ZONE 'UTC'),
       worker_id = '$(sqlesc "$WORKER_ID")'
  FROM claimed
 WHERE ar.id = claimed.id
RETURNING ar.id,
          (SELECT url FROM snapshots WHERE id = ar.snapshot_id),
          ar.extractor,
          COALESCE(ar.proxy_chain, ''),
          ar.snapshot_id;
"
}

complete_job() {
  local result_id="$1" snapshot_id="$2" artifact_path="$3" size="$4" sha="$5"
  sql -c "
BEGIN;
UPDATE archive_results
   SET state = 'completed',
       completed_at = (now() AT TIME ZONE 'UTC')
 WHERE id = $result_id;
INSERT INTO artifacts (result_id, snapshot_id, path, size_bytes, sha256)
VALUES ($result_id, $snapshot_id, '$(sqlesc "$artifact_path")', $size, '$(sqlesc "$sha")');
COMMIT;
"
}

extract_html_title() {
  local file="$1"
  [ -f "$file" ] || {
    echo ""
    return
  }
  local raw
  raw=$(tr -d '\n\r' <"$file" |
    sed -nE 's:.*<title[^>]*>([^<]*)</title>.*:\1:p' |
    head -n1)
  [ -z "$raw" ] && {
    echo ""
    return
  }
  printf '%s' "$raw" |
    sed -e 's/&amp;/\&/g' \
      -e 's/&lt;/</g' \
      -e 's/&gt;/>/g' \
      -e 's/&quot;/"/g' \
      -e "s/&#39;/'/g" \
      -e 's/&nbsp;/ /g' |
    tr -s ' \t' ' ' |
    sed -e 's/^ *//' -e 's/ *$//'
}

set_snapshot_title_if_empty() {
  local snapshot_id="$1" title="$2"
  [ -z "$title" ] && return 0
  local title_esc
  title_esc=$(sqlesc "$title")
  sql -c "
UPDATE snapshots
   SET extracted_title = '$title_esc',
       updated_at = (now() AT TIME ZONE 'UTC')
 WHERE id = $snapshot_id
   AND (extracted_title IS NULL OR extracted_title = '');
" >/dev/null
}

extract_title_from_workdir() {
  local extractor="$1" workdir="$2"
  case "$extractor" in
    readability) extract_html_title "$workdir/readable.html" ;;
    monolith) extract_html_title "$workdir/data/page.html" ;;
    *) echo "" ;;
  esac
}

fail_job() {
  local result_id="$1" error="$2"
  local err_esc
  err_esc=$(sqlesc "$error")
  sql -c "
UPDATE archive_results
   SET state = CASE
                 WHEN retry_count < max_retries THEN 'pending'
                 ELSE 'failed'
               END,
       retry_count = retry_count + 1,
       error = '$err_esc'
 WHERE id = $result_id;
"
}

fail_job_permanent() {
  local result_id="$1" error="$2"
  local err_esc
  err_esc=$(sqlesc "$error")
  sql -c "
UPDATE archive_results
   SET state = 'failed',
       retry_count = max_retries,
       error = '$err_esc'
 WHERE id = $result_id;
"
}

run_fetch() {
  local result_id="$1" url="$2" extractor="$3" proxy_override="$4"
  local workdir="/tmp/fetch-$result_id"
  if [ -z "$extractor" ] || [ -z "$url" ]; then
    log "ERROR: empty extractor or url (extractor='$extractor' url='$url')"
    return 2
  fi
  local socks
  case "$extractor" in
    bd_*)
      socks="socks5://10.0.2.2:10819"
      ;;
    *)
      if [ -n "$proxy_override" ]; then
        socks="$proxy_override"
      else
        socks="$CONTAINER_PROXY"
      fi
      ;;
  esac

  mkdir -p "$workdir"

  local chromium_flags=(
    --headless=new
    --no-sandbox
    --disable-gpu
    --disable-dev-shm-usage
    --hide-scrollbars
    --user-data-dir=/tmp/chrome
    --virtual-time-budget=60000
    "--window-size=1920,16384"
    --default-background-color=FFFFFFFF
    "--proxy-server=$socks"
  )
  case "$extractor" in
    bd_*)
      chromium_flags+=(--ignore-certificate-errors)
      ;;
  esac

  case "$extractor" in
    wget_warc)
      # shellcheck disable=SC2016
      run_gvisor_container "$result_id" "$workdir" \
        bash -c '
                    set -euo pipefail
                    sockshostport="${1#socks5://}"
                    sockshostport="${sockshostport#socks5h://}"
                    host="${sockshostport%%:*}"
                    port="${sockshostport##*:}"
                    cat > /tmp/proxychains.conf <<EOC
strict_chain
proxy_dns
tcp_connect_time_out 8000
[ProxyList]
socks5 $host $port
EOC
                    mkdir -p /output/data
                    proxychains4 -q -f /tmp/proxychains.conf \
                        wget --warc-file=/output/archive \
                             --page-requisites --convert-links \
                             --adjust-extension --no-parent \
                             -P /output/data \
                             "$2"
                ' wget-warc-runner "$socks" "$url"
      ;;
    browsertrix)
      podman run --rm \
        --runtime=runsc \
        --network=slirp4netns:allow_host_loopback=true \
        --volume "$workdir:/crawls:rw" \
        --memory 4g \
        --cpus 2 \
        --timeout 900 \
        docker.io/webrecorder/browsertrix-crawler:latest \
        crawl --url "$url" \
        --collection "result-$result_id" \
        --workers 1 \
        --depth 0 \
        --proxyServer "$socks" \
        --generateWACZ
      ;;
    yt_dlp)
      run_gvisor_container "$result_id" "$workdir" \
        yt-dlp --proxy "$socks" \
        --output "/output/data/%(title)s.%(ext)s" \
        "$url"
      ;;
    monolith)
      # shellcheck disable=SC2016
      run_gvisor_container "$result_id" "$workdir" \
        bash -c '
                    set -euo pipefail
                    sockshostport="${1#socks5://}"
                    sockshostport="${sockshostport#socks5h://}"
                    host="${sockshostport%%:*}"
                    port="${sockshostport##*:}"
                    cat > /tmp/proxychains.conf <<EOC
strict_chain
proxy_dns
tcp_connect_time_out 8000
[ProxyList]
socks5 $host $port
EOC
                    mkdir -p /output/data
                    proxychains4 -q -f /tmp/proxychains.conf \
                        monolith "$2" --output /output/data/page.html
                ' monolith-runner "$socks" "$url"
      ;;
    screenshot | bd_screenshot | screenshot_mobile | screenshot_tablet | screenshot_desktop)
      local width
      case "$extractor" in
        screenshot_mobile) width=390 ;;
        screenshot_tablet) width=820 ;;
        screenshot_desktop) width=1440 ;;
        *) width=1920 ;;
      esac
      local cert_flag=""
      case "$extractor" in
        bd_*) cert_flag="--ignore-cert" ;;
      esac
      run_gvisor_container "$result_id" "$workdir" \
        chromium-fullpage "$url" "/output/screenshot.png" "$width" "$socks" $cert_flag
      ;;
    pdf)
      run_gvisor_container "$result_id" "$workdir" \
        chromium "${chromium_flags[@]}" \
        --print-to-pdf-no-header \
        --print-to-pdf=/output/page.pdf \
        "$url"
      ;;
    dom_dump)
      # shellcheck disable=SC2016
      run_gvisor_container "$result_id" "$workdir" \
        bash -c '
                    set -euo pipefail
                    chromium --headless=new --no-sandbox --disable-gpu \
                             --disable-dev-shm-usage --hide-scrollbars \
                             --user-data-dir=/tmp/chrome \
                             --virtual-time-budget=30000 \
                             --proxy-server="$1" \
                             --dump-dom "$2" > /output/dom.html
                ' dom-runner "$socks" "$url"
      ;;
    singlefile)
      # shellcheck disable=SC2016
      run_gvisor_container "$result_id" "$workdir" \
        bash -c '
                    set -euo pipefail
                    single-file \
                        --browser-executable-path="$(command -v chromium)" \
                        --browser-arg="--no-sandbox" \
                        --browser-arg="--disable-dev-shm-usage" \
                        --browser-arg="--proxy-server=$1" \
                        "$2" /output/page.html
                ' singlefile-runner "$socks" "$url"
      ;;
    readability)
      # shellcheck disable=SC2016
      run_gvisor_container "$result_id" "$workdir" \
        bash -c '
                    set -euo pipefail
                    socks_h="${1/socks5:\/\//socks5h://}"
                    curl -sSL --fail --max-time 60 -x "$socks_h" "$2" \
                        | readable --base "$2" --quiet > /output/readable.html
                ' readability-runner "$socks" "$url"
      ;;
    *)
      log "ERROR: unknown extractor '$extractor'"
      return 2
      ;;
  esac
}

run_gvisor_container() {
  local result_id="$1" workdir="$2"
  shift 2

  podman run --rm \
    --runtime=runsc \
    --network=slirp4netns:allow_host_loopback=true \
    --read-only \
    --tmpfs /tmp \
    --volume "$workdir:/output:rw" \
    --memory 2g \
    --cpus 1 \
    --timeout 300 \
    "fetchproxies-worker:latest" \
    "$@"
}

store_artifacts() {
  local result_id="$1" workdir="$2"
  gen_index "$workdir" "$result_id"
  local s3_prefix="s3://$S3_BUCKET/results/$result_id/"
  s3_cp_recursive "$workdir/" "$s3_prefix"
  echo "results/$result_id"
}

log "Starting worker (pg=$DATABASE_URL s3=$AWS_ENDPOINT_URL/$S3_BUCKET runtime=runsc)"
while true; do
  result=$(claim_job || true)
  IFS='|' read -r result_id url extractor proxy_chain snapshot_id <<<"$result"
  if [ -z "$result_id" ] || [ -z "$url" ] || [ -z "$extractor" ]; then
    sleep 5
    continue
  fi
  log "Claimed result $result_id: $extractor $url"

  rc=0
  run_fetch "$result_id" "$url" "$extractor" "$proxy_chain" || rc=$?
  if [ "$rc" -eq 0 ]; then
    workdir="/tmp/fetch-$result_id"
    artifact_key=$(store_artifacts "$result_id" "$workdir")
    size=$(du -sb "$workdir" | cut -f1)
    sha=$(find "$workdir" -type f -exec sha256sum {} + | sha256sum | cut -d' ' -f1)
    complete_job "$result_id" "$snapshot_id" "$artifact_key" "$size" "$sha"
    title=$(extract_title_from_workdir "$extractor" "$workdir" || true)
    if [ -n "${title:-}" ]; then
      set_snapshot_title_if_empty "$snapshot_id" "$title" &&
        log "Set snapshot $snapshot_id title: $title"
    fi
    log "Completed result $result_id -> s3://$S3_BUCKET/$artifact_key/"
  elif [ "$rc" -eq 2 ]; then
    fail_job_permanent "$result_id" "extractor '$extractor' permanently failed (exit 2)"
    log "Permanently failed result $result_id: extractor '$extractor'"
  else
    fail_job "$result_id" "extractor failed with exit code $rc"
    log "Failed result $result_id"
    sleep 1
  fi

  rm -rf "/tmp/fetch-$result_id"
done
