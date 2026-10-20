#!/usr/bin/env bash
# ==============================================================================
# apply-z1-config.sh - 在 Arch linux-lts 6.18 基线之上应用 "z1" 差异集
#
# 用法:  ./apply-z1-config.sh [perf|diag]
#   perf (默认)  交付镜像: 关全部调试设施, 追求小体积 + 低占用
#   diag         诊断变体: 开 BTF + ftrace, 供 perf/bpftrace 剖析使用
#
#   高性能  = PREEMPT_DYNAMIC 单镜像多档 + CPU 分区能力(nohz_full/rcu_nocbs/isolcpus)
#   小体积  = 砍 NR_CPUS 静态 percpu、关 DEBUG_INFO/BTF、strip、模块 zstd
#   低占用  = 关 SLUB_DEBUG/PAGE_POISONING/函数级 tracer
#   广驱动  = 驱动面完全不动(基线 6228 个 =m 模块), 禁用 localmodconfig
#
# 幂等: 可重复执行。
#
# 重要 (6.18 实测): scripts/config 是 bash 实现, 一条命令只接受【一个】符号。
#   传多个符号时第二个会被当成命令本身, 报 "bad command: XXX"。
#   故统一走 c_enable/c_disable 包装, 每个符号单独调用一次。
# ==============================================================================
set -euo pipefail

SRC="${SRC:-$HOME/kb/linux-6.18.57}"
VARIANT="${1:-perf}"
KERNEL_COMPRESS="${KERNEL_COMPRESS:-lz4}"   # bzImage 压缩: lz4(启动快) | zstd(体积更小)
NR_CPUS="${NR_CPUS:-512}"                   # 基线是 8192, 每 CPU 约 +8KB 静态 percpu 区
LOCALVER="${LOCALVER:--z1}"

cd "$SRC"
[ -f scripts/config ] || { echo "错误: $SRC 不是内核源码树(缺 scripts/config)" >&2; exit 1; }
[ -f .config ]        || { echo "错误: 缺 .config, 请先跑 build-z1.sh prepare" >&2; exit 1; }

cp -f .config ".config.bak.$(date +%s)"
C=scripts/config

# 每个符号单独一次调用 (scripts/config 不支持一命令多符号)
c_enable()  { local s; for s in "$@"; do $C --enable  "$s"; done; }
c_disable() { local s; for s in "$@"; do $C --disable "$s"; done; }

echo "==> 变体: $VARIANT | bzImage 压缩: $KERNEL_COMPRESS | NR_CPUS: $NR_CPUS"

# ---------- 1. 规模控制: 体积与运行时占用的最大单项 ----------
# 基线 NR_CPUS=8192, 根因是 CONFIG_MAXSMP=y:
#   arch/x86/Kconfig 里 NR_CPUS 的 prompt 条件是 "if SMP && !MAXSMP",
#   MAXSMP=y 时它直接不可配, 且 NR_CPUS_DEFAULT 被钉死 8192;
#   CPUMASK_OFFSTACK 同理被 select 打开(range end 也变 8192)。
# 所以必须【先关 MAXSMP】, NR_CPUS 才真正可写。
# 降容收益: 静态 percpu 区 + cpumask 位图随 NR_CPUS 线性增长,
#   8192 -> 512 大约省 60MB 常驻; 同时关掉 CPUMASK_OFFSTACK 省掉每次调度
#   路径上的动态 cpumask 分配开销。512 仍覆盖双路 EPYC(384 线程)。
c_disable MAXSMP CPUMASK_OFFSTACK
# EXPERT 是打开多个调试项 prompt 的总闸(如 SLUB_DEBUG), 必须放出来才能关它们。
# 这里开 EXPERT 不是为了用它的功能, 而是为了获得"能关"的权限。
c_enable  EXPERT
$C --set-val NR_CPUS "$NR_CPUS"

