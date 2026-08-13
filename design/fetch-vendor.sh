#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

REACT_VERSION=18.3.1
BABEL_VERSION=7.29.0

fetch() {
  local path=$1 url=$2 want=$3 got
  if [ -f "$path" ] && [ "$(sha256sum <"$path" | cut -d' ' -f1)" = "$want" ]; then
    echo "ok      $path"
    return
  fi
  mkdir -p "$(dirname "$path")"
  curl -fsSL --retry 3 -o "$path.tmp" "$url"
  got=$(sha256sum <"$path.tmp" | cut -d' ' -f1)
  if [ "$got" != "$want" ]; then
    rm -f "$path.tmp"
    echo "FAILED  $path: sha256 $got != $want" >&2
    exit 1
  fi
  mv -f "$path.tmp" "$path"
  echo "fetched $path"
}

fetch vendor/react.development.js \
  "https://unpkg.com/react@$REACT_VERSION/umd/react.development.js" \
  28348fef6cb0ed8b2ceeb22deaf824428fd13875d84c73d38f77dd216fc24e7f

fetch vendor/react-dom.development.js \
  "https://unpkg.com/react-dom@$REACT_VERSION/umd/react-dom.development.js" \
  f9044a5e9c39db8bb1a204dff924e526ec0a621e695bb69de1035811be8709e4

fetch vendor/babel.min.js \
  "https://unpkg.com/@babel/standalone@$BABEL_VERSION/babel.min.js" \
  2623a9e22809915ce789b4461154e277ddce520d5a4320c14d44332a5d0dcea0
