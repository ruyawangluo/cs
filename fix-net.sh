#!/usr/bin/env bash
#
# fix-net.sh —— DD 重装后重建网卡配置
#
# 作用：
#   1. 备份并废掉 DD 后系统自带的网卡配置（含 cloud-init 生成的）
#   2. 禁用 cloud-init 对网络的接管（否则重启会被回写覆盖）
#   3. 交互式询问网络信息，按输入重建 /etc/netplan 下的静态配置
#   4. 校验并应用，支持多 IPv4、附加子网、IPv6
#   5. 可选把 DNS 同步写入 /etc/resolv.conf（绕过 systemd-resolved 的 stub）
#
# 用法：
#   sudo bash fix-net.sh              # 正常交互执行
#   sudo bash fix-net.sh --dry-run    # 只在 /tmp 生成配置预览，不改动系统
#   sudo bash fix-net.sh ens18        # 直接指定网卡名，跳过探测
#
set -uo pipefail

DRY_RUN=0
IFACE_ARG=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) awk 'NR>2 && /^set -uo/{exit} NR>2' "$0"; exit 0 ;;
    *) IFACE_ARG="$a" ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 运行：sudo bash $0" >&2
  exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/netplan-backup-$TS"
CONF_PATH="/etc/netplan/99-virt-custom.yaml"
[[ $DRY_RUN -eq 1 ]] && CONF_PATH="/tmp/netplan-dryrun-99-virt-custom.yaml"

