#!/usr/bin/env bash
#
# install-speedtest-cli.sh
# 安装 Ookla Speedtest CLI（官方版）
# 支持 Debian/Ubuntu、RHEL/CentOS/Fedora，自动检测发行版。
#
# 用法：
#   sudo bash install-speedtest-cli.sh
#
set -euo pipefail

# ---------- 颜色输出 ----------
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; NC=''
fi

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ---------- 权限检查 ----------
if [[ $EUID -ne 0 ]]; then
  err "请使用 root 或 sudo 运行本脚本。"
  exit 1
fi

# ---------- 必备工具检查 ----------
if ! command -v curl >/dev/null 2>&1; then
  err "缺少 curl，请先安装（例如：apt-get install curl 或 yum install curl）。"
  exit 1
fi

detect_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_LIKE="${ID_LIKE:-}"
    OS_VER="${VERSION_ID:-}"
    OS_CODENAME="${VERSION_CODENAME:-}"
  else
    OS_ID=""
  fi
}

# ---------- 移除旧版/非官方冲突包 ----------
cleanup_conflicts() {
  warn "尝试移除可能冲突的旧版/非官方 speedtest 包（若存在）..."
  # bintray 时代的旧源
  rm -f /etc/apt/sources.list.d/speedtest.list 2>/dev/null || true
  rm -f /etc/yum.repos.d/bintray-ookla-rhel.repo 2>/dev/null || true
  # 非官方 Python 版 speedtest-cli
  apt-get remove -y speedtest-cli >/dev/null 2>&1 || true
  yum remove -y speedtest-cli >/dev/null 2>&1 || true
  dnf remove -y speedtest-cli >/dev/null 2>&1 || true
}

install_deb() {
  info "检测到 Debian/Ubuntu 系，使用 apt + packagecloud 源安装。"

  # 先确保 curl 存在（官方流程）
  apt-get update -y >/dev/null
  apt-get install -y curl gnupg >/dev/null

  # 添加官方源
  curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash

  # Ubuntu 新版本兼容处理：官方源仅支持到 jammy（22.04），
  # noble(24.04)、resolute(26.04) 等更新版本统一改用 jammy 源。
  local supported_codenames="trusty xenial bionic focal jammy"
  if [[ "$OS_ID" == "ubuntu" && -n "$OS_CODENAME" && " $supported_codenames " != *" $OS_CODENAME "* ]]; then
    warn "检测到 Ubuntu ($OS_CODENAME)，官方源暂无该版本包，自动改用 jammy 源。"
    grep -rl "$OS_CODENAME" /etc/apt/sources.list.d/ 2>/dev/null | while IFS= read -r f; do
      sed -i "s/$OS_CODENAME/jammy/g" "$f"
    done || true
  fi

  apt-get update -y >/dev/null
  apt-get install -y speedtest
}

install_rpm() {
  info "检测到 RHEL/CentOS/Fedora 系，使用 dnf/yum + packagecloud 源安装。"

  curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh | bash

  if command -v dnf >/dev/null 2>&1; then
    dnf install -y speedtest
  else
    yum install -y speedtest
  fi
}

install_other() {
  info "未识别的发行版，改用通用二进制安装（x86_64）。"
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64)       arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    armv7l|armhf)  arch="armhf" ;;
    i386|i686)     arch="i386" ;;
    *)
      err "不支持的架构：$arch"
      exit 1
      ;;
  esac

  local url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-${arch}.tgz"
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  info "下载：$url"
  curl -fsSL "$url" -o "$tmpdir/speedtest.tgz"
  tar -xzf "$tmpdir/speedtest.tgz" -C "$tmpdir"
  install -m 0755 "$tmpdir/speedtest" /usr/local/bin/speedtest
}

main() {
  info "开始安装 Ookla Speedtest CLI ..."

  detect_os
  cleanup_conflicts

  case "$OS_ID" in
    debian|ubuntu|raspbian|linuxmint)
      install_deb
      ;;
    rhel|centos|rocky|almalinux|fedora|ol|amzn)
      install_rpm
      ;;
    *)
      install_other
      ;;
  esac

  # ---------- 验证 ----------
  if command -v speedtest >/dev/null 2>&1; then
    echo ""
    info "安装完成！当前版本："
    speedtest --version || true
    echo ""
    info "运行测速：speedtest"
    info "查看所有服务器：speedtest -L"
  else
    err "安装后未找到 speedtest 命令，请检查日志。"
    exit 1
  fi
}

main "$@"
