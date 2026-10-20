#!/usr/bin/env bash
# ==============================================================================
# build-z1.sh — 6.18 LTS 定制内核构建 / 打包 全流程（WSL2 Ubuntu 内执行）
#
# 用法:
#   ./build-z1.sh prepare   # 装依赖 + 下载源码 + 拉 Arch 基线 config
#   ./build-z1.sh config    # 应用 z1 差异集（VARIANT=diag 可出诊断变体）
#   ./build-z1.sh build     # 编译（-j 自动取值，可用 JOBS= 覆盖）
#   ./build-z1.sh package   # strip + 打包成 linux-z1.tar.zst
#   ./build-z1.sh all       # 以上四步一次跑完
#
# 源码必须位于 WSL 的 ext4 原生目录（默认 ~/kb），禁止 /mnt/c —— 9P 会慢 5-10 倍。
# ==============================================================================
set -euo pipefail

VER=6.18.57
BASE="$HOME/kb"
SRC="$BASE/linux-$VER"
OUT="$BASE/out"
STAGE="$BASE/stage"
KB="${BASE}"                       # 产物落点
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 本脚本所在目录（含 apply-z1-config.sh）
ARCH_CFG_URL="https://gitlab.archlinux.org/archlinux/packaging/packages/linux-lts/-/raw/main/config.x86_64"
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${VER}.tar.xz"

JOBS="${JOBS:-$(nproc)}"
[ "$JOBS" -gt 16 ] && JOBS=16      # 不开 LTO 时峰值约 <1GB/线程，16 路留足余量给宿主
# 内存护栏：WSL2 是动态内存，按可用内存再压一次，避免宿主被拖入 swap
AVAIL_GB=$(awk '/MemAvailable/ {printf "%d", $2/1048576}' /proc/meminfo)
MEM_CAP=$(( AVAIL_GB * 10 / 12 ))   # 约每线程 1.2GB
if [ "$JOBS" -gt "$MEM_CAP" ]; then JOBS="$MEM_CAP"; fi
[ "$JOBS" -lt 1 ] && JOBS=1
echo "构建并行度 JOBS=$JOBS (nproc=$(nproc), 可用内存=${AVAIL_GB}GB)"
VARIANT="${VARIANT:-perf}"

log() { echo; echo "########## $* ##########"; }

do_prepare() {
  log "1/4 安装构建依赖"
  sudo apt-get update -qq
  sudo apt-get install -y -qq build-essential libncurses-dev bison flex libssl-dev \
    libelf-dev bc cpio kmod rsync tar git zstd lz4 python3 dwarves \
    ccache                                        # dwarves 提供 pahole（diag 变体开 BTF 时需要）

  log "2/4 下载内核源码 linux-$VER（约 148MB）"
  mkdir -p "$BASE"
  [ -d "$SRC" ] || { wget -q --show-progress -O "$BASE/linux-${VER}.tar.xz" "$KERNEL_URL"
                     tar -xf "$BASE/linux-${VER}.tar.xz" -C "$BASE"; }

  log "3/4 拉取版本对齐的基线 config"
  # 关键：Arch 的 linux-lts 包恰好就是 6.18.57，与源码版本完全一致。
  # 不要用主线 linux 包的 config（那是 7.x，套到 6.18 会被 olddefconfig 丢弃大量选项）。
  # 优先用随脚本一起落盘的本地基线（离线可复现），拿不到才回落到网络。
  cd "$SRC"
  LOCAL_CFG="$SELF_DIR/01-基线配置/config-lts-6.18.x86_64"
  [ -s "$LOCAL_CFG" ] || LOCAL_CFG="$SELF_DIR/../01-基线配置/config-lts-6.18.x86_64"
  if [ -s "$LOCAL_CFG" ]; then
    cp -f "$LOCAL_CFG" .config
    echo "  使用本地基线: $LOCAL_CFG"
  else
    curl -sSL -o .config "$ARCH_CFG_URL"
  fi
  [ -s .config ] || { echo "基线 config 下载失败" >&2; exit 1; }

  log "4/4 编译器版本核对（决定 DKMS 模块能否加载）"
  echo "  本机构建 gcc : $(gcc --version | head -1)"
  echo "  内核源码要求 : $(grep -m1 '^CONFIG_CC_VERSION_TEXT=' .config || echo '(基线未提供)')"
  cat <<'WARN'
  ⚠ 若目标 Arch 机器的 gcc major 高于本机，NVIDIA/VirtualBox/ZFS 等 DKMS 模块
    会因 vermagic 不匹配而拒绝加载。最稳做法是在 WSL2 内改用 Arch 环境构建。
    退路：目标机手动 modprobe -f，或本机安装同 major 的 gcc。
WARN
}

do_config() {
  log "应用 z1 差异集（变体: $VARIANT）"
  cd "$SRC"
  SRC="$SRC" VARIANT="$VARIANT" "$SELF_DIR/apply-z1-config.sh" "$VARIANT"
}

do_build() {
  log "编译 linux-$VER（JOBS=$JOBS，预计 20-40 分钟）"
  cd "$SRC"
  make -j"$JOBS" 2>&1 | tee "$BASE/build.log"
  make -j"$JOBS" modules 2>&1 | tee -a "$BASE/build.log"
  KREL=$(make -s kernelrelease)
  echo "$KREL" > "$BASE/.kernelrelease"
  log "内核版本: $KREL"
}

do_package() {
  cd "$SRC"
  KREL=$(make -s kernelrelease)
  log "打包 $KREL"
  rm -rf "$STAGE"; mkdir -p "$STAGE"
  # INSTALL_MOD_STRIP=1 是 /lib/modules 体积的关键（去符号表）
  make INSTALL_MOD_PATH="$STAGE" INSTALL_MOD_STRIP=1 modules_install
  make INSTALL_PATH="$STAGE/boot" install
  cp .config "$STAGE/boot/config-$KREL"
  cp "$BASE/build.log" "$STAGE/boot/build.log" 2>/dev/null || true

  log "产物体积基线"
  echo "  bzImage   : $(stat -c%s arch/x86/boot/bzImage) 字节"
  echo "  vmlinux   : $(stat -c%s vmlinux) 字节"
  echo "  模块目录  : $(du -sh "$STAGE/lib/modules/$KREL" | cut -f1)"
  echo "  模块个数  : $(find "$STAGE/lib/modules/$KREL" -name '*.ko*' | wc -l)"
  echo "  =m 配置项 : $(grep -c '=m' .config)"

  tar -C "$STAGE" -caf "$KB/linux-z1-${VARIANT}.tar.zst" .
  echo "  压缩包    : $(stat -c%s "$KB/linux-z1-${VARIANT}.tar.zst") 字节 -> $KB/linux-z1-${VARIANT}.tar.zst"
}

case "${1:-all}" in
  prepare) do_prepare ;;
  config)  do_config  ;;
  build)   do_build   ;;
  package) do_package ;;
  all)     do_prepare; do_config; do_build; do_package ;;
  *) echo "用法: $0 [prepare|config|build|package|all]" >&2; exit 1 ;;
esac
