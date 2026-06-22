#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  command -v sudo >/dev/null || { echo "请用 root 运行，或先安装 sudo"; exit 1; }
  exec sudo "$0" "$@"
fi

BASE=/opt/snell-multi
CONF=/etc/snell-multi
STATE=/var/lib/snell-multi
UNIT=/etc/systemd/system/snell@.service
LIMIT_SERVICE=/etc/systemd/system/snell-limit-check.service
LIMIT_TIMER=/etc/systemd/system/snell-limit-check.timer
SCRIPT_URL=${SNELL_ONEKEY_SCRIPT_URL:-https://github.com/m4802222/snell-onekey/raw/main/snell-onekey.sh}
mkdir -p "$BASE/bin" "$CONF" "$STATE"

install_shortcut() {
  local target=/usr/local/bin/snell tmp
  tmp=$(mktemp)
  if command -v curl >/dev/null 2>&1 && curl -fsSL "$SCRIPT_URL" -o "$tmp" 2>/dev/null; then
    install -m 755 "$tmp" "$target" 2>/dev/null || true
  fi
  rm -f "$tmp"
}

install_shortcut

read_input() {
  local __var=$1 prompt=$2 default=${3:-} value
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    printf "%s" "$prompt" >/dev/tty
    IFS= read -r value </dev/tty
  else
    printf "%s" "$prompt"
    IFS= read -r value
  fi || return 1
  value=${value:-$default}
  printf -v "$__var" '%s' "$value"
}

arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo aarch64 ;;
    *) echo "不支持的架构: $(uname -m)"; exit 1 ;;
  esac
}

ver_full() {
  case "$1" in
    4) echo v4.1.1 ;;
    5) echo v5.0.1 ;;
    6) echo v6.0.0b3 ;;
    *) echo "版本只能选 4/5/6"; exit 1 ;;
  esac
}

rand_psk() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }

public_ip() {
  local ip
  ip=$(curl -4fsS --connect-timeout 3 https://api.ipify.org 2>/dev/null || true)
  [[ -n "$ip" ]] || ip=$(curl -4fsS --connect-timeout 3 https://ifconfig.me 2>/dev/null || true)
  [[ -n "$ip" ]] || ip="你的服务器IP"
  echo "$ip"
}

human_bytes() {
  local bytes=${1:-0}
  awk -v b="$bytes" 'BEGIN {
    split("B KB MB GB TB", u, " ");
    i = 1;
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    if (i == 1) printf "%d%s", b, u[i]; else printf "%.2f%s", b, u[i]
  }'
}

num_or_zero() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && echo "$1" || echo 0
}

traffic_limit_text() {
  local gb=${1:-0}
  if [[ "$gb" =~ ^[0-9]+$ && "$gb" -gt 0 ]]; then
    echo "${gb}G"
  else
    echo "不限"
  fi
}

state_text() {
  case "${1:-unknown}" in
    active) echo "运行中" ;;
    activating) echo "启动中" ;;
    inactive) echo "已停止" ;;
    failed) echo "失败" ;;
    limited) echo "超限停用" ;;
    deactivating) echo "停止中" ;;
    *) echo "${1:-未知}" ;;
  esac
}

now_epoch() { date +%s; }

file_mtime() {
  stat -c %Y "$1" 2>/dev/null || now_epoch
}

set_env_value() {
  local name=$1 key=$2 value=$3 env="$CONF/$1.env"
  if grep -q "^${key}=" "$env" 2>/dev/null; then
    sed -i.bak "s/^${key}=.*/${key}=${value}/" "$env"
    rm -f "$env.bak"
  else
    echo "${key}=${value}" >> "$env"
  fi
}

