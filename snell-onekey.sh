#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  command -v sudo >/dev/null || { echo "请用 root 运行，或先安装 sudo"; exit 1; }
  exec sudo "$0" "$@"
fi

BASE=/opt/snell-multi
CONF=/etc/snell-multi
UNIT=/etc/systemd/system/snell@.service
mkdir -p "$BASE/bin" "$CONF"

arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo aarch64 ;;
    *) echo "不支持的架构: $(uname -m)"; exit 1 ;;
  esac
}

ver_full() {
  case "$1" in
    4) echo 4.1.1 ;;
    5) echo 5.0.1 ;;
    6) echo 6.0.0b3 ;;
    *) echo "版本只能选 4/5/6"; exit 1 ;;
  esac
}

rand_psk() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }

install_bin() {
  local v=$1 force=${2:-0} full url tmp
  full=$(ver_full "$v")
  [[ "$force" != 1 && -x "$BASE/bin/snell-server-v$v" ]] && return
  command -v curl >/dev/null || { apt update && apt install -y curl unzip; }
  command -v unzip >/dev/null || { apt update && apt install -y unzip; }
  tmp=$(mktemp -d)
  url="https://dl.nssurge.com/snell/snell-server-${full}-linux-$(arch).zip"
  echo "下载 Snell v$v: $url"
  curl -fL --retry 3 -o "$tmp/snell.zip" "$url"
  unzip -o "$tmp/snell.zip" -d "$tmp" >/dev/null
  install -m 755 "$tmp/snell-server" "$BASE/bin/snell-server-v$v"
  rm -rf "$tmp"
}

restart_version() {
  local v=$1 e name
  for e in "$CONF"/*.env; do
    [[ -e "$e" ]] || continue
    name=$(basename "$e" .env)
    # shellcheck disable=SC1090
    . "$e"
    [[ "${VER:-}" == "$v" ]] || continue
    systemctl restart "snell@$name" || true
  done
}

upgrade_version() {
  local v=$1
  echo "开始升级/重装 Snell v$v ..."
  install_bin "$v" 1
  write_unit
  restart_version "$v"
  echo "Snell v$v 已升级，并已重启该版本所有实例。"
}

write_unit() {
  cat > "$UNIT" <<EOF
[Unit]
Description=Snell %i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$CONF/%i.env
ExecStart=$BASE/bin/snell-server-v\${VER} -c $CONF/%i.conf
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
IPAccounting=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

add_instance() {
  read -rp "选择版本 [4/5/6]: " v
  [[ "$v" =~ ^[456]$ ]] || { echo "版本错误"; return; }
  read -rp "实例名，例如 hk-v$v-1: " name
  [[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "实例名只能用字母数字._-"; return; }
  read -rp "监听端口: " port
  [[ "$port" =~ ^[0-9]+$ ]] || { echo "端口错误"; return; }
  read -rp "PSK，留空随机: " psk
  psk=${psk:-$(rand_psk)}
  read -rp "obfs [tls/http/off] 默认 tls: " obfs
  obfs=${obfs:-tls}

  install_bin "$v"
  write_unit

  cat > "$CONF/$name.conf" <<EOF
[snell-server]
listen = ::0:$port
psk = $psk
reuse = true
EOF
  [[ "$obfs" != off ]] && echo "obfs = $obfs" >> "$CONF/$name.conf"

  cat > "$CONF/$name.env" <<EOF
VER=$v
PORT=$port
EOF

  chmod 600 "$CONF/$name.conf" "$CONF/$name.env"
  systemctl enable --now "snell@$name"
  echo
  echo "已安装: snell@$name"
  echo "版本: v$v"
  echo "端口: $port"
  echo "PSK: $psk"
}

list_instances() {
  printf "%-22s %-4s %-7s %-10s %-12s %-12s\n" NAME VER PORT STATE RX TX
  for e in "$CONF"/*.env; do
    [[ -e "$e" ]] || continue
    name=$(basename "$e" .env)
    # shellcheck disable=SC1090
    . "$e"
    state=$(systemctl is-active "snell@$name" 2>/dev/null || true)
    rx=$(systemctl show "snell@$name" -p IPIngressBytes --value 2>/dev/null || echo 0)
    tx=$(systemctl show "snell@$name" -p IPEgressBytes --value 2>/dev/null || echo 0)
    printf "%-22s v%-3s %-7s %-10s %-12s %-12s\n" "$name" "$VER" "$PORT" "${state:-unknown}" "$rx" "$tx"
  done
}

service_menu() {
  read -rp "操作 [start/stop/restart/status/logs/remove]: " op
  read -rp "实例名: " name
  case "$op" in
    start|stop|restart|status) systemctl "$op" "snell@$name" ;;
    logs) journalctl -u "snell@$name" -f ;;
    remove)
      systemctl disable --now "snell@$name" || true
      rm -f "$CONF/$name.conf" "$CONF/$name.env"
      systemctl daemon-reload
      echo "已删除 $name"
      ;;
    *) echo "未知操作" ;;
  esac
}

while true; do
  echo
  echo "==== Snell v4/v5/v6 一键管理 ===="
  echo "1. 添加 Snell 实例"
  echo "2. 查看实例和流量"
  echo "3. 启停/日志/删除"
  echo "4. 一键升级全部版本"
  echo "0. 退出"
  read -rp "请选择: " n
  case "$n" in
    1) add_instance ;;
    2) list_instances ;;
    3) service_menu ;;
    4) upgrade_version 4; upgrade_version 5; upgrade_version 6 ;;
    0) exit 0 ;;
    *) echo "选择错误" ;;
  esac
done
