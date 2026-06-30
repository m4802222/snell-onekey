#!/usr/bin/env bash
set -e

URL="${SNELL_ONEKEY_URL:-https://raw.githubusercontent.com/m4802222/snell-onekey/main/snell-onekey.sh}"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

curl -fsSL -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' "$URL" -o "$TMP"
bash -n "$TMP"
install -m 755 "$TMP" /usr/local/bin/snell
chmod +x /usr/local/bin/snell
echo "安装完成，运行：snell"