# ---------- 2. 抢占与调度: 一个镜像覆盖多档 ----------
# PREEMPT_DYNAMIC 允许启动时用 preempt=none|voluntary|full|lazy 切换,
# 构建期只需指定默认档。这里默认 full(低延迟优先), 吞吐档通过 GRUB 项切。
c_enable  PREEMPT_DYNAMIC
c_disable PREEMPT_NONE PREEMPT_VOLUNTARY
c_enable  PREEMPT                       # 动态模式下的默认档 = full
c_enable  HZ_1000
c_disable HZ_300 HZ_250 HZ_100
$C --set-val HZ 1000
c_enable  NO_HZ_FULL RCU_NOCB_CPU CPUSETS
c_disable SCHED_AUTOGROUP               # 避免交互/吞吐混合负载下的抖动
# 注意: PREEMPT_DYNAMIC 与 PREEMPT_RT 在 Kconfig 中互斥, 硬实时需单独构建 RT 变体。

# ---------- 3. 压缩分工: zstd 管体积、lz4 管启动速度 ----------
case "$KERNEL_COMPRESS" in
  lz4)  c_enable  KERNEL_LZ4
        c_disable KERNEL_ZSTD KERNEL_GZIP KERNEL_XZ KERNEL_LZMA ;;
  zstd) c_enable  KERNEL_ZSTD
        c_disable KERNEL_LZ4  KERNEL_GZIP KERNEL_XZ KERNEL_LZMA ;;
  *)    echo "错误: KERNEL_COMPRESS 只能是 lz4 或 zstd" >&2; exit 1 ;;
esac
# 内核模块: Kconfig 模块压缩无 lz4 选项, zstd 比率最优(基线已是 zstd, 保持)
c_enable MODULE_COMPRESS MODULE_COMPRESS_ALL MODULE_COMPRESS_ZSTD MODULE_DECOMPRESS
# initramfs 两种解压器都内置, 便于 lz4/zstd 两种 initramfs A/B
c_enable RD_ZSTD RD_LZ4

# ---------- 4. 启动链可靠性: NVMe 提升为内置 ----------
# 基线 BLK_DEV_NVME=m, NVMe 根盘机器一旦 initramfs 缺模块即 "Unable to mount root fs"。
# 目标定位是"装到各种机器", 故提升为内置(约 +200KB, 换取换机可启动性)。
c_enable NVME_CORE BLK_DEV_NVME

# ---------- 5. 交付变体: 砍调试设施(体积 + 占用 + 性能三重收益) ----------
if [ "$VARIANT" = perf ]; then
  c_disable DEBUG_INFO DEBUG_INFO_BTF DEBUG_INFO_BTF_MODULES \
            DEBUG_INFO_DWARF5 DEBUG_INFO_COMPRESSED_ZLIB
  c_disable SLUB_DEBUG PAGE_POISONING
  c_disable FUNCTION_TRACER GRAPH_TRACER DYNAMIC_FTRACE \
            DYNAMIC_FTRACE_WITH_ARGS DYNAMIC_FTRACE_WITH_REGS \
            DYNAMIC_FTRACE_WITH_DIRECT_CALLS
  # 保留 FTRACE + FTRACE_SYSCALLS: tracepoint 是 perf 的数据来源, 成本极低
else
  echo "    (diag 变体: 保留 BTF + ftrace, 供 bpftrace/perf 剖析)"
  c_enable DEBUG_INFO DEBUG_INFO_BTF DEBUG_INFO_BTF_MODULES DEBUG_INFO_DWARF5
  c_enable FUNCTION_TRACER DYNAMIC_FTRACE GRAPH_TRACER
fi

# ---------- 6. 版本标识: 稳定 vermagic ----------
$C --set-str LOCALVERSION "$LOCALVER"
c_disable LOCALVERSION_AUTO            # 避免 git 脏树追加 -dirty 导致 vermagic 漂移

# ---------- 7. 体积削峰: 关掉 kheaders ----------
# IKHEADERS 会把整棵内核头文件打包成 kheaders.ko(.zst)+ 常量块，实测 4.4MB，
# 是模块目录里第二大的单项。它只服务于 BPF CO-RE 运行时编译等少数场景；
# 真正编译外部模块的人装 linux-headers 包即可。
c_disable IKHEADERS

