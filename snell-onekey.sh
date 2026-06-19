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

host_prefix() {
  local h
  h=$(hostname 2>/dev/null || echo vps)
  h=$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_.-]/-/g; s/^-*//; s/-*$//')
  [[ -n "$h" ]] || h=vps
  echo "$h"
}

next_instance_name() {
  local prefix i
  prefix=$(host_prefix)
  i=1
  while [[ -e "$CONF/${prefix}-${i}.env" || -e "$CONF/${prefix}-${i}.conf" ]]; do
    i=$((i + 1))
  done
  echo "${prefix}-${i}"
}

port_exists_in_config() {
  local port=$1 e
  for e in "$CONF"/*.env; do
    [[ -e "$e" ]] || continue
    # shellcheck disable=SC1090
    . "$e"
    [[ "${PORT:-}" == "$port" ]] && return 0
  done
  return 1
}

port_is_listening() {
  local port=$1
  if command -v ss >/dev/null 2>&1; then
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk 'NR>2 {print $4}' | grep -Eq "(^|:)${port}$"
  else
    return 1
  fi
}

random_port() {
  local port
  while true; do
    port=$((20000 + RANDOM % 40000))
    port_exists_in_config "$port" && continue
    port_is_listening "$port" && continue
    echo "$port"
    return
  done
}

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
  local v name port psk obfs
  read -rp "选择版本 [4/5/6] 默认 5: " v
  v=${v:-5}
  [[ "$v" =~ ^[456]$ ]] || { echo "版本错误"; return; }
  name=$(next_instance_name)
  port=$(random_port)
  psk=$(rand_psk)
  read -rp "obfs [tls/http/off] 默认 tls: " obfs
  obfs=${obfs:-tls}
  [[ "$obfs" =~ ^(tls|http|off)$ ]] || { echo "obfs 只能是 tls/http/off"; return; }

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
  echo "obfs: $obfs"
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
  read -rp "操作 [start/stop/restart/status/logs/remove] 默认 status: " op
  op=${op:-status}
  read -rp "实例名: " name
  [[ -n "$name" ]] || { echo "实例名不能为空"; return; }
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
  read -rp "请选择，默认 1: " n
  n=${n:-1}
  case "$n" in
    1) add_instance ;;
    2) list_instances ;;
    3) service_menu ;;
    4) upgrade_version 4; upgrade_version 5; upgrade_version 6 ;;
    0) exit 0 ;;
    *) echo "选择错误" ;;
  esac
done
