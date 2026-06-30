#!/usr/bin/env bash
set -Eeuo pipefail

SNELL_VERSION="${SNELL_VERSION:-4.1.1}"
SNELL_PORT="${SNELL_PORT:-}"
SNELL_PSK="${SNELL_PSK:-}"
SNELL_IPV6="${SNELL_IPV6:-false}"
SNELL_CONF_DIR="${SNELL_CONF_DIR:-/etc/snell}"
SNELL_CONF="${SNELL_CONF:-${SNELL_CONF_DIR}/snell-server.conf}"
SNELL_BIN="${SNELL_BIN:-/usr/local/bin/snell-server}"
SNELL_SERVICE="${SNELL_SERVICE:-snell-server}"
SNELL_DOWNLOAD_BASE="${SNELL_DOWNLOAD_BASE:-https://dl.nssurge.com/snell}"

log() { printf '[snell-v4] %s\n' "$*"; }
die() { printf '[snell-v4] ERROR: %s\n' "$*" >&2; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

need_root() {
  [ "$(id -u)" -eq 0 ] || die "请用 root 运行"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) printf 'linux-amd64' ;;
    aarch64 | arm64) printf 'linux-aarch64' ;;
    armv7l | armv7) printf 'linux-armv7' ;;
    *) die "不支持的架构: $(uname -m)" ;;
  esac
}

detect_os_family() {
  if [ -r /etc/alpine-release ]; then
    printf 'alpine'
  elif command_exists apt-get; then
    printf 'debian'
  elif command_exists dnf; then
    printf 'dnf'
  elif command_exists yum; then
    printf 'yum'
  else
    die "不支持的 Linux 发行版"
  fi
}

detect_init() {
  if command_exists systemctl && [ -d /run/systemd/system ]; then
    printf 'systemd'
  elif command_exists rc-service && command_exists rc-update; then
    printf 'openrc'
  else
    die "不支持的 init 系统，需要 systemd 或 OpenRC"
  fi
}

valid_port() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 && "$1" -le 65535 ]]
}

port_is_listening() {
  local port=$1
  if command_exists ss; then
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"
  elif command_exists netstat; then
    netstat -ltn 2>/dev/null | awk 'NR>2 {print $4}' | grep -Eq "(^|:)${port}$"
  else
    return 1
  fi
}

random_port() {
  local port
  while true; do
    port=$((20000 + RANDOM % 40000))
    port_is_listening "$port" && continue
    printf '%s' "$port"
    return
  done
}

choose_port() {
  if [ -n "$SNELL_PORT" ]; then
    valid_port "$SNELL_PORT" || die "SNELL_PORT 必须是 1-65535"
    port_is_listening "$SNELL_PORT" && die "端口 ${SNELL_PORT} 已被占用"
    return
  fi

  SNELL_PORT="$(random_port)"
  log "随机端口: ${SNELL_PORT}"
}

install_deps() {
  case "$1" in
    alpine)
      apk update
      apk add --no-cache ca-certificates curl unzip openssl libstdc++ gcompat iproute2-ss
      ;;
    debian)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y --no-install-recommends ca-certificates curl unzip openssl libstdc++6 iproute2
      ;;
    dnf)
      dnf install -y ca-certificates curl unzip openssl libstdc++ iproute
      ;;
    yum)
      yum install -y ca-certificates curl unzip openssl libstdc++ iproute
      ;;
  esac
}

download_server() {
  local arch url tmp zip
  arch="$(detect_arch)"
  url="${SNELL_DOWNLOAD_BASE}/snell-server-v${SNELL_VERSION}-${arch}.zip"
  tmp="$(mktemp -d)"
  zip="${tmp}/snell.zip"

  log "下载 ${url}"
  curl -fL --connect-timeout 15 --retry 3 -o "$zip" "$url"
  unzip -o "$zip" -d "$tmp" >/dev/null
  install -m 0755 "${tmp}/snell-server" "$SNELL_BIN"
  rm -rf "$tmp"
}

make_psk() {
  if [ -n "$SNELL_PSK" ]; then
    printf '%s' "$SNELL_PSK"
  else
    openssl rand -hex 16
  fi
}

