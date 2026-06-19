#!/usr/bin/env bash
set -e

URL="${SNELL_ONEKEY_URL:-https://github.com/m4802222/snell-onekey/raw/main/snell-onekey.sh}"

curl -fsSL "$URL" -o /usr/local/bin/n
chmod +x /usr/local/bin/n
echo "安装完成，运行：n"