info() { printf '\033[32m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }
err()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# ---------- 输入解析 ----------
# 把带空格/中英文逗号的输入切成数组
split_list() { sed 's/[,，]/\n/g' <<<"$1" | tr -s ' \t' '\n'; }

# 归一化 IPv4：可省略掩码，默认 /24
norm_v4() {
  local c="$1" ip pfx
  if [[ "$c" == */* ]]; then ip="${c%%/*}"; pfx="${c##*/}"; else ip="$c"; pfx=24; fi
  echo "$ip/$pfx"
}

valid_v4() {
  local cidr="$1" ip pfx
  ip="${cidr%%/*}"; pfx="${cidr##*/}"
  valid_v4_addr "$ip" || return 1
  [[ "$pfx" =~ ^[0-9]+$ ]] && (( pfx >= 0 && pfx <= 32 )) || return 1
  return 0
}

valid_v4_addr() {
  local ip="$1" a b c d o
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r a b c d <<<"$ip"
  for o in "$a" "$b" "$c" "$d"; do (( o >= 0 && o <= 255 )) || return 1; done
  return 0
}

# 归一化 IPv6：可省略掩码，默认 /64
norm_v6() {
  local c="$1" ip pfx
  if [[ "$c" == */* ]]; then ip="${c%%/*}"; pfx="${c##*/}"; else ip="$c"; pfx=64; fi
  echo "$ip/$pfx"
}

valid_v6() {
  local cidr="$1" ip pfx
  ip="${cidr%%/*}"; pfx="${cidr##*/}"
  [[ "$ip" == *:* ]] || return 1
  [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] || return 1
  [[ "$pfx" =~ ^[0-9]+$ ]] && (( pfx >= 0 && pfx <= 128 )) || return 1
  return 0
}

# IPv4 <-> 整数（用于算网段）
ip2int() { local IFS=. a b c d; read -r a b c d <<<"$1"; echo $(( (a<<24) | (b<<16) | (c<<8) | d )); }
int2ip() { echo "$(( ($1>>24)&255 )).$(( ($1>>16)&255 )).$(( ($1>>8)&255 )).$(( $1&255 ))"; }
mask_of() { local p="$1"; if (( p == 0 )); then echo 0; else echo $(( (0xffffffff << (32-p)) & 0xffffffff )); fi; }
network_of() { local n; n=$(( $(ip2int "${1%%/*}") & $(mask_of "${1##*/}") )); echo "$(int2ip "$n")/${1##*/}"; }

# ---------- 探测网卡 ----------
mapfile -t IFACES < <(for i in $(compgen -G "/sys/class/net/*" || true); do b="${i##*/}"; [[ "$b" == lo ]] && continue; echo "$b"; done)

if [[ -n "$IFACE_ARG" ]]; then
  IFACE="$IFACE_ARG"
elif (( ${#IFACES[@]} == 1 )); then
  IFACE="${IFACES[0]}"
else
  def="$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')"
  echo "检测到多张网卡："
  for i in "${IFACES[@]}"; do
    mac="$(cat "/sys/class/net/$i/address" 2>/dev/null)"
    printf '  - %-10s MAC %s\n' "$i" "$mac"
  done
  read -rp "请输入要配置的网卡名${def:+ [$def]}: " IFACE
  IFACE="${IFACE:-$def}"
fi

if [[ ! -d "/sys/class/net/$IFACE" ]]; then
  err "网卡 $IFACE 不存在，请用 ip -br link 确认后重试。"
  exit 1
fi
MAC="$(cat "/sys/class/net/$IFACE/address" 2>/dev/null || true)"
info "使用网卡：$IFACE  (MAC $MAC)"
echo
echo "当前网络状态（供参考，可回滚核对）："
ip -br addr 2>/dev/null || true
echo

# ---------- 交互采集 ----------
read -rp "IPv4 地址（多个用空格/逗号分隔，可带掩码，省略按 /24）: " V4RAW
V4LIST=()
if [[ -n "$V4RAW" ]]; then
  while read -r c; do
    [[ -z "$c" ]] && continue
    c="$(norm_v4 "$c")"
    if ! valid_v4 "$c"; then err "无效的 IPv4: $c"; exit 1; fi
    V4LIST+=("$c")
  done < <(split_list "$V4RAW")
fi

read -rp "IPv4 默认网关（没有可留空）: " GW4
if [[ -n "$GW4" ]] && ! valid_v4_addr "$GW4"; then err "无效的 IPv4 网关: $GW4"; exit 1; fi

read -rp "IPv6 地址（多个用空格/逗号分隔，可带掩码，省略按 /64，可留空）: " V6RAW
V6LIST=()
if [[ -n "$V6RAW" ]]; then
  while read -r c; do
    [[ -z "$c" ]] && continue
    c="$(norm_v6 "$c")"
    if ! valid_v6 "$c"; then err "无效的 IPv6: $c"; exit 1; fi
    V6LIST+=("$c")
  done < <(split_list "$V6RAW")
fi

read -rp "IPv6 默认网关（没有可留空）: " GW6
if [[ -n "$GW6" ]] && ! { [[ "$GW6" == *:* && "$GW6" =~ ^[0-9a-fA-F:]+$ ]]; }; then err "无效的 IPv6 网关: $GW6"; exit 1; fi
read -rp "DNS 服务器（多个用空格/逗号分隔）[8.8.8.8 1.1.1.1]: " DNSRAW
DNSRAW="${DNSRAW:-8.8.8.8 1.1.1.1}"
read -rp "是否绑定 MAC 地址（防止内核升级后网卡改名）[Y/n]: " BIND_MAC
BIND_MAC="${BIND_MAC:-Y}"
read -rp "是否把 DNS 同步写入 /etc/resolv.conf（绕过 systemd-resolved 的 stub 链接）[Y/n]: " WRITE_RESOLV
WRITE_RESOLV="${WRITE_RESOLV:-Y}"

if (( ${#V4LIST[@]} == 0 && ${#V6LIST[@]} == 0 )); then
  err "至少需要一个 IPv4 或 IPv6 地址。"
  exit 1
fi

# ---------- 生成 YAML ----------
gen() {
  echo "network:"
  echo "  version: 2"
  echo "  renderer: networkd"
  echo "  ethernets:"
  echo "    $IFACE:"
  echo "      dhcp4: false"
  echo "      dhcp6: false"
  if [[ "$BIND_MAC" =~ ^[Yy] && -n "$MAC" ]]; then
    echo "      match:"
    echo "        macaddress: $MAC"
  fi
  echo "      addresses:"
  local c
  for c in "${V4LIST[@]:-}"; do [[ -n "$c" ]] && echo "        - $c"; done
  for c in "${V6LIST[@]:-}"; do [[ -n "$c" ]] && echo "        - $c"; done
  echo "      routes:"
  if [[ -n "$GW4" ]]; then
    echo "        - on-link: true"
    echo "          to: 0.0.0.0/0"
    echo "          via: $GW4"
  fi
  if [[ -n "$GW6" ]]; then
    echo "        - on-link: true"
    echo "          to: ::/0"
    echo "          via: $GW6"
  fi
  # 附加 IPv4 子网：非网关所在网段的地址，补一条 on-link 路由
  if [[ -n "$GW4" && ${#V4LIST[@]} -gt 0 ]]; then
    local gwnw="" c nw
    # 网关网段取"包含网关"的地址网段；若无匹配则以第一个地址网段为准
    for c in "${V4LIST[@]}"; do
      nw="$(network_of "$c")"
      base="$(int2ip "$(ip2int "$GW4")")"
      if [[ "$(network_of "$base/${c##*/}")" == "$nw" ]]; then gwnw="$nw"; break; fi
    done
    [[ -z "$gwnw" ]] && gwnw="$(network_of "${V4LIST[0]}")"
    local -A seen=()
    for c in "${V4LIST[@]}"; do
      nw="$(network_of "$c")"
      if [[ "$nw" != "$gwnw" && -z "${seen[$nw]:-}" ]]; then
        seen[$nw]=1
        echo "        - on-link: true"
        echo "          to: $nw"
        echo "          via: $GW4"
      fi
    done
  fi
  echo "      nameservers:"
  printf '        addresses: ['
  local first=1 d
  while read -r d; do
    [[ -z "$d" ]] && continue
    if (( first )); then printf '%s' "$d"; first=0; else printf ', %s' "$d"; fi
  done < <(split_list "$DNSRAW")
  printf ']\n'
}

# /etc/resolv.conf 内容
gen_resolv() {
  local d
  while read -r d; do
    [[ -z "$d" ]] && continue
    echo "nameserver $d"
  done < <(split_list "$DNSRAW")
}

echo
info "生成的配置预览："
echo "----------------------------------------"
gen | tee /tmp/.fix-net-preview
echo "----------------------------------------"
if [[ "$WRITE_RESOLV" =~ ^[Yy] ]]; then
  echo "将要写入 /etc/resolv.conf："
  echo "----------------------------------------"
  gen_resolv
  echo "----------------------------------------"
fi
echo
read -rp "确认写入并应用？[y/N]: " OK
[[ "$OK" =~ ^[Yy] ]] || { warn "已取消。"; exit 0; }

# ---------- 落盘 ----------
if [[ $DRY_RUN -eq 1 ]]; then
  gen > "$CONF_PATH"
  chmod 600 "$CONF_PATH"
  if [[ "$WRITE_RESOLV" =~ ^[Yy] ]]; then
    gen_resolv > /tmp/resolv-dryrun.conf
    info "[dry-run] 已写入 $CONF_PATH 和 /tmp/resolv-dryrun.conf，未改动系统。"
  else
    info "[dry-run] 已写入 $CONF_PATH，未改动系统。"
  fi
  exit 0
fi

mkdir -p "$BACKUP_DIR"
mkdir -p /etc/netplan
if compgen -G "/etc/netplan/*" >/dev/null; then
  cp -a /etc/netplan/. "$BACKUP_DIR"/ 2>/dev/null || true
  info "已备份原配置到 $BACKUP_DIR"
fi

# 废掉旧的 netplan 配置（保留备份）
find /etc/netplan -maxdepth 1 -name '*.yaml' -delete 2>/dev/null || true

# 禁用 cloud-init 网络接管
mkdir -p /etc/cloud/cloud.cfg.d
echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

gen > "$CONF_PATH"
chmod 600 "$CONF_PATH"
info "已写入 $CONF_PATH"

# 同步 DNS 到 /etc/resolv.conf（DD 后它常被 systemd-resolved 接管为 stub 链接，导致 DNS 不生效）
if [[ "$WRITE_RESOLV" =~ ^[Yy] ]]; then
  if [[ -e /etc/resolv.conf || -L /etc/resolv.conf ]]; then
    cp -a /etc/resolv.conf "$BACKUP_DIR/resolv.conf.bak" 2>/dev/null || true
    readlink /etc/resolv.conf > "$BACKUP_DIR/resolv.conf.bak.link" 2>/dev/null || true
  fi
  chattr -i /etc/resolv.conf 2>/dev/null || true
  rm -f /etc/resolv.conf
  gen_resolv > /etc/resolv.conf
  chmod 644 /etc/resolv.conf
  info "已写入 /etc/resolv.conf（原链接备份于 $BACKUP_DIR/resolv.conf.bak*）"
fi

# ---------- 校验并应用 ----------
if ! command -v netplan >/dev/null 2>&1; then
  err "未找到 netplan 命令，请确认系统使用 netplan 管理网络。"
  exit 1
fi

if ! netplan generate 2>/tmp/.fix-net-err; then
  err "配置校验失败："
  cat /tmp/.fix-net-err >&2
  err "已保留改动但未 apply；可执行 cp -a $BACKUP_DIR/. /etc/netplan/ 回滚。"
  exit 1
fi
info "netplan 校验通过。"

echo
warn "即将应用网络配置。若你是 SSH 连接，网关或地址有误会立即断线。"
echo "  安全做法：下面用 netplan try（60 秒内不确认会自动回滚）。"
read -rp "应用方式：回车=netplan try（推荐），输入 a=直接 apply: " APPLY_MODE
echo
if [[ "$APPLY_MODE" =~ ^[Aa] ]]; then
  netplan apply && info "已应用。回滚备份：$BACKUP_DIR"
else
  if [[ -t 0 ]]; then
    netplan try --timeout 60 || { warn "未确认，配置已自动回滚。备份：$BACKUP_DIR"; exit 1; }
    info "已应用并确认。回滚备份：$BACKUP_DIR"
  else
    warn "当前非交互终端，netplan try 不可用，改为直接 apply。"
    netplan apply && info "已应用。回滚备份：$BACKUP_DIR"
  fi
fi

echo
info "完成。核对："
ip -br addr 2>/dev/null || true
ip route 2>/dev/null || true
