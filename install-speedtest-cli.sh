#!/usr/bin/env bash
#
# install-speedtest-cli.sh
# 安装 Ookla Speedtest CLI（官方二进制版）
# 跨 Linux 发行版通用，不依赖 apt/yum 源，彻底规避新发行版未被源收录的问题。
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

# ---------- 依赖检查 ----------
for cmd in curl tar; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "缺少 $cmd，请先安装后再运行。"
    exit 1
  fi
done

# ---------- 版本与架构 ----------
VERSION="1.2.0"

arch="$(uname -m)"
case "$arch" in
  x86_64|amd64)   pkgarch="x86_64" ;;
  aarch64|arm64)  pkgarch="aarch64" ;;
  armv7l|armhf)   pkgarch="armhf" ;;
  armel)          pkgarch="armel" ;;
  i386|i686)      pkgarch="i386" ;;
  *)
    err "不支持的架构：$arch"
    exit 1
    ;;
esac

url="https://install.speedtest.net/app/cli/ookla-speedtest-${VERSION}-linux-${pkgarch}.tgz"

# ---------- 下载并安装 ----------
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

info "下载 Speedtest CLI（${pkgarch}）..."
curl -fsSL "$url" -o "$tmpdir/speedtest.tgz"

info "解压并安装到 /usr/local/bin/speedtest ..."
tar -xzf "$tmpdir/speedtest.tgz" -C "$tmpdir"
install -m 0755 "$tmpdir/speedtest" /usr/local/bin/speedtest

# ---------- 验证 ----------
if command -v speedtest >/dev/null 2>&1; then
  echo ""
  info "安装完成！当前版本："
  speedtest --version || true
  echo ""
  info "运行测速：speedtest"
  info "查看所有服务器：speedtest -L"
else
  err "安装失败，未找到 speedtest 命令。"
  exit 1
fi