# ---------- 8. Rust 支持: 保证驱动面不缩水 ----------
# Arch 基线开启了 CONFIG_RUST=y(部分新驱动/子系统用 Rust 写)。
# 但 olddefconfig 只看工具链是否可用: 缺 rustc/bindgen 时会静默把 RUST 关掉,
# 于是这些驱动就消失了 —— 与"适配大部分驱动"目标直接冲突。
# 故这里显式重新打开, 并在下面断言; 若构建机缺 rustc, 断言会明确报错而不是静默降级。
c_enable RUST

# ---------- 明确保留(不动): 驱动广度与关键性能项 ----------
# 驱动面: 基线 6228 个 =m 模块(网卡 51 项 / DRM 59 项 / 存储无线声卡全量)完全不动
# 保留: CC_OPTIMIZE_FOR_PERFORMANCE(-O2)、SLUB、UNWINDER_ORC、MODULE_SIG(in-tree 自动签名)
# 明确不开: TRIM_UNUSED_KSYMS(与 NVIDIA DKMS/VirtualBox/ZFS 冲突)、
#           LTO_CLANG(DKMS/objtool 兼容风险)、CC_OPTIMIZE_FOR_SIZE(-Os 伤吞吐)

make olddefconfig

# ---------- 复核报告 ----------
echo
echo "==> 复核(这些值必须如预期, 否则停止编译)"
grep -E '^(CONFIG_NR_CPUS|CONFIG_HZ|CONFIG_PREEMPT_DYNAMIC|CONFIG_PREEMPT|CONFIG_PREEMPT_RT|CONFIG_KERNEL_(LZ4|ZSTD)|CONFIG_MODULE_COMPRESS_ZSTD|CONFIG_DEBUG_INFO|CONFIG_DEBUG_INFO_BTF|CONFIG_SLUB_DEBUG|CONFIG_PAGE_POISONING|CONFIG_FUNCTION_TRACER|CONFIG_LOCALVERSION|CONFIG_BLK_DEV_NVME|CONFIG_SCHED_AUTOGROUP)=' .config | sort

echo
echo "==> 断言"
fail=0
chk() { # chk "期望" "实际"
  if [ "$2" = "$1" ]; then echo "  OK   $2"; else echo "  FAIL 期望=$1 实际=$2"; fail=1; fi
}
chk "CONFIG_NR_CPUS=$NR_CPUS"            "$(grep -m1 '^CONFIG_NR_CPUS=' .config)"
chk "CONFIG_HZ=1000"                     "$(grep -m1 '^CONFIG_HZ=' .config)"
chk "CONFIG_PREEMPT_DYNAMIC=y"           "$(grep -m1 '^CONFIG_PREEMPT_DYNAMIC=' .config)"
chk "CONFIG_BLK_DEV_NVME=y"              "$(grep -m1 '^CONFIG_BLK_DEV_NVME=' .config)"
chk "CONFIG_MODULE_COMPRESS_ZSTD=y"      "$(grep -m1 '^CONFIG_MODULE_COMPRESS_ZSTD=' .config)"
chk "CONFIG_LOCALVERSION=\"$LOCALVER\""  "$(grep -m1 '^CONFIG_LOCALVERSION=' .config)"
# Rust 支持必须保住: 否则 Rust 写的驱动会从模块清单里消失(而 --disable 是不可见的)
chk "CONFIG_RUST=y"                      "$(grep -m1 '^CONFIG_RUST=' .config)"
if [ "$VARIANT" = perf ]; then
  ! grep -q '^CONFIG_DEBUG_INFO=y' .config && echo "  OK   DEBUG_INFO 已关" || { echo "  FAIL DEBUG_INFO 仍开"; fail=1; }
  ! grep -q '^CONFIG_SLUB_DEBUG=y' .config && echo "  OK   SLUB_DEBUG 已关" || { echo "  FAIL SLUB_DEBUG 仍开"; fail=1; }
fi
echo -n "==> 驱动广度回归检查(=m 模块数, 基线约 6228): "
grep -c '=m' .config

[ $fail -eq 0 ] || { echo "断言未通过, 请检查后再编译" >&2; exit 1; }
echo "==> config 就绪: $SRC/.config"