write_config() {
  local psk backup
  psk="$(make_psk)"
  install -d -m 0755 "$SNELL_CONF_DIR"

  if [ -f "$SNELL_CONF" ]; then
    backup="${SNELL_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$SNELL_CONF" "$backup"
    log "已备份旧配置: ${backup}"
  fi

  cat >"$SNELL_CONF" <<CONF
[snell-server]
listen = 0.0.0.0:${SNELL_PORT}
psk = ${psk}
ipv6 = ${SNELL_IPV6}
CONF
  chmod 0600 "$SNELL_CONF"
}

write_systemd_service() {
  cat >/etc/systemd/system/${SNELL_SERVICE}.service <<SERVICE
[Unit]
Description=Snell v4 Proxy Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SNELL_BIN} -c ${SNELL_CONF}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICE

  systemctl daemon-reload
  systemctl enable --now "$SNELL_SERVICE"
  systemctl restart "$SNELL_SERVICE"
}

write_openrc_service() {
  cat >/etc/init.d/${SNELL_SERVICE} <<SERVICE
#!/sbin/openrc-run
name="${SNELL_SERVICE}"
description="Snell v4 Proxy Server"
command="${SNELL_BIN}"
command_args="-c ${SNELL_CONF}"
command_background="yes"
pidfile="/run/${SNELL_SERVICE}.pid"
start_stop_daemon_args="--make-pidfile"

depend() {
    need net
    after firewall
}
SERVICE

  chmod +x /etc/init.d/${SNELL_SERVICE}
  rc-update add "$SNELL_SERVICE" default >/dev/null 2>&1 || true
  rc-service "$SNELL_SERVICE" restart
}

open_local_firewall() {
  if command_exists ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${SNELL_PORT}/tcp" >/dev/null 2>&1 || true
  elif command_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --add-port="${SNELL_PORT}/tcp" --permanent >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  elif command_exists iptables; then
    iptables -C INPUT -p tcp --dport "$SNELL_PORT" -j ACCEPT >/dev/null 2>&1 ||
      iptables -I INPUT -p tcp --dport "$SNELL_PORT" -j ACCEPT >/dev/null 2>&1 || true
  fi
}

validate() {
  local psk init_system
  init_system="$(detect_init)"
  sleep 1
  if ss -lntup 2>/dev/null | grep -q ":${SNELL_PORT}"; then
    log "已监听 TCP ${SNELL_PORT}"
  else
    ss -lntup 2>/dev/null || true
    die "Snell 未监听 TCP ${SNELL_PORT}"
  fi

  psk="$(sed -n 's/^psk *= *//p' "$SNELL_CONF")"
  cat <<EOF

Surge 配置：
snell, YOUR_SERVER_IP, ${SNELL_PORT}, psk=${psk}, version=4

服务启动详情：
EOF

  if [ "$init_system" = "systemd" ]; then
    printf 'systemd is-active: '
    systemctl is-active "$SNELL_SERVICE" || true
    printf '\nsystemd status:\n'
    systemctl --no-pager --full status "$SNELL_SERVICE" || true
    printf '\n最近日志:\n'
    journalctl -u "$SNELL_SERVICE" -n 20 --no-pager || true
  else
    printf 'OpenRC status:\n'
    rc-service "$SNELL_SERVICE" status || true
  fi

  cat <<EOF

进程：
$(ps w | grep '[s]nell-server' || true)

监听：
$(ss -lntup 2>/dev/null | grep ":${SNELL_PORT}" || true)

提示：
1. 把 YOUR_SERVER_IP 替换为 VPS 公网 IP。
2. 云厂商安全组需要放行 TCP ${SNELL_PORT}。
EOF
}

main() {
  need_root
  os_family="$(detect_os_family)"
  init_system="$(detect_init)"

  log "OS: ${os_family}"
  log "init: ${init_system}"
  install_deps "$os_family"
  choose_port
  download_server
  write_config
  open_local_firewall

  if [ "$init_system" = "systemd" ]; then
    write_systemd_service
  else
    write_openrc_service
  fi

  validate
}

main "$@"
