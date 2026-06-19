#!/usr/bin/env bash
set -e

URL="${SNELL_ONEKEY_URL:-https://codeload.github.com/m4802222/snell-onekey/tar.gz/refs/heads/main}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

curl -fsSL "$URL" | tar -xz -C "$TMP"
install -m 755 "$TMP"/snell-onekey-main/snell-onekey.sh /usr/local/bin/snell
chmod +x /usr/local/bin/snell
echo "安装完成，运行：snell"
