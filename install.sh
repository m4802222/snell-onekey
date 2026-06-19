#!/usr/bin/env bash
set -e

URL="${SNELL_ONEKEY_URL:-https://raw.githubusercontent.com/m4802222/snell-onekey/main/snell-onekey.sh}"

curl -fsSL "$URL" -o /usr/local/bin/snell-onekey
chmod +x /usr/local/bin/snell-onekey
echo "安装完成，运行：sudo snell-onekey"
