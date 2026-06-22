#!/usr/bin/env bash
set -e

URL="${SNELL_ONEKEY_URL:-https://github.com/m4802222/snell-onekey/raw/main/snell-onekey.sh}"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

curl -fsSL "$URL" -o "$TMP"
bash -n "$TMP"
install -m 755 "$TMP" /usr/local/bin/snell
chmod +x /usr/local/bin/snell
echo "安装完成，运行：snell"