month_epoch() {
  local start=$1 months=$2 y m d h mi s total ty tm last_day result
  y=$(date -d "@$start" +%Y 2>/dev/null || true)
  m=$(date -d "@$start" +%m 2>/dev/null || true)
  d=$(date -d "@$start" +%d 2>/dev/null || true)
  h=$(date -d "@$start" +%H 2>/dev/null || true)
  mi=$(date -d "@$start" +%M 2>/dev/null || true)
  s=$(date -d "@$start" +%S 2>/dev/null || true)
  if [[ ! "$y$m$d$h$mi$s" =~ ^[0-9]+$ ]]; then
    echo $((start + months * 30 * 86400))
    return
  fi
  total=$((10#$m - 1 + months))
  ty=$((10#$y + total / 12))
  tm=$((total % 12 + 1))
  last_day=$(date -d "$(printf '%04d-%02d-01 +1 month -1 day' "$ty" "$tm")" +%d 2>/dev/null || echo "$d")
  if [[ "$((10#$d))" -gt "$((10#$last_day))" ]]; then
    d=$last_day
  fi
  result=$(date -d "$(printf '%04d-%02d-%02d %02d:%02d:%02d' "$ty" "$tm" "$((10#$d))" "$((10#$h))" "$((10#$mi))" "$((10#$s))")" +%s 2>/dev/null || true)
  if [[ "$result" =~ ^[0-9]+$ ]]; then
    echo "$result"
  else
    echo $((start + months * 30 * 86400))
  fi
}

cycle_start_epoch() {
  local start=$1 now=${2:-$(now_epoch)} prev next i=1
  prev=$start
  if [[ "$start" -gt "$now" ]]; then
    echo "$start"
    return
  fi
  while true; do
    next=$(month_epoch "$start" "$i")
    if [[ "$next" -gt "$now" ]]; then
      echo "$prev"
      return
    fi
    prev=$next
    i=$((i + 1))
  done
}

next_reset_epoch() {
  local start=$1 now=${2:-$(now_epoch)} next i=1
  if [[ "$start" -gt "$now" ]]; then
    echo "$start"
    return
  fi
  while true; do
    next=$(month_epoch "$start" "$i")
    if [[ "$next" -gt "$now" ]]; then
      echo "$next"
      return
    fi
    i=$((i + 1))
  done
}

remaining_time_text() {
  local limit_gb=${1:-0} start=${2:-0} now next diff days
  if ! [[ "$limit_gb" =~ ^[0-9]+$ ]] || [[ "$limit_gb" -le 0 ]]; then
    echo "不限"
    return
  fi
  start=$(num_or_zero "$start")
  [[ "$start" -gt 0 ]] || start=$(now_epoch)
  now=$(now_epoch)
  next=$(next_reset_epoch "$start" "$now")
  diff=$((next - now))
  [[ "$diff" -gt 0 ]] || { echo "<1天"; return; }
  days=$(((diff + 86399) / 86400))
  echo "${days}天"
}

current_bytes() {
  local name=$1 rx tx
  rx=$(systemctl show "snell@$name" -p IPIngressBytes --value 2>/dev/null || echo 0)
  tx=$(systemctl show "snell@$name" -p IPEgressBytes --value 2>/dev/null || echo 0)
  rx=$(num_or_zero "$rx")
  tx=$(num_or_zero "$tx")
  echo $((rx + tx))
}

state_num() {
  local file=$1 value=0
  [[ -f "$file" ]] && read -r value < "$file" || true
  num_or_zero "$value"
}

used_bytes() {
  local name=$1 current last total
  mkdir -p "$STATE"
  current=$(current_bytes "$name")
  last=$(state_num "$STATE/$name.last")
  total=$(state_num "$STATE/$name.total")
  if [[ "$current" -ge "$last" ]]; then
    total=$((total + current - last))
  else
    total=$((total + current))
  fi
  printf '%s\n' "$total" > "$STATE/$name.total"
  printf '%s\n' "$current" > "$STATE/$name.last"
  echo "$total"
}

reset_usage() {
  local name=$1 current
  mkdir -p "$STATE"
  current=$(current_bytes "$name")
  printf '0\n' > "$STATE/$name.total"
  printf '%s\n' "$current" > "$STATE/$name.last"
  clear_limited "$name"
}

ensure_usage_at_least() {
  local name=$1 min_bytes=$2 total current
  mkdir -p "$STATE"
  total=$(state_num "$STATE/$name.total")
  [[ "$total" -ge "$min_bytes" ]] && return 0
  current=$(current_bytes "$name")
  printf '%s\n' "$min_bytes" > "$STATE/$name.total"
  printf '%s\n' "$current" > "$STATE/$name.last"
}

limit_bytes() {
  local gb=${1:-0}
  if [[ "$gb" =~ ^[0-9]+$ && "$gb" -gt 0 ]]; then
    echo $((gb * 1024 * 1024 * 1024))
  else
    echo 0
  fi
}

mark_limited() {
  touch "$CONF/$1.limited"
}

clear_limited() {
  rm -f "$CONF/$1.limited"
}

is_limited() {
  [[ -f "$CONF/$1.limited" ]]
}

ensure_billing_start() {
  local name=$1 fallback start
  start=$(num_or_zero "${BILLING_START:-0}")
  [[ "$start" -gt 0 ]] && return 0
  fallback=$(file_mtime "$CONF/$name.env")
  set_env_value "$name" "BILLING_START" "$fallback"
  BILLING_START=$fallback
}

reset_cycle_if_due() {
  local name=$1 now start cycle marker active_before=0 was_limited=0
  load_instance "$name" >/dev/null || return 1
  ensure_billing_start "$name"
  now=$(now_epoch)
  start=$(cycle_start_epoch "$BILLING_START" "$now")
  marker=$(state_num "$STATE/$name.cycle")
  if [[ "$marker" -eq 0 ]]; then
    printf '%s\n' "$start" > "$STATE/$name.cycle"
    return 1
  fi
  [[ "$marker" -eq "$start" ]] && return 1

  systemctl is-active --quiet "snell@$name" 2>/dev/null && active_before=1
  is_limited "$name" && was_limited=1
  reset_usage "$name"
  printf '%s\n' "$start" > "$STATE/$name.cycle"
  if [[ "$active_before" -eq 1 || "$was_limited" -eq 1 ]]; then
    clear_limited "$name"
    load_instance "$name" >/dev/null || return 0
    open_port "$PORT"
    systemctl start "snell@$name" >/dev/null 2>&1 || true
  fi
  return 0
}

enforce_limit() {
  local name=$1 quiet=${2:-0} used limit
  load_instance "$name" >/dev/null || return 1
  ensure_billing_start "$name"
  reset_cycle_if_due "$name" >/dev/null 2>&1 || true
  load_instance "$name" >/dev/null || return 1
  ensure_billing_start "$name"
  limit=$(limit_bytes "${LIMIT_GB:-0}")
  if is_limited "$name"; then
    if [[ "$limit" -gt 0 ]]; then
      ensure_usage_at_least "$name" "$limit"
    else
      clear_limited "$name"
      return 1
    fi
    systemctl stop "snell@$name" >/dev/null 2>&1 || true
    close_port "$PORT"
    return 0
  fi
  [[ "$limit" -gt 0 ]] || { clear_limited "$name"; return 1; }
  used=$(used_bytes "$name")
  if [[ "$used" -ge "$limit" ]]; then
    systemctl stop "snell@$name" >/dev/null 2>&1 || true
    close_port "$PORT"
    if ! is_limited "$name" && [[ "$quiet" != 1 ]]; then
      echo "$name 已超过流量上限 $(traffic_limit_text "$LIMIT_GB")，已自动停用。"
    fi
    mark_limited "$name"
    return 0
  fi
  clear_limited "$name"
  return 1
}

fix_obfs_for_instance() {
  local name=$1 env="$CONF/$1.env" conf="$CONF/$1.conf"
  [[ -f "$env" && -f "$conf" ]] || return 0
  VER="" PORT="" PSK="" OBFS="" LIMIT_GB=0
  # shellcheck disable=SC1090
  . "$env"
  if [[ "${VER:-}" != "6" ]] && grep -qiE '^[[:space:]]*obfs[[:space:]]*=[[:space:]]*tls[[:space:]]*$' "$conf"; then
    sed -i.bak '/^[[:space:]]*obfs[[:space:]]*=[[:space:]]*tls[[:space:]]*$/Id' "$conf"
    if grep -q '^OBFS=' "$env"; then
      sed -i.bak 's/^OBFS=.*/OBFS=off/' "$env"
    else
      echo "OBFS=off" >> "$env"
    fi
    rm -f "$conf.bak" "$env.bak"
    echo "$name: 已修复 v${VER} 不支持的 obfs=tls"
  fi
}

fix_listen_for_instance() {
  local name=$1 conf="$CONF/$1.conf"
  [[ -f "$conf" ]] || return 0
  if grep -qE '^[[:space:]]*listen[[:space:]]*=[[:space:]]*::0:' "$conf"; then
    sed -i.bak 's/^\([[:space:]]*listen[[:space:]]*=[[:space:]]*\)::0:/\10.0.0.0:/' "$conf"
    rm -f "$conf.bak"
    echo "$name: 已修复监听地址为 0.0.0.0"
  fi
}

fix_instance() {
  fix_obfs_for_instance "$1"
  fix_listen_for_instance "$1"
}

repair_all_instances() {
  local e name
  for e in "$CONF"/*.env; do
    [[ -e "$e" ]] || continue
    name=$(basename "$e" .env)
    fix_instance "$name"
  done
}

instance_names() {
  local e
  for e in "$CONF"/*.env; do
    [[ -e "$e" ]] || continue
    basename "$e" .env
  done | sort
}

load_instance() {
  local name=$1
  VER="" PORT="" PSK="" OBFS="" LIMIT_GB=0 BILLING_START=0
  [[ -f "$CONF/$name.env" ]] || { echo "实例不存在: $name"; return 1; }
  # shellcheck disable=SC1090
  . "$CONF/$name.env"
  ensure_billing_start "$name"
}

instance_state() {
  local name=$1 state
  enforce_limit "$name" 1 >/dev/null 2>&1 || true
  state=$(systemctl is-active "snell@$name" 2>/dev/null || true)
  if is_limited "$name" && [[ "$state" != active && "$state" != activating ]]; then
    state="limited"
  fi
  echo "$state"
}

instance_summary() {
  local name=$1 state used
  load_instance "$name" >/dev/null || return 1
  state=$(instance_state "$name")
  used=$(used_bytes "$name")
  printf "%s  v%s  %s  %s  %s/%s  %s" "$name" "$VER" "$PORT" "$(state_text "$state")" "$(human_bytes "$used")" "$(traffic_limit_text "${LIMIT_GB:-0}")" "$(remaining_time_text "${LIMIT_GB:-0}" "${BILLING_START:-0}")"
}

choose_number() {
  local prompt=$1 default=$2 max=$3 choice
  read_input choice "$prompt" "$default" || return 1
  [[ "$choice" =~ ^[0-9]+$ ]] || { echo "选择错误" >&2; return 1; }
  [[ "$choice" -ge 0 && "$choice" -le "$max" ]] || { echo "选择错误" >&2; return 1; }
  echo "$choice"
}

select_instance() {
  local names=() name i choice
  while IFS= read -r name; do
    names+=("$name")
  done < <(instance_names)
  [[ "${#names[@]}" -gt 0 ]] || { echo "暂无实例" >&2; return 1; }

  echo >&2
  echo "选择实例：" >&2
  for i in "${!names[@]}"; do
    printf "%s. %s\n" "$((i + 1))" "$(instance_summary "${names[$i]}")" >&2
  done
  echo "0. 返回" >&2
  choice=$(choose_number "请选择，默认 1: " 1 "${#names[@]}") || return 1
  [[ "$choice" -eq 0 ]] && return 1
  echo "${names[$((choice - 1))]}"
}

assert_can_run() {
  local name=$1 action=$2 used limit
  load_instance "$name" >/dev/null || return 1
  reset_cycle_if_due "$name" >/dev/null 2>&1 || true
  load_instance "$name" >/dev/null || return 1
  if is_limited "$name"; then
    systemctl stop "snell@$name" >/dev/null 2>&1 || true
    close_port "$PORT"
    echo "该实例已超限停用，不能${action}。"
    echo "下个计费周期会自动清零并重新启动。"
    return 1
  fi
  limit=$(limit_bytes "${LIMIT_GB:-0}")
  used=$(used_bytes "$name")
  if [[ "$limit" -gt 0 && "$used" -ge "$limit" ]]; then
    systemctl stop "snell@$name" >/dev/null 2>&1 || true
    close_port "$PORT"
    mark_limited "$name"
    echo "已超过流量上限 $(human_bytes "$used")/$(traffic_limit_text "$LIMIT_GB")，不能${action}。"
    echo "下个计费周期会自动清零并重新启动。"
    return 1
  fi
  clear_limited "$name"
}

run_instance_action() {
  local name=$1 op=$2
  case "$op" in
    1)
      load_instance "$name" >/dev/null || return 1
      assert_can_run "$name" "启动" || return 1
      open_port "$PORT"
      systemctl start "snell@$name"
      ;;
    2)
      load_instance "$name" >/dev/null || return 1
      systemctl stop "snell@$name"
      close_port "$PORT"
      ;;
    3)
      load_instance "$name" >/dev/null || return 1
      assert_can_run "$name" "重启" || return 1
      open_port "$PORT"
      systemctl restart "snell@$name"
      ;;
    4)
      enforce_limit "$name" 0 >/dev/null 2>&1 || true
      systemctl status "snell@$name" --no-pager
      ;;
    5) journalctl -u "snell@$name" -f ;;
    6)
      load_instance "$name" >/dev/null || return 1
      systemctl disable --now "snell@$name" || true
      close_port "$PORT"
      rm -f "$CONF/$name.conf" "$CONF/$name.env" "$CONF/$name.limited"
      rm -f "$STATE/$name.total" "$STATE/$name.last" "$STATE/$name.cycle"
      systemctl daemon-reload
      echo "已删除 $name"
      ;;
    7) print_client_config "$name" ;;
    8)
      fix_instance "$name"
      assert_can_run "$name" "重启" || return 1
      systemctl restart "snell@$name"
      echo "已修复并重启 $name"
      echo "复制配置："
      print_client_config "$name"
      ;;
    9) diagnose_instance "$name" ;;
    10)
      load_instance "$name" >/dev/null || return 1
      reset_usage "$name"
      open_port "$PORT"
      systemctl start "snell@$name"
      echo "已重置 $name 当前周期流量，并已启动。"
      ;;
    0) return 0 ;;
    *) echo "未知操作" ;;
  esac
}

print_client_config() {
  local name=$1 server_ip
  fix_instance "$name"
  load_instance "$name" >/dev/null || return 1
  server_ip=$(public_ip)
  if [[ "${OBFS:-off}" == off ]]; then
    echo "${name} = snell, ${server_ip}, ${PORT}, psk=${PSK}, version=${VER}"
  else
    echo "${name} = snell, ${server_ip}, ${PORT}, psk=${PSK}, version=${VER}, obfs=${OBFS}"
  fi
}

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

valid_port() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 && "$1" -le 65535 ]]
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

choose_port() {
  local port
  read_input port "监听端口，留空随机: " "" || return 1
  if [[ -z "$port" ]]; then
    random_port
    return
  fi
  valid_port "$port" || { echo "端口必须是 1-65535"; return 1; }
  port_exists_in_config "$port" && { echo "端口已被当前脚本实例使用"; return 1; }
  port_is_listening "$port" && { echo "端口正在被系统占用"; return 1; }
  echo "$port"
}

open_port() {
  local port=$1
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$port/tcp" >/dev/null 2>&1 || true
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --add-port="$port/tcp" --permanent >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  elif command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
  fi
}

close_port() {
  local port=$1
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw delete allow "$port/tcp" >/dev/null 2>&1 || true
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --remove-port="$port/tcp" --permanent >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  elif command -v iptables >/dev/null 2>&1; then
    while iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; do
      iptables -D INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || break
    done
  fi
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
    VER="" PORT="" PSK="" OBFS="" LIMIT_GB=0 BILLING_START=0
    name=$(basename "$e" .env)
    fix_instance "$name"
    # shellcheck disable=SC1090
    . "$e"
    [[ "${VER:-}" == "$v" ]] || continue
    enforce_limit "$name" 1 >/dev/null 2>&1 && continue
    systemctl restart "snell@$name" || true
  done
}

upgrade_version() {
  local v=$1
  echo "开始升级/重装 Snell v$v ..."
  install_bin "$v" 1
  write_unit
  write_limit_timer
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
ExecStart=/bin/sh -c 'exec $BASE/bin/snell-server-v\${VER} -c $CONF/%i.conf'
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
IPAccounting=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

write_limit_timer() {
  cat > "$LIMIT_SERVICE" <<EOF
[Unit]
Description=Snell traffic limit check

[Service]
Type=oneshot
ExecStart=/usr/local/bin/snell check-limits
EOF

  cat > "$LIMIT_TIMER" <<EOF
[Unit]
Description=Run Snell traffic limit check every 1 minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now snell-limit-check.timer >/dev/null 2>&1 || true
}

check_limits() {
  local e name
  for e in "$CONF"/*.env; do
    [[ -e "$e" ]] || continue
    VER="" PORT="" PSK="" OBFS="" LIMIT_GB=0
    name=$(basename "$e" .env)
    fix_instance "$name"
    enforce_limit "$name" 0 || true
  done
}

add_instance() {
  local v name port psk obfs limit_gb billing_start
  read_input v "选择版本 [4/5/6] 默认 5: " "5" || { echo "读取版本失败"; return; }
  [[ "$v" =~ ^[456]$ ]] || { echo "版本错误"; return; }
  name=$(next_instance_name)
  port=$(choose_port) || { echo "端口选择失败"; return; }
  psk=$(rand_psk)
  obfs=off
  read_input limit_gb "每月流量上限，单位G，留空不限: " "0" || { echo "读取流量上限失败"; return; }
  [[ "$limit_gb" =~ ^[0-9]+$ ]] || { echo "每月流量上限只能填数字"; return; }

  install_bin "$v" || { echo "Snell v$v 下载或安装失败"; return; }
  write_unit
  write_limit_timer
  billing_start=$(now_epoch)

  cat > "$CONF/$name.conf" <<EOF
[snell-server]
listen = 0.0.0.0:$port
psk = $psk
reuse = true
EOF
  [[ "$obfs" != off ]] && echo "obfs = $obfs" >> "$CONF/$name.conf"

  cat > "$CONF/$name.env" <<EOF
VER=$v
PORT=$port
PSK=$psk
OBFS=$obfs
LIMIT_GB=$limit_gb
BILLING_START=$billing_start
EOF

  chmod 600 "$CONF/$name.conf" "$CONF/$name.env"
  reset_usage "$name"
  clear_limited "$name"
  open_port "$port"
  systemctl enable --now "snell@$name"
  echo
  echo "安装完成，复制下面配置即可："
  print_client_config "$name"
}

list_instances() {
  {
    printf "实例名称\t版本\t端口\t状态\t已用流量\t流量上限\t剩余时间\n"
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      fix_instance "$name"
      load_instance "$name" >/dev/null || continue
      state=$(instance_state "$name")
      used=$(used_bytes "$name")
      printf "%s\tv%s\t%s\t%s\t%s\t%s\t%s\n" "$name" "$VER" "$PORT" "$(state_text "$state")" "$(human_bytes "$used")" "$(traffic_limit_text "${LIMIT_GB:-0}")" "$(remaining_time_text "${LIMIT_GB:-0}" "${BILLING_START:-0}")"
    done < <(instance_names)
  } | {
    if command -v column >/dev/null 2>&1; then
      column -t -s $'\t'
    else
      cat
    fi
  }
}

diagnose_instance() {
  local name=$1 state listen server_ip
  fix_instance "$name"
  load_instance "$name" >/dev/null || return 1
  assert_can_run "$name" "检测连接" || return 1
  open_port "$PORT"
  systemctl restart "snell@$name" >/dev/null 2>&1 || true
  sleep 1
  state=$(systemctl is-active "snell@$name" 2>/dev/null || true)
  server_ip=$(public_ip)
  echo
  echo "===== 检测结果 ====="
  echo "实例: $name"
  echo "状态: $(state_text "$state")"
  echo "服务器: $server_ip"
  echo "端口: $PORT"
  echo
  echo "客户端配置："
  print_client_config "$name"
  echo
  echo "监听检查："
  if command -v ss >/dev/null 2>&1; then
    listen=$(ss -ltnp 2>/dev/null | grep ":$PORT " || true)
  else
    listen=$(netstat -ltnp 2>/dev/null | grep ":$PORT " || true)
  fi
  if [[ -n "$listen" ]]; then
    echo "$listen"
  else
    echo "未检测到端口监听，请看下面日志。"
  fi
  echo
  echo "最近日志："
  journalctl -u "snell@$name" -n 20 --no-pager || true
  echo
  echo "提示: 如果状态正常且端口已监听但仍测速失败，请确认云厂商安全组已放行 TCP $PORT。"
}

service_menu() {
  local name op
  name=$(select_instance) || return

  echo
  echo "选择操作："
  echo "1. 启动"
  echo "2. 停止"
  echo "3. 重启"
  echo "4. 查看状态"
  echo "5. 查看日志"
  echo "6. 删除"
  echo "7. 复制配置"
  echo "8. 修复配置"
  echo "9. 检测连接"
  echo "10. 周期内流量重置"
  echo "0. 返回"
  op=$(choose_number "请选择，默认 4: " 4 10) || return
  run_instance_action "$name" "$op"
}

if [[ "${1:-}" == "check-limits" ]]; then
  repair_all_instances
  check_limits
  exit 0
fi

repair_all_instances
write_unit
write_limit_timer

while true; do
  echo
  echo "==== Snell v4/v5/v6 一键管理 ===="
  echo "1. 添加 Snell 实例"
  echo "2. 查看实例和流量"
  echo "3. 启停/日志/删除"
  echo "4. 一键升级全部版本"
  echo "0. 退出"
  n=$(choose_number "请选择，默认 1: " 1 4) || continue
  case "$n" in
    1) add_instance ;;
    2) list_instances ;;
    3) service_menu ;;
    4) upgrade_version 4; upgrade_version 5; upgrade_version 6 ;;
    0) exit 0 ;;
    *) echo "选择错误" ;;
  esac
done
