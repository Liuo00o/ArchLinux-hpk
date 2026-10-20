# z1 — 高性能精简 Linux 内核

<div align="center">

![Kernel](https://img.shields.io/badge/Linux%20Kernel-6.18.57%20LTS-blue.svg)
![Platform](https://img.shields.io/badge/platform-x86__64-green.svg)
![Target](https://img.shields.io/badge/target-Arch%20Linux-1793d1.svg)
![Build](https://img.shields.io/badge/build-WSL2%20%2F%20Linux-orange.svg)
![License](https://img.shields.io/badge/license-GPL--2.0-red.svg)

**简体中文** · [English](#english) · [Русский](#русский) · [Français](#français)

</div>

---

## 简体中文

### 项目说明

我维护 z1 的起因很直接：手上有一批硬件差异很大的机器，既要跑吞吐密集的负载，又要压住延迟敏感任务的尾延迟，同时不希望内核镜像和常驻内存无谓地膨胀。

市面上的选择总是偏科——发行版通用内核驱动面够广，但带着一堆调试设施和按 8192 核预留的静态开销；极致裁剪的内核体积小，但换一台机器就可能起不来。所以我自己做了一份：

- 基线取 **Linux 6.18.57 LTS**（kernel.org 当前 longterm，EOL 2028-12）
- 配置基线取 **Arch Linux `linux-lts` 包**的 `config.x86_64`——它的 `pkgver` 恰好就是 6.18.57，与源码版本完全对齐
- 用 `CONFIG_PREEMPT_DYNAMIC` 让**一个镜像**覆盖三种抢占档位，再配合 CPU 分区同时拿到吞吐与低延迟
- 压缩按**解压频率**分工：内核镜像 LZ4、模块与 initramfs zstd

三条硬约束（小体积 / 低占用 / 广驱动）之间是有张力的，我把每一处取舍都记在文档里，包括代价——不打算用「又快又小又全」这种空话糊弄过去。

### 当前进度（2025-10-20）

编译阶段已完成，验收指标中「小文件体积」一项也已达标；其余仍需真机实测。

| 阶段 | 状态 | 依据 |
|---|---|---|
| 立项 / 基线选定 | 完成 | Arch `linux-lts` = 6.18.57，与源码版本对齐 |
| 瓶颈诊断 / 配置差异集 | 完成 | 280 行 config 变更，9 项断言全绿 |
| 编译 | **完成** | `6.18.57-z1`，WSL2 内 25m51s |
| 小文件体积 | **达标 −14.3%** | 133.48 MB vs Arch 官方 155.8 MB |
| 驱动广度 | 达标（静态） | `=m` 6221，仅少 7 项意图内变更 |
| 真机冷启动（≥3 台） | **未做** | 无可用物理机 |
| 吞吐 / 延迟 A/B | **未做** | 需目标机 `metrics.sh` |

> 还没有在真机上引导过这个内核。体积与配置层面的结论可信，
> 启动、吞吐、延迟三组数据必须上机后再谈。

> 这不是一份「调几个参数就能更快」的参数集合。每处改动都有对应的诊断依据或上游 Kconfig 依据，每条结论都要能被 A/B 数据复现。

### 实现目标

| 约束 | 量化指标 | 验收方式 |
|---|---|---|
| 小文件体积 | bzImage、`/lib/modules`、initramfs 三处体积相对同版本官方内核均不上升，模块目录下降 ≥ 10% | `metrics.sh build` |
| 低系统占用 | 开机后 `MemAvailable` 上升；`Slab` / `KernelStack` / `PageTables` 不上升；已加载模块数不上升 | `metrics.sh boot` |
| 适配大部分驱动 | 基线 6228 个 `=m` 模块一个不删；在 ≥3 台不同硬件完成冷启动 | 换机实测 |
| 高吞吐 | `hackbench`、fio 随机读 IOPS 相对基线不退化 | `metrics.sh perf` |
| 低延迟 | isolated 核 `cyclictest` 最大延迟显著低于 housekeeping 核 | `metrics.sh perf` |
| 可复现 | `.config`、启动参数、sysctl 全部版本化，任意节点可按文档重建 | 从零重建演练 |
| 可回滚 | 保留原内核与旧 GRUB 项，单次回滚 ≤ 5 分钟 | 回滚演练 |

### 仓库结构

```
00-文档/                   计划书 v1.0 / v1.1（docx + Markdown）、构建与交付手册
01-基线配置/               config-lts-6.18.x86_64 —— 唯一可信的基线
02-构建脚本/               build-z1.sh、apply-z1-config.sh
03-部署配置/               mkinitcpio-z1.conf、grub-40-custom-z1
04-度量/                   metrics.sh（输出 CSV，做 A/B）
05-工具/                   make_v11.py、docx2md.py
06-构建产物/               编译输出落点（linux-z1-*.tar.zst）
09-参考-非本项目基线/       Arch 主线 7.2.11 素材，仅供对照，勿用于编译 6.18
```

### 使用教程

#### 步骤 0 — 准备环境

编译需要 Linux 环境（WSL2 或物理机均可）。以 WSL2 + Ubuntu 24.04 为例：

```bash
sudo apt-get update && sudo apt-get install -y \
  build-essential libncurses-dev bison flex libssl-dev libelf-dev \
  bc cpio kmod rsync tar git zstd lz4 python3 dwarves
```

`.wslconfig` 建议限制资源，避免宿主被吃满：

```ini
[wsl2]
memory=20GB
processors=20
swap=8GB
```

> **两个容易踩的坑**
> 1. 源码必须放在 ext4 原生目录（如 `~/kb`），**不要放 `/mnt/c`** —— 9P 文件系统慢 5–10 倍。
> 2. 编译机的 gcc 主版本若**低于**目标机，NVIDIA / VirtualBox / ZFS 等 DKMS 模块会因 **vermagic 不匹配**拒绝加载。最稳的做法是在与目标机同发行版的环境内编译。

#### 步骤 1 — 获取源码与基线

```bash
mkdir -p ~/kb && cd ~/kb
wget -qO- https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.57.tar.xz | tar -xJ
cd linux-6.18.57

# 版本对齐的基线：Arch linux-lts 包
curl -sSL -o .config \
  https://gitlab.archlinux.org/archlinux/packaging/packages/linux-lts/-/raw/main/config.x86_64
make olddefconfig
```

#### 步骤 2 — 应用 z1 差异集

```bash
./apply-z1-config.sh perf     # 交付变体：关全部调试设施
./apply-z1-config.sh diag     # 诊断变体：开 BTF + ftrace，供 perf/bpftrace 剖析
```

脚本执行完会打印复核结果与断言，这几项必须如预期：

```
CONFIG_NR_CPUS=512            CONFIG_HZ=1000
CONFIG_PREEMPT_DYNAMIC=y      CONFIG_BLK_DEV_NVME=y
CONFIG_MODULE_COMPRESS_ZSTD=y CONFIG_LOCALVERSION="-z1"
```

#### 步骤 3 — 编译与打包

```bash
make -j16 2>&1 | tee build.log
make -j16 modules

export S=~/kb/stage && rm -rf $S && mkdir -p $S
make INSTALL_MOD_PATH=$S INSTALL_MOD_STRIP=1 modules_install   # strip 是体积关键
make INSTALL_PATH=$S/boot install
tar -C $S -caf ~/kb/linux-z1-perf.tar.zst .
```

#### 步骤 4 — 安装到目标机（Arch）

```bash
sudo tar -C / -xaf linux-z1-perf.tar.zst
sudo cp mkinitcpio-z1.conf /etc/mkinitcpio-z1.conf
KREL=$(ls /lib/modules | grep z1)

# 通用 initramfs。关键：HOOKS 里没有 autodetect
sudo mkinitcpio -k "$KREL" -g /boot/initramfs-z1.img -c /etc/mkinitcpio-z1.conf

# 【必做】校验根盘与根文件系统驱动确实在里面
lsinitramfs /boot/initramfs-z1.img | grep -E 'nvme|ahci|sd_mod|ext4|xfs|btrfs'

sudo grub-mkconfig -o /boot/grub/grub.cfg
```

#### 步骤 5 — 选择启动档位

`grub-40-custom-z1` 提供三档，核划分按目标机实际核数调整：

| 档位 | 启动参数要点 | 适用 |
|---|---|---|
| 吞吐档 | `preempt=none` + `irqaffinity` 收拢中断 | 数据库、网络转发 |
| 低延迟档 | `preempt=full threadirqs` + `nohz_full` / `rcu_nocbs` | 实时控制、音视频 |
| 硬实时档 | 需要单独构建 `PREEMPT_RT` 变体 | 硬实时需求 |

```bash
# 把低延迟任务真正钉到隔离核上
taskset -c 12-23 <your-latency-critical-app>
```

#### 步骤 6 — A/B 度量

```bash
./metrics.sh boot baseline && ./metrics.sh perf baseline   # 换内核前
./metrics.sh boot z1      && ./metrics.sh perf z1          # 换内核后
```

用户态保持不变，只换内核与启动参数；每场景 3 次取中位数，方差 >5% 先收敛噪声再比。

#### 步骤 7 — 回滚

**新内核首次成功启动前，绝不删除原内核。** 起不来就在 GRUB 选旧项，然后：

```bash
sudo rm -f /boot/vmlinuz-$KREL /boot/initramfs-z1.img /boot/config-$KREL
sudo rm -rf /lib/modules/$KREL
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

### 核心取舍

| 矛盾 | 解法 | 代价 |
|---|---|---|
| 广驱动 vs 小体积 | 内核本体只留启动链闭包并编为内置，驱动全部 `=m`；**禁用 `localmodconfig`** | 通用 initramfs 约 45MB → 128MB |
| 吞吐 vs 低延迟 | `PREEMPT_DYNAMIC` 多档启动参数 + CPU 分区 | 档位是全局的，需按负载选；硬实时要单独镜像 |
| 小体积 vs 启动快 | 按解压频率分工：镜像 LZ4、模块与 initramfs zstd | 放弃 XZ 的极致压缩率 |

**明确不做的事**（都有踩坑依据）：`TRIM_UNUSED_KSYMS`（与 NVIDIA DKMS / VirtualBox / ZFS 冲突）、`LTO_CLANG`（objtool 兼容风险）、`CC_OPTIMIZE_FOR_SIZE`（`-Os` 省 5–8% 体积但伤吞吐）、`localmodconfig`（漏未连接的外设与虚拟化模块）。

### 风险

| 风险 | 应对 |
|---|---|
| `NR_CPUS` 降至 512，超 512 线程机器会被截断 | 部署清单标注；此类机器用 8192 重建 |
| 关闭 BTF 导致 bpftrace 不可用 | 用 `diag` 变体做剖析，交付仍用 `perf` 变体 |
| DKMS 模块 vermagic 不匹配 | 编译环境与目标发行版对齐，或 MOK 签名 |
| Secure Boot 拦截未签名模块 | 预先 `sbctl sign` 或 MOK 注册 |
| 根盘驱动缺失导致换机无法启动 | NVMe 提升为内置；安装后用 `lsinitramfs` 校验 |

### 许可

GPL-2.0。`.config` 派生自 Linux 内核与 Arch Linux 打包配置，同样遵循 GPL-2.0。

---

## English

### Project Overview

I maintain z1 because I needed one kernel image that could serve machines with very different hardware, run throughput-heavy workloads, and still keep tail latency under control for delay-sensitive tasks — without the image or resident memory ballooning.

The available options are all lopsided. Distribution kernels cover enough drivers but ship debug facilities and static per-CPU overhead sized for 8192 CPUs. Aggressively trimmed kernels are small but may not boot on a different machine. So I built my own:

- Baseline: **Linux 6.18.57 LTS** (current kernel.org longterm, EOL 2028-12)
- Config baseline: Arch Linux **`linux-lts`** package `config.x86_64` — its `pkgver` is exactly 6.18.57, so it lines up with the source tree
- `CONFIG_PREEMPT_DYNAMIC` lets **one image** cover three preemption modes; combined with CPU partitioning it delivers both throughput and low latency
- Compression split by **decompression frequency**: LZ4 for the kernel image, zstd for modules and initramfs

The three hard constraints (small size / low footprint / wide driver coverage) pull against each other. Every trade-off is documented together with its cost — I am not going to pretend something can be fast, small, and complete all at once.

> This is not a bag of "tweak these magic parameters". Every change has either diagnostic evidence or an upstream Kconfig justification, and every claim must be reproducible by A/B measurement.

### Goals

| Constraint | Metric | How verified |
|---|---|---|
| Small size | bzImage, `/lib/modules`, initramfs all no larger than the same-version distro kernel; module directory ≥ 10% smaller | `metrics.sh build` |
| Low footprint | `MemAvailable` up after boot; `Slab` / `KernelStack` / `PageTables` not up; loaded module count not up | `metrics.sh boot` |
| Wide driver coverage | All 6228 baseline `=m` modules kept; cold boot verified on ≥ 3 different machines | cross-machine testing |
| Throughput | `hackbench` and fio random-read IOPS no worse than baseline | `metrics.sh perf` |
| Low latency | `cyclictest` max latency on isolated cores clearly below housekeeping cores | `metrics.sh perf` |
| Reproducible | `.config`, boot parameters, sysctl all version-controlled | rebuild-from-scratch drill |
| Reversible | Original kernel and old GRUB entries kept; single rollback ≤ 5 min | rollback drill |

### Repository Layout

```
00-docs/                 plan v1.0 / v1.1 (docx + Markdown), build & delivery handbook
01-baseline/             config-lts-6.18.x86_64 — the only trusted baseline
02-build/                build-z1.sh, apply-z1-config.sh
03-deploy/               mkinitcpio-z1.conf, grub-40-custom-z1
04-metrics/              metrics.sh (CSV output for A/B)
05-tools/                make_v11.py, docx2md.py
06-artifacts/            build output (linux-z1-*.tar.zst)
09-reference-not-baseline/  Arch mainline 7.2.11 material, comparison only
```

### Usage

#### Step 0 — Environment

```bash
sudo apt-get update && sudo apt-get install -y \
  build-essential libncurses-dev bison flex libssl-dev libelf-dev \
  bc cpio kmod rsync tar git zstd lz4 python3 dwarves
```

Suggested `.wslconfig` limits so the host is not starved:

```ini
[wsl2]
memory=20GB
processors=20
swap=8GB
```

> **Two common traps**
> 1. Keep sources on a native ext4 directory (e.g. `~/kb`), **not `/mnt/c`** — the 9P filesystem is 5–10× slower.
> 2. If the build host's gcc major version is **lower** than the target's, DKMS modules (NVIDIA / VirtualBox / ZFS) will be refused with a **vermagic mismatch**. Build inside the same distro as the target whenever possible.

#### Step 1 — Source and baseline

```bash
mkdir -p ~/kb && cd ~/kb
wget -qO- https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.57.tar.xz | tar -xJ
cd linux-6.18.57

# Version-aligned baseline: the Arch linux-lts package
curl -sSL -o .config \
  https://gitlab.archlinux.org/archlinux/packaging/packages/linux-lts/-/raw/main/config.x86_64
make olddefconfig
```

#### Step 2 — Apply the z1 delta

```bash
./apply-z1-config.sh perf     # shipping variant: no debug facilities
./apply-z1-config.sh diag     # diagnostic variant: BTF + ftrace for perf/bpftrace
```

The script prints a verification block with assertions. These must match:

```
CONFIG_NR_CPUS=512            CONFIG_HZ=1000
CONFIG_PREEMPT_DYNAMIC=y      CONFIG_BLK_DEV_NVME=y
CONFIG_MODULE_COMPRESS_ZSTD=y CONFIG_LOCALVERSION="-z1"
```

#### Step 3 — Build and package

```bash
make -j16 2>&1 | tee build.log
make -j16 modules

export S=~/kb/stage && rm -rf $S && mkdir -p $S
make INSTALL_MOD_PATH=$S INSTALL_MOD_STRIP=1 modules_install   # strip is critical for size
make INSTALL_PATH=$S/boot install
tar -C $S -caf ~/kb/linux-z1-perf.tar.zst .
```

#### Step 4 — Install on the Arch target

```bash
sudo tar -C / -xaf linux-z1-perf.tar.zst
sudo cp mkinitcpio-z1.conf /etc/mkinitcpio-z1.conf
KREL=$(ls /lib/modules | grep z1)

# Generic initramfs. Key point: no autodetect in HOOKS
sudo mkinitcpio -k "$KREL" -g /boot/initramfs-z1.img -c /etc/mkinitcpio-z1.conf

# MUST DO: verify root disk and root filesystem drivers are present
lsinitramfs /boot/initramfs-z1.img | grep -E 'nvme|ahci|sd_mod|ext4|xfs|btrfs'

sudo grub-mkconfig -o /boot/grub/grub.cfg
```

#### Step 5 — Pick a boot profile

`grub-40-custom-z1` ships three profiles; adjust core ranges to the target machine:

| Profile | Key parameters | For |
|---|---|---|
| Throughput | `preempt=none` + `irqaffinity` pinning interrupts | databases, packet forwarding |
| Low latency | `preempt=full threadirqs` + `nohz_full` / `rcu_nocbs` | real-time control, audio/video |
| Hard real-time | requires a separate `PREEMPT_RT` build | hard RT requirements |

```bash
# Actually pin latency-critical work onto the isolated cores
taskset -c 12-23 <your-latency-critical-app>
```

#### Step 6 — A/B measurement

```bash
./metrics.sh boot baseline && ./metrics.sh perf baseline   # before
./metrics.sh boot z1      && ./metrics.sh perf z1          # after
```

Keep userspace fixed; swap only kernel and boot parameters. Take the median of 3 runs; if variance exceeds 5%, reduce noise before comparing.

#### Step 7 — Rollback

**Never delete the original kernel before the new one has booted successfully.** If it fails, pick the old GRUB entry, then:

```bash
sudo rm -f /boot/vmlinuz-$KREL /boot/initramfs-z1.img /boot/config-$KREL
sudo rm -rf /lib/modules/$KREL
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

### Key Trade-offs

| Conflict | Resolution | Cost |
|---|---|---|
| Wide drivers vs small size | Kernel image keeps only the boot-chain closure built-in; everything else `=m`; **`localmodconfig` disabled** | Generic initramfs ~45MB → ~128MB |
| Throughput vs low latency | `PREEMPT_DYNAMIC` boot profiles + CPU partitioning | Preemption mode is global; hard RT needs its own image |
| Small size vs fast boot | Split by decompression frequency: LZ4 image, zstd modules/initramfs | Gives up XZ's maximum ratio |

**Deliberately not done** (each has a concrete failure mode): `TRIM_UNUSED_KSYMS` (breaks NVIDIA DKMS / VirtualBox / ZFS), `LTO_CLANG` (objtool compatibility risk), `CC_OPTIMIZE_FOR_SIZE` (`-Os` saves 5–8% but hurts throughput), `localmodconfig` (misses disconnected peripherals and virtualization modules).

### Risks

| Risk | Mitigation |
|---|---|
| `NR_CPUS` reduced to 512 truncates machines above 512 threads | Flag in deployment inventory; rebuild with 8192 for those |
| Disabling BTF breaks bpftrace | Use the `diag` variant for profiling, ship the `perf` variant |
| DKMS vermagic mismatch | Match build environment to target distro, or sign with MOK |
| Secure Boot rejects unsigned modules | Pre-register with `sbctl sign` or MOK |
| Missing root-disk driver bricks another machine | NVMe promoted to built-in; verify with `lsinitramfs` |

### License

GPL-2.0. The `.config` derives from the Linux kernel and Arch Linux packaging and is likewise GPL-2.0.

---

## Русский

### О проекте

Я веду z1 потому, что мне нужно было одно ядро для машин с очень разным «железом», которое одновременно выдерживает нагрузку, ориентированную на пропускную способность, и удерживает хвостовую задержку для задач, чувствительных к задержке, — при этом не раздувая ни образ, ни резидентную память.

Готовые варианты всегда однобоки. Дистрибутивные ядра покрывают достаточно драйверов, но несут отладочные механизмы и статические расходы, рассчитанные на 8192 CPU. Сильно урезанные ядра компактны, но могут не загрузиться на другой машине. Поэтому я собрал своё:

- База: **Linux 6.18.57 LTS** (текущая longterm-ветка kernel.org, EOL 2028-12)
- Базовая конфигурация: `config.x86_64` из пакета Arch Linux **`linux-lts`** — его `pkgver` равен ровно 6.18.57, то есть полностью совпадает с исходниками
- `CONFIG_PREEMPT_DYNAMIC` позволяет **одному образу** покрыть три режима вытеснения, а вместе с разбиением CPU даёт и пропускную способность, и низкую задержку
- Сжатие распределено по **частоте распаковки**: LZ4 для образа ядра, zstd для модулей и initramfs

Три жёстких требования (малый размер / низкое потребление / широкий охват драйверов) противоречат друг другу. Каждый компромисс задокументирован вместе с ценой — я не собираюсь делать вид, что можно получить «быстро, компактно и полностью» одновременно.

> Это не набор «магических параметров». У каждого изменения есть либо диагностическое обоснование, либо обоснование из上游 Kconfig, и каждый вывод должен воспроизводиться A/B-измерениями.

### Цели

| Требование | Метрика | Проверка |
|---|---|---|
| Малый размер | bzImage, `/lib/modules`, initramfs не больше, чем у дистрибутивного ядра той же версии; каталог модулей не менее чем на 10% меньше | `metrics.sh build` |
| Низкое потребление | После загрузки `MemAvailable` выше; `Slab` / `KernelStack` / `PageTables` не выросли; число загруженных модулей не выросло | `metrics.sh boot` |
| Широкий охват драйверов | Все 6228 базовых модулей `=m` сохранены; холодная загрузка проверена на ≥ 3 разных машинах | тесты на разных машинах |
| Пропускная способность | `hackbench` и IOPS fio при случайном чтении не хуже базы | `metrics.sh perf` |
| Низкая задержка | Максимальная задержка `cyclictest` на изолированных ядрах заметно ниже, чем на housekeeping-ядрах | `metrics.sh perf` |
| Воспроизводимость | `.config`, параметры загрузки и sysctl под контролем версий | тренировка сборки с нуля |
| Обратимость | Исходное ядро и старые записи GRUB сохранены; откат ≤ 5 минут | тренировка отката |

### Структура репозитория

```
00-docs/                 план v1.0 / v1.1 (docx + Markdown), руководство по сборке
01-baseline/             config-lts-6.18.x86_64 — единственная надёжная база
02-build/                build-z1.sh, apply-z1-config.sh
03-deploy/               mkinitcpio-z1.conf, grub-40-custom-z1
04-metrics/              metrics.sh (вывод CSV для A/B)
05-tools/                make_v11.py, docx2md.py
06-artifacts/            результат сборки (linux-z1-*.tar.zst)
09-reference-not-baseline/  материалы Arch mainline 7.2.11, только для сравнения
```

### Использование

#### Шаг 0 — Окружение

```bash
sudo apt-get update && sudo apt-get install -y \
  build-essential libncurses-dev bison flex libssl-dev libelf-dev \
  bc cpio kmod rsync tar git zstd lz4 python3 dwarves
```

Рекомендуемые ограничения в `.wslconfig`, чтобы не «съесть» хост:

```ini
[wsl2]
memory=20GB
processors=20
swap=8GB
```

> **Две частые ловушки**
> 1. Исходники должны лежать в родном каталоге ext4 (например `~/kb`), **не в `/mnt/c`** — файловая система 9P медленнее в 5–10 раз.
> 2. Если мажорная версия gcc на машине сборки **ниже**, чем на целевой, DKMS-модули (NVIDIA / VirtualBox / ZFS) будут отклонены из-за **несовпадения vermagic**. По возможности собирайте в том же дистрибутиве, что и целевая машина.

#### Шаг 1 — Исходники и база

```bash
mkdir -p ~/kb && cd ~/kb
wget -qO- https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.57.tar.xz | tar -xJ
cd linux-6.18.57

# База, совпадающая по версии: пакет Arch linux-lts
curl -sSL -o .config \
  https://gitlab.archlinux.org/archlinux/packaging/packages/linux-lts/-/raw/main/config.x86_64
make olddefconfig
```

#### Шаг 2 — Применить изменения z1

```bash
./apply-z1-config.sh perf     # вариант поставки: без отладочных механизмов
./apply-z1-config.sh diag     # диагностический вариант: BTF + ftrace для perf/bpftrace
```

Скрипт выводит блок проверки с утверждениями. Должно совпадать:

```
CONFIG_NR_CPUS=512            CONFIG_HZ=1000
CONFIG_PREEMPT_DYNAMIC=y      CONFIG_BLK_DEV_NVME=y
CONFIG_MODULE_COMPRESS_ZSTD=y CONFIG_LOCALVERSION="-z1"
```

#### Шаг 3 — Сборка и упаковка

```bash
make -j16 2>&1 | tee build.log
make -j16 modules

export S=~/kb/stage && rm -rf $S && mkdir -p $S
make INSTALL_MOD_PATH=$S INSTALL_MOD_STRIP=1 modules_install   # strip критичен для размера
make INSTALL_PATH=$S/boot install
tar -C $S -caf ~/kb/linux-z1-perf.tar.zst .
```

#### Шаг 4 — Установка на целевую машину (Arch)

```bash
sudo tar -C / -xaf linux-z1-perf.tar.zst
sudo cp mkinitcpio-z1.conf /etc/mkinitcpio-z1.conf
KREL=$(ls /lib/modules | grep z1)

# Универсальный initramfs. Ключевой момент: в HOOKS нет autodetect
sudo mkinitcpio -k "$KREL" -g /boot/initramfs-z1.img -c /etc/mkinitcpio-z1.conf

# ОБЯЗАТЕЛЬНО: проверить наличие драйверов корневого диска и ФС
lsinitramfs /boot/initramfs-z1.img | grep -E 'nvme|ahci|sd_mod|ext4|xfs|btrfs'

sudo grub-mkconfig -o /boot/grub/grub.cfg
```

#### Шаг 5 — Выбор профиля загрузки

`grub-40-custom-z1` содержит три профиля; диапазоны ядер уточните под конкретную машину:

| Профиль | Ключевые параметры | Для чего |
|---|---|---|
| Пропускная способность | `preempt=none` + `irqaffinity` (сбор прерываний) | СУБД, пересылка пакетов |
| Низкая задержка | `preempt=full threadirqs` + `nohz_full` / `rcu_nocbs` | управление в реальном времени, аудио/видео |
| Жёсткий реальное время | нужна отдельная сборка `PREEMPT_RT` | требования жёсткого РВ |

```bash
# Действительно закрепить критичную к задержке работу на изолированных ядрах
taskset -c 12-23 <ваша_чувствительная_к_задержке_программа>
```

#### Шаг 6 — A/B-измерения

```bash
./metrics.sh boot baseline && ./metrics.sh perf baseline   # до
./metrics.sh boot z1      && ./metrics.sh perf z1          # после
```

Пользовательское окружение не меняется; меняются только ядро и параметры загрузки. Медиана из 3 прогонов; при разбросе более 5% сначала снизьте шум.

#### Шаг 7 — Откат

**Никогда не удаляйте исходное ядро, пока новое не загрузилось успешно.** Если загрузка не удалась, выберите старую запись GRUB, затем:

```bash
sudo rm -f /boot/vmlinuz-$KREL /boot/initramfs-z1.img /boot/config-$KREL
sudo rm -rf /lib/modules/$KREL
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

### Основные компромиссы

| Противоречие | Решение | Цена |
|---|---|---|
| Широкий охват против малого размера | В ядро встроен только замыкание цепочки загрузки, остальное — `=m`; **`localmodconfig` отключён** | Универсальный initramfs ~45 МБ → ~128 МБ |
| Пропускная способность против задержки | Профили `PREEMPT_DYNAMIC` + разбиение CPU | Режим вытеснения глобален; для жёсткого РВ нужен отдельный образ |
| Малый размер против быстрой загрузки | Разделение по частоте распаковки: LZ4 для образа, zstd для модулей/initramfs | Отказ от максимальной степени XZ |

**Сознательно не делается** (у каждого пункта есть конкретный отказ): `TRIM_UNUSED_KSYMS` (ломает NVIDIA DKMS / VirtualBox / ZFS), `LTO_CLANG` (риск совместимости с objtool), `CC_OPTIMIZE_FOR_SIZE` (`-Os` экономит 5–8% размера, но вредит пропускной способности), `localmodconfig` (пропускает отключённые периферийные устройства и модули виртуализации).

### Риски

| Риск | Смягчение |
|---|---|
| `NR_CPUS` снижен до 512; машины с более чем 512 потоками будут обрезаны | Отметить в описи развёртывания; для таких машин пересобрать с 8192 |
| Отключение BTF ломает bpftrace | Профилировать вариантом `diag`, поставлять вариантом `perf` |
| Несовпадение vermagic у DKMS | Собирать в том же дистрибутиве, что и цель, либо подписать через MOK |
| Secure Boot отклоняет неподписанные модули | Заранее зарегистрировать через `sbctl sign` или MOK |
| Отсутствие драйвера корневого диска «окирпичит» другую машину | NVMe переведён во встроенные; проверять через `lsinitramfs` |

### Лицензия

GPL-2.0. `.config` является производной от ядра Linux и упаковки Arch Linux и также распространяется под GPL-2.0.

---

## Français

### Présentation du projet

Je maintiens z1 parce qu'il me fallait une seule image noyau capable de servir des machines au matériel très différent, d'encaisser des charges orientées débit tout en maîtrisant la latence de queue des tâches sensibles au délai — sans laisser gonfler ni l'image ni la mémoire résidente.

Les options disponibles sont toutes déséquilibrées. Les noyaux de distribution couvrent assez de pilotes mais embarquent des mécanismes de débogage et un surcoût statique dimensionné pour 8192 CPU. Les noyaux très élagués sont compacts mais risquent de ne pas démarrer sur une autre machine. J'ai donc fait le mien :

- Base : **Linux 6.18.57 LTS** (branche longterm actuelle de kernel.org, EOL 2028-12)
- Configuration de base : `config.x86_64` du paquet Arch Linux **`linux-lts`** — son `pkgver` vaut exactement 6.18.57, donc parfaitement aligné sur les sources
- `CONFIG_PREEMPT_DYNAMIC` permet à **une seule image** de couvrir trois modes de préemption ; combiné au partitionnement des CPU, il donne à la fois le débit et la faible latence
- Compression répartie selon la **fréquence de décompression** : LZ4 pour l'image noyau, zstd pour les modules et l'initramfs

Les trois contraintes fortes (petite taille / faible empreinte / large couverture de pilotes) tirent dans des directions opposées. Chaque compromis est documenté avec son coût — je ne prétendrai pas qu'on peut être à la fois rapide, petit et complet.

> Ceci n'est pas une collection de « paramètres magiques ». Chaque modification s'appuie soit sur un diagnostic, soit sur la documentation Kconfig amont, et chaque conclusion doit être reproductible par une mesure A/B.

### Objectifs

| Contrainte | Métrique | Vérification |
|---|---|---|
| Petite taille | bzImage, `/lib/modules`, initramfs non supérieurs au noyau de distribution de même version ; répertoire des modules inférieur d'au moins 10 % | `metrics.sh build` |
| Faible empreinte | Après démarrage, `MemAvailable` en hausse ; `Slab` / `KernelStack` / `PageTables` en non-hausse ; nombre de modules chargés en non-hausse | `metrics.sh boot` |
| Large couverture | Les 6228 modules `=m` de la base conservés ; démarrage à froid validé sur ≥ 3 machines différentes | tests multi-machines |
| Débit | `hackbench` et IOPS de lecture aléatoire fio non dégradés | `metrics.sh perf` |
| Faible latence | Latence maximale `cyclictest` sur cœurs isolés nettement inférieure à celle des cœurs housekeeping | `metrics.sh perf` |
| Reproductible | `.config`, paramètres de démarrage et sysctl sous gestion de versions | exercice de reconstruction |
| Réversible | Noyau d'origine et anciennes entrées GRUB conservés ; retour arrière ≤ 5 min | exercice de retour arrière |

### Structure du dépôt

```
00-docs/                 plan v1.0 / v1.1 (docx + Markdown), manuel de construction
01-baseline/             config-lts-6.18.x86_64 — la seule base fiable
02-build/                build-z1.sh, apply-z1-config.sh
03-deploy/               mkinitcpio-z1.conf, grub-40-custom-z1
04-metrics/              metrics.sh (sortie CSV pour A/B)
05-tools/                make_v11.py, docx2md.py
06-artifacts/            sortie de compilation (linux-z1-*.tar.zst)
09-reference-not-baseline/  éléments Arch mainline 7.2.11, comparaison uniquement
```

### Utilisation

#### Étape 0 — Environnement

```bash
sudo apt-get update && sudo apt-get install -y \
  build-essential libncurses-dev bison flex libssl-dev libelf-dev \
  bc cpio kmod rsync tar git zstd lz4 python3 dwarves
```

Limites conseillées dans `.wslconfig` pour ne pas affamer l'hôte :

```ini
[wsl2]
memory=20GB
processors=20
swap=8GB
```

> **Deux pièges fréquents**
> 1. Les sources doivent résider dans un répertoire ext4 natif (par ex. `~/kb`), **pas dans `/mnt/c`** — le système de fichiers 9P est 5 à 10× plus lent.
> 2. Si la version majeure de gcc sur l'hôte de compilation est **inférieure** à celle de la cible, les modules DKMS (NVIDIA / VirtualBox / ZFS) seront refusés pour **vermagic incompatible**. Compilez autant que possible dans la même distribution que la cible.

#### Étape 1 — Sources et base

```bash
mkdir -p ~/kb && cd ~/kb
wget -qO- https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.57.tar.xz | tar -xJ
cd linux-6.18.57

# Base alignée sur la version : le paquet Arch linux-lts
curl -sSL -o .config \
  https://gitlab.archlinux.org/archlinux/packaging/packages/linux-lts/-/raw/main/config.x86_64
make olddefconfig
```

#### Étape 2 — Appliquer le delta z1

```bash
./apply-z1-config.sh perf     # variante livrable : sans mécanismes de débogage
./apply-z1-config.sh diag     # variante diagnostic : BTF + ftrace pour perf/bpftrace
```

Le script affiche un bloc de vérification avec assertions. Doivent correspondre :

```
CONFIG_NR_CPUS=512            CONFIG_HZ=1000
CONFIG_PREEMPT_DYNAMIC=y      CONFIG_BLK_DEV_NVME=y
CONFIG_MODULE_COMPRESS_ZSTD=y CONFIG_LOCALVERSION="-z1"
```

#### Étape 3 — Compilation et empaquetage

```bash
make -j16 2>&1 | tee build.log
make -j16 modules

export S=~/kb/stage && rm -rf $S && mkdir -p $S
make INSTALL_MOD_PATH=$S INSTALL_MOD_STRIP=1 modules_install   # strip est critique pour la taille
make INSTALL_PATH=$S/boot install
tar -C $S -caf ~/kb/linux-z1-perf.tar.zst .
```

#### Étape 4 — Installation sur la cible (Arch)

```bash
sudo tar -C / -xaf linux-z1-perf.tar.zst
sudo cp mkinitcpio-z1.conf /etc/mkinitcpio-z1.conf
KREL=$(ls /lib/modules | grep z1)

# initramfs générique. Point clé : pas de autodetect dans HOOKS
sudo mkinitcpio -k "$KREL" -g /boot/initramfs-z1.img -c /etc/mkinitcpio-z1.conf

# OBLIGATOIRE : vérifier la présence des pilotes du disque racine et du système de fichiers
lsinitramfs /boot/initramfs-z1.img | grep -E 'nvme|ahci|sd_mod|ext4|xfs|btrfs'

sudo grub-mkconfig -o /boot/grub/grub.cfg
```

#### Étape 5 — Choisir un profil de démarrage

`grub-40-custom-z1` propose trois profils ; ajustez les plages de cœurs à la machine :

| Profil | Paramètres clés | Pour |
|---|---|---|
| Débit | `preempt=none` + `irqaffinity` (regroupement des interruptions) | bases de données, transfert de paquets |
| Faible latence | `preempt=full threadirqs` + `nohz_full` / `rcu_nocbs` | contrôle temps réel, audio/vidéo |
| Temps réel dur | nécessite une compilation `PREEMPT_RT` séparée | exigences temps réel strictes |

```bash
# Épingler réellement le travail sensible à la latence sur les cœurs isolés
taskset -c 12-23 <votre_application_sensible_à_la_latence>
```

#### Étape 6 — Mesure A/B

```bash
./metrics.sh boot baseline && ./metrics.sh perf baseline   # avant
./metrics.sh boot z1      && ./metrics.sh perf z1          # après
```

L'espace utilisateur ne change pas ; seuls le noyau et les paramètres de démarrage changent. Médiane de 3 exécutions ; si la variance dépasse 5 %, réduisez le bruit avant de comparer.

#### Étape 7 — Retour arrière

**Ne supprimez jamais le noyau d'origine avant que le nouveau n'ait démarré avec succès.** En cas d'échec, choisissez l'ancienne entrée GRUB, puis :

```bash
sudo rm -f /boot/vmlinuz-$KREL /boot/initramfs-z1.img /boot/config-$KREL
sudo rm -rf /lib/modules/$KREL
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

### Compromis clés

| Conflit | Résolution | Coût |
|---|---|---|
| Large couverture vs petite taille | Le noyau n'intègre que la fermeture de la chaîne de démarrage ; tout le reste en `=m` ; **`localmodconfig` désactivé** | initramfs générique ~45 Mo → ~128 Mo |
| Débit vs faible latence | Profils de démarrage `PREEMPT_DYNAMIC` + partitionnement des CPU | Le mode de préemption est global ; le temps réel dur exige une image dédiée |
| Petite taille vs démarrage rapide | Répartition selon la fréquence de décompression : LZ4 pour l'image, zstd pour modules/initramfs | On renonce au taux maximal de XZ |

**Délibérément non fait** (chacun a un mode de défaillance concret) : `TRIM_UNUSED_KSYMS` (casse NVIDIA DKMS / VirtualBox / ZFS), `LTO_CLANG` (risque de compatibilité objtool), `CC_OPTIMIZE_FOR_SIZE` (`-Os` économise 5–8 % de taille mais nuit au débit), `localmodconfig` (oublie les périphériques débranchés et les modules de virtualisation).

### Risques

| Risque | Atténuation |
|---|---|
| `NR_CPUS` abaissé à 512 tronque les machines à plus de 512 threads | Le noter dans l'inventaire de déploiement ; recompiler avec 8192 pour celles-là |
| La désactivation de BTF casse bpftrace | Profiler avec la variante `diag`, livrer la variante `perf` |
| Vermagic incompatible pour DKMS | Compiler dans la même distribution que la cible, ou signer via MOK |
| Secure Boot refuse les modules non signés | Enregistrer à l'avance avec `sbctl sign` ou MOK |
| Pilote de disque racine absent : la machine ne démarre plus | NVMe passé en intégré ; vérifier avec `lsinitramfs` |

### Licence

GPL-2.0. Le `.config` dérive du noyau Linux et de l'empaquetage Arch Linux, et est également sous GPL-2.0.

---

<div align="center">

[简体中文](#简体中文) · [English](#english) · [Русский](#русский) · [Français](#français)

</div>
