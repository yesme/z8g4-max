# I7. 保留 HT，DeepSeek 启停时交还整颗物理核

F10 → Advanced → Performance Options 固定 NUMA 开、SNC 关，保持 HT、所有核心和 Turbo 开启。用默认调度跑一轮真实模型和 Buck2，再启用本节。生成器从 Linux sysfs 读取每个逻辑 CPU 所属的 socket 和同核 HT 线程，按每路独立分配。DDR4 节点号用 [T3 拓扑报告](PMEM.md#核对双路-numa-拓扑) 确认。

| 每路推理预留 | 双路可运行的推理线程 | 双路系统与编译可用线程 | Xolotl CPU expert worker 起点 |
|---|---:|---:|---:|
| 4 颗物理核 | 8 | 88 | 6 |
| **6 颗物理核（首装）** | **12** | **80** | **10** |
| 8 颗物理核 | 16 | 72 | 14 |
| **推理服务已停止（仍预留 6 核/路的 HT 伙伴）** | — | **92** | — |

以上按双路各 26 核、每核两个 HT 线程计算。已有 8269CY 的实机实验记录每颗 26 核、52 线程。每路用 K=N+1 颗核。停推理时每路系统与编译可用 52−K 个逻辑 CPU，双路 104−2K。运行时每路可用 2×(26−K)，双路 4×(26−K)。 [8269CY 实机实验平台](https://www.vldb.org/pvldb/vol17/p4827-li.pdf)

用每路内部的示意编号 `0↔26、1↔27、…、25↔51`，每路取最后六颗物理核时，推理用 20–25，对应 HT 伙伴 46–51 始终保留。普通任务在推理停机时用 0–45，推理启动后用 0–19 与 26–45。每路推理核中的第一颗留给主控，其余五颗进入 Xolotl 的 worker 列表。

Linux 的 CPU 号全机唯一。脚本按 `thread_siblings_list` 配对，每对取编号较小的 CPU 作“主线程”，每路按这个编号排序取最后 K 对。这样 CPU0 所在物理核留给普通任务和系统。cgroup 的 CPU 集合约束其中的进程。硬件 IRQ 与内核线程有自己的亲和性，用 `/proc/interrupts` 和 `ps -eLo pid,tid,psr,comm` 核正在跑的网卡、存储和推理负载。CPU 核的执行资源分开，socket 的 Turbo、功耗、末级缓存、DDR4、PMem 和 UPI 仍然共享。 [Linux CPU 拓扑](https://docs.kernel.org/admin-guide/cputopology.html) · [Linux cgroup v2 cpuset](https://docs.kernel.org/admin-guide/cgroup-v2.html#cpuset) · [Linux IRQ 亲和性](https://docs.kernel.org/core-api/irq/irq-affinity.html)

**6 核/路的估算。** Xolotl 的 DS4.1 支持 `--threads` 和 `STRATA_POOL_CORES`。首轮给 expert pool 每路 5 颗物理核，共 10 个 worker，再每路留 1 颗给引擎控制、CUDA 提交和其他 helper。此配置允许 12 个 CPU 线程同时运行，10 是 worker 的设定值。四张 V100 执行的 GPU kernel、pinned DDR4 到 GPU 的 DMA 与 CPU expert 路径分开计。实际 CPU 工作量由模型量化、expert 命中、CPU 回退比例、请求长度和并发决定。1Cat 的已公开路径有冷 expert staging 和长 prefill 的 Engram 并行读取，不能套 Xolotl 的 worker 数。沿用 launcher 的 `OMP_NUM_THREADS=1`，分别测 4/6/8 核每路；8 核/路是本轮扫参上界，若 6→8 仍显著改善并且 CPU 忙，再扩测。 [Xolotl DS4.1 参数](https://github.com/Indras-Mirror/Xolotl/blob/main/tools/v41/engine/ds41_generate.cpp) · [1Cat V4.1 cold expert 与 Engram 路径](https://github.com/1CatAI/1Cat-vLLM/blob/main/benchmarks/deepseek_v41/HANDOFF.md)

`z8-infer.service` 先把 `system.slice`、`user.slice`、`machine.slice` 和 `z8build.slice` 缩到编译集合，再启动模型。停止或启动失败时恢复普通任务的空闲集合，只交还推理的 12 个主线程；同核的 12 个 HT 伙伴一直排除。cgroup 更新会作用到正在运行的 Buck2 与 runner，已有进程主动设过的 affinity 也要一并核对。服务常驻时即使暂时没有 API 请求也保留核心。OMP/Pi/DSH 直连云端 API 不启动该服务。

`AllowedCPUs` 定运行位置。`CPUWeight` 决定同级 cgroup 争抢共同 CPU 时的相对份额。推理 slice 权重 200，构建 slice 权重 100，推理服务设普通调度的 `Nice=-5`。推理核的独占由 CPU 集合分配实现。已显式放入 `z8build.slice` 的本地构建和远程 runner 共享编译集合，子 slice 权重分别为 200 和 100。容器 `cpus: 12` 仍是 12 个 CPU 的时间配额，`mem_limit: 32g` 仍限制其内存。CPU 集合和两路 DDR4 的 `numactl` 分配是两项独立设置。 [Ubuntu 26.04 systemd 资源控制](https://manpages.ubuntu.com/manpages/resolute/man5/systemd.resource-control.5.html) · [Ubuntu 26.04 systemctl set-property](https://manpages.ubuntu.com/manpages/resolute/man1/systemctl.1.html)

## 运行时的 NUMA 内存策略

同一进程能用两路 DDR4，一个连续的虚拟地址范围可以映射到不同节点的物理页。对会在同一份数据上工作的线程，先看 CPU 和数据是否就近。对整台机，比较两路 DDR4 剩余量和 UPI 流量，按工作负载分配。 `AllowedCPUs` 控制线程可运行的位置，内存策略独立配置。 [Linux NUMA 内存策略](https://docs.kernel.org/admin-guide/mm/numa_memory_policy.html)

| 工作负载 | 起步配置 | 怎样看分配结果 |
|---|---|---|
| 系统、SSH、Xfce、普通 harness | 两路都保留普通任务的 CPU，沿用 Linux 本地优先。页初次实际分配时，内核优先使用当时运行线程所在的节点，紧张时可回退 | 用 `numastat -m` 看两路 DDR4 余量，用 `numastat -p PID` 看吃内存最多的服务 |
| Buck2 本地编译、Buildbarn worker | 先保留两路对称 CPU 集合和本地优先，由并行编译进程就近分配。现有 `z8build-local.slice` 和 worker 的 `z8build-remote.slice` 都跨两路 | 看整个构建 cgroup 的 `memory.numa_stat`，分别比较 `anon` 和 `file`，以及真实构建时间。单个 linker 偏一侧可以接受。若持续挤满同一侧，先在多个独立构建间分配 socket，或对大工作集做两 DDR4 节点交错对照 |
| 1Cat、Xolotl 四卡推理 | 推理核每路等量，约 101 GiB 共享 pinned 缓冲以 `Z8_DRAM_INTERLEAVE=0,1` 启动，目标约 50.5 GiB/路。0、1 是示例 DDR4 节点，不含 kmem。独立 staging 后续再试让每个 rank 的线程和缓冲贴近它对应的 V100 | 查实际 CUDA worker/引擎的 `/proc/PID/numa_maps`、`numastat -p PID` 和 pinned 峰值。用 `nvidia-smi topo -m` 对照 GPU 归属，再看 H→D、UPI、TTFT 和 decode |
| llama.cpp 四卡推理 | 首轮同样在两路保留等量 CPU，以 DDR4 交错启动。`mmap` 的 GGUF/Engram 按条带的物理布局读取，进程策略影响可受该策略约束的 DRAM 分配。用 `--load-mode none` 对照时重新核 DDR4 预算 | 分开看文件映射、匿名页和 pinned buffer。按 `/proc/PID/smaps`、`numastat -p PID`、`VmPin` 与引擎日志核对，再比较 PCIe / UPI 和 TTFT |

DDR4 交错是进程启动时的分配策略。具体映射若由引擎、共享内存或 CUDA 驱动另行设置，核实际节点分布。101 GiB 是总预算，还要留出系统和编译的空间。顶层 slice 的 `AllowedMemoryNodes` 维持默认，允许正常回退及冷页下沉。严格只给 DDR4 节点的 cgroup 会失去向 PMem 下沉的目标。 [Linux 7.0 下沉掩码](https://github.com/torvalds/linux/blob/v7.0/mm/vmscan.c#L978) · [cgroup `memory.numa_stat`](https://docs.kernel.org/admin-guide/cgroup-v2.html#memory-interface-files)

**逐卡本地 DDR4 对照。** 先把 CUDA rank／stage 对到 GPU UUID、PCI BDF 和 `/sys/bus/pci/devices/<BDF>/numa_node`。固定模型文件布局和 arena 预算，单独比较 staging 放置。Xolotl 的四个 stage 共用一个引擎进程。外层 `numactl` 只能给出进程默认策略，逐 stage 对照需要在引擎分配时按对应 GPU 给缓冲区设内存策略，在注册 pinned 页之前就近触页。1Cat 可逐 rank 量进程策略，还需确认共享区和 staging 实际由哪个线程分配并首次访问。以每 stage 24 GiB 算，每路两张卡预算各 48 GiB。用 `numastat -p`、`numa_maps`、实际 H→D 带宽和 PCM 的 UPI 数据核分布和收益。卡的 pinned 页确实全在本地时，该缓冲的 H→D payload 可以走本地 PCIe；模型冷读、跨 stage、TP 通信和系统流量仍各走自己的路径。全进程交错也只约束适用的页，单卡实际跨 UPI 的比例从计数器看。 [Xolotl stage 初始化](https://github.com/Indras-Mirror/Xolotl/blob/db25febda3e2869333d72eca6b17296142916a9b/tools/v41/engine/ds41_pipeline.cpp#L382) · [1Cat staging](https://github.com/1CatAI/1Cat-vLLM/blob/main/benchmarks/deepseek_v41/HANDOFF.md#G2-cold-expert-staging-ring)

## 生成并安装

之前已生成 CPU masks 的机器，先停止 `z8-infer.service`，再重新生成。安装步骤会移除本仓库旧的四份 slice `80-z8-cpu.conf`。`10-z8-cpu.conf` 先于 `systemctl set-property --runtime` 生成的 `50-AllowedCPUs.conf` 读取。推理运行时重载 systemd 后，核普通任务的 `EffectiveCPUs` 仍为 80 个。 [systemd drop-in 合并顺序](https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html)

从解压后的 `z8-kit` 目录执行。预览每路核心数、保留的 HT sibling 和 Xolotl worker 列表。T1–T5 验机阶段沿用默认调度。

```bash
kit=$(realpath .)
lscpu -e=CPU,CORE,SOCKET,NODE,ONLINE
numactl -H
grep -w cpuset /sys/fs/cgroup/cgroup.controllers
layout=$(mktemp -d)/cpu-layout
python3 "$kit/host/cpu-layout.py" "$layout" --infer-per-socket 6
cat "$layout"/{z8infer.slice,z8-infer-cpu.env,10-z8-cpu.conf}
```

```bash
(
    set -e
    systemd-analyze verify --man=no "$layout"/*.slice
    sudo install -m 0644 "$layout"/*.slice /etc/systemd/system/
    sudo install -m 0644 "$layout/z8-infer-cpu.env" /etc/z8-infer-cpu.env
    for slice in system user machine z8build; do
        sudo install -Dm0644 "$layout/10-z8-cpu.conf" \
            "/etc/systemd/system/$slice.slice.d/10-z8-cpu.conf"
        sudo rm -f -- "/etc/systemd/system/$slice.slice.d/80-z8-cpu.conf"
    done
    sudo install -Dm0755 "$kit/host/cpu-mode.sh" /usr/local/libexec/z8-cpu-mode
    sudo install -m 0644 "$kit/host/cpu-isolation/z8-infer.service" /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo /usr/local/libexec/z8-cpu-mode restore
    systemctl cat system.slice user.slice machine.slice z8build.slice
    systemctl show system.slice user.slice machine.slice z8build.slice -p Id -p AllowedCPUs
)
```

安装到这一步，四个 slice 的 `AllowedCPUs` 应与 `Z8_IDLE_CPUS` 一致，默认共 92 个。四份 drop-in 让重启后也应用空闲集合；启动推理时再用运行时属性缩到 80 个。若已有其它 CPU 限制，先用 `systemctl cat` 和 `EffectiveCPUs` 核对合并结果。

如 I5 已启用 Buildbarn 远程执行，加下面的 runner 配置。Docker 应报告 `systemd 2`，对应 systemd cgroup 驱动和 cgroup v2。runner 启动真正的编译动作；scheduler、worker 协调进程和 CAS 继续用普通服务 CPU 集合。等当前远程动作结束再重启 worker。

```bash
(
    set -e
    test "$(sudo docker info --format '{{.CgroupDriver}} {{.CgroupVersion}}')" = 'systemd 2'
    cd /opt/z8-kit/buildbarn
    sudo install -m 0644 "$kit/buildbarn/compose.cpu-layout.yaml" .
    sudo docker compose -p z8-tiered -f compose.tiered.yaml -f compose.worker.yaml \
        -f compose.cpu-layout.yaml config --quiet
    sudo install -Dm0644 "$kit/buildbarn/worker-cpu-layout.conf.example" \
        /etc/systemd/system/z8-buildbarn-worker.service.d/80-z8-cpu.conf
    sudo systemctl daemon-reload
    sudo systemctl restart z8-buildbarn-worker.service
)
```

## 启停本地模型

按已通过的 I6 profile 写入 `~/.config/z8-infer/launch.sh`。以 `z8user` 创建目录与脚本，执行 `install -d -m 0700 ~/.config/z8-infer`、`chmod 0700 ~/.config/z8-infer/launch.sh`。`env.sh` 由该用户保存，权限设为 0600，填 GPU UUID、本地密钥以及对应引擎配置需要的变量，使用 `export NAME=值`。按 `numactl -H` 和 T3 报告填两个 **DDR4** 节点号，例如 `export Z8_DRAM_INTERLEAVE=0,1`。服务以 `z8user` 运行，要求 PMem 模型卷已挂载。

**llama.cpp 的 `launch.sh`**

沿用 [实测通过的 llama-server 命令](../inference/README.md#llamacpp-v100-首选多会话服务候选)。文件首部加 `#!/usr/bin/env bash` 和 `set -euo pipefail`，加载 `source "$HOME/.config/z8-infer/env.sh"`。将服务命令的开头改为 `exec /usr/bin/numactl --interleave="$Z8_DRAM_INTERLEAVE" /path/to/llama.cpp/build/bin/llama-server`。在 `env.sh` 填 `CUDA_VISIBLE_DEVICES`、`DS41_GGUF` 及跑通的 `SLOTS`、`SLOT_CTX` 和专家缓存预算。把 `--threads` 和 `--threads-batch` 两处初始值 12 一起改成实际预留 CPU 数。若为 Xolotl 配过服务的 `MemoryMax`，切换前按 llama.cpp 工作集调整同一个 drop-in。

**1Cat 的 `launch.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$HOME/.config/z8-infer/env.sh"
exec /usr/bin/numactl --interleave="$Z8_DRAM_INTERLEAVE" /usr/bin/bash \
    /path/to/z8-kit/inference/serve-1cat.sh /path/to/1Cat-vLLM /path/to/1cat-4x16.yaml
```

**Xolotl 的 `launch.sh`**

Buster 上游启动器会另用 `systemd-run --user` 创建 scope，使实际引擎回到 `user.slice`。在固定 SHA 的 checkout 中先运行 `git apply --check /path/to/z8-kit/inference/buster-inherit-scope.patch`，再执行同路径的 `git apply`。配套补丁保留锁和默认路径，下面的环境变量让引擎继承外层 cgroup。`STRATA_POOL_CORES` 使用生成的 worker 清单，生成的 Xolotl profile 保持 `--threads` 未设，让引擎按列表决定 worker 数。`STRATA_ENGINE_NICE=0` 关闭 launcher 对子进程额外增加 nice 的逻辑，让它继承 service 的 `Nice=-5`。 [Xolotl Buster launcher](https://github.com/Indras-Mirror/Xolotl/blob/main/tools/buster/buster-engine.sh) · [DS4.1 worker 参数](https://github.com/Indras-Mirror/Xolotl/blob/main/tools/v41/engine/ds41_generate.cpp) · [Xolotl 的 engine nice 逻辑](https://github.com/Indras-Mirror/Xolotl/blob/main/serve/server.py#L4053)

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$HOME/.config/z8-infer/env.sh"
source /etc/z8-infer-cpu.env
export Z8_BUSTER_INHERIT_SCOPE=1
export STRATA_POOL_CORES="$Z8_XOLOTL_POOL_CPUS"
export STRATA_ENGINE_NICE=0
cd /path/to/Xolotl
export STRATA_BUILD_DIR="$PWD/build-buster"
exec /usr/bin/numactl --interleave="$Z8_DRAM_INTERLEAVE" .venv-serve/bin/python tools/v41/serve/serve_ds41.py \
    --engine strata --config local-1017.json --port 8150
```

Xolotl 原来给引擎单独设 `MemoryMax=140G`、`MemorySwapMax=0`。在 `sudo systemctl edit z8-infer.service` 中加下面两行资源设置，使外层同时覆盖 API 和引擎，再以峰值复核。切到 1Cat 时按其独立的内存基线调整该 drop-in。

```ini
[Service]
MemoryMax=140G
MemorySwapMax=0
```

```bash
sudo systemctl start z8-infer.service
journalctl -fu z8-infer.service
# 模型不再使用时，在另一个终端执行。
sudo systemctl stop z8-infer.service
```

`Type=exec` 只确认启动器已执行，加载模型与 API 就绪继续从日志和 [I7 请求探针](../inference/README.md) 验证。llama.cpp 和 1Cat 可先看各自的 `/health`，Xolotl 用实际短生成跑过首次加载。需要持久化的 KV／slot 先通过引擎接口保存并确认完成再停服务。服务的停止超时为 300 秒，真实落盘耗时在验收时记录。

先用已验证的启动策略。若需要硬限制推理 cgroup 的分配范围，可以另设 `AllowedMemoryNodes=` 为实际 DDR4 节点，并用 `numastat -p`、pinned 峰值和 PSI 核对。Linux 7.0 的页回收会用 cgroup 的内存节点集合过滤可用的下沉目标，收紧后这个 cgroup 可能更早遇到 DRAM 压力。 [Linux 7.0 vmscan](https://github.com/torvalds/linux/blob/v7.0/mm/vmscan.c#L978)

## 本地构建与验证

普通 SSH、Xfce 和 harness 已随 `user.slice` 切换。希望本地构建和远程 runner 使用前面定义的同级权重时，从项目目录进入专用 scope，并在同一 shell 启动 Buck2 或会编译的 harness。需要持久 tmux 时，在 scope 内首次运行 `tmux -L z8build new-session -s build`，再用相同 socket 名重连。`--isolation-dir z8-build` 让 Buck2 使用在这个 scope 内启动的 daemon。若已在别处使用同一个 isolation dir，先从原进程所在项目目录执行 `buck2 --isolation-dir z8-build kill`。

```bash
sudo systemd-run --scope --slice=z8build-local.slice \
    /usr/bin/setpriv --reuid="$(id -u)" --regid="$(id -g)" --init-groups \
    --reset-env /usr/bin/bash -il
# 以下在新 shell 内运行，目标换成真实项目目标。
buck2 --isolation-dir z8-build build --local-only -j 8 //path:target
```

如果一个大构建持续用尽同一路 DDR4，可在同一 scope 内另起 Buck2 daemon 对照。第一次启动就用 `numactl --interleave=0,1 buck2 --isolation-dir z8-build-interleave build --local-only -j 8 //path:target`，只填实际 DDR4 节点。使用同一目标、同一构建并发，保持两轮的本地物化和缓存状态可比。只给已经连上旧 daemon 的客户端加 `numactl`，旧 daemon 的策略不会随之切换。

### IRQ 与内核线程

推理的 HT 伙伴只对配置过的用户态 slice 留空。IRQ 和内核线程可能仍在其中运行。先在模型与冷 CAS 同时运行时采样，确认是否和 TTFT 毛刺同时间发生。

```bash
mpstat -P ALL 1
ps -eLo pid,tid,psr,comm | grep -E 'z_wr_iss|z_rd_int|kworker'
grep -Ei 'nvme|ahci|nvidia|iwlwifi' /proc/interrupts
# 把 IRQ 换成 /proc/interrupts 中正在增长的向量编号。
IRQ=REPLACE_IRQ_NUMBER
cat "/proc/irq/$IRQ/effective_affinity_list"
```

若确认可迁移 IRQ 造成干扰并且启用了 irqbalance，用 `sudo systemctl edit irqbalance.service` 在 `[Service]` 下加 `Environment="IRQBALANCE_BANNED_CPULIST=实际推理主线程,实际HT伙伴"`。填两路实际 CPU 列表并重启 irqbalance。已在 `/etc/default/irqbalance` 设置同变量的机器可直接修改该处。重跑并查看有效亲和性。具体存储 IRQ 要手动绑时，用对应设备本地的编译核。内核管理的 MSI-X 队列以实际有效掩码为准，逐个验证后再留设置。 [Ubuntu 26.04 irqbalance](https://manpages.ubuntu.com/manpages/resolute/man1/irqbalance.1.html) · [Linux IRQ affinity](https://docs.kernel.org/core-api/irq/irq-affinity.html)

dm-zoned 回收用有序的 unbound workqueue。若它与尾延迟相关，单独试收窄全局 unbound 掩码。ZFS SPL 的 taskq 是独立线程，需通过线程采样和 [冷 CAS 压缩对照](../storage/README.md) 另行判断。首装不自动设置全局掩码。 [Linux workqueue](https://docs.kernel.org/core-api/workqueue.html) · [dm-zoned 回收队列](https://raw.githubusercontent.com/torvalds/linux/v7.0/drivers/md/dm-zoned-reclaim.c)

```bash
source /etc/z8-infer-cpu.env
wq=/sys/devices/virtual/workqueue/cpumask
old_wq=$(cat "$wq")
build_wq=$(python3 - "$Z8_BUILD_CPUS" <<'PY'
import sys
mask = 0
for item in sys.argv[1].split(","):
    start, _, end = item.partition("-")
    for cpu in range(int(start), int(end or start) + 1):
        mask |= 1 << cpu
words = (mask.bit_length() + 31) // 32
print(",".join(f"{(mask >> (word * 32)) & 0xffffffff:08x}" for word in reversed(range(words))))
PY
)
printf '%s\n' "$build_wq" | sudo tee "$wq"
```

跑完同一组推理和冷 CAS，再在原 shell 恢复原值。

```bash
printf '%s\n' "$old_wq" | sudo tee "$wq"
```

### 混合负载的 RDT 对照

保留目前的 CPU 集合与 HT 伙伴隔离。若推理与构建同跑时 p95 明显恶化，先检查 PCIe、UPI、DDR4 带宽和 LLC。`resctrl` 作为后续实验手段，先看两路 8269CY 与实际内核暴露的功能。只在试验机当前没有其他程序管理该挂载时手动挂载。 [Linux 7.0 resctrl](https://www.kernel.org/doc/html/v7.0/filesystems/resctrl.html)

```bash
awk '/^flags[[:space:]]*:/ { for (i=1; i<=NF; i++) if ($i ~ /^(cat_l3|mba|cqm_mbm_total|cqm_mbm_local)$/) print $i; exit }' /proc/cpuinfo
findmnt -M /sys/fs/resctrl || sudo mount -t resctrl resctrl /sys/fs/resctrl
cat /sys/fs/resctrl/schemata
ls /sys/fs/resctrl/info
```

有 MBM 时先观察实际编译任务的带宽。对远程执行，检查 runner 与实际编译器的宿主 PID/TID。`resctrl` 按 task 或 CPU 归组，写 `tasks` 时核实际执行者和后续子任务的归属，Buildbarn 的 cgroup 路径本身不能当成 `tasks` 的成员。若证实是内存带宽竞争，再手动试一个 MBA 档，按 `info/MB/min_bandwidth`、`bandwidth_gran`、`thread_throttle_mode` 和 `schemata` 的实际缓存域选值。看 MBM 实际读数、推理 p95 及构建时间。默认百分比表示节流档位，整组实际带宽还受线程数和硬件影响。LLC 争用则单独测 CAT。GPU DMA 和跨 UPI 瓶颈仍用各自计数器判定。 [Linux 7.0 资源归组规则](https://www.kernel.org/doc/html/v7.0/filesystems/resctrl.html#resource-allocation-rules) · [MBA 与 MBM](https://www.kernel.org/doc/html/v7.0/filesystems/resctrl.html#memory-bandwidth-allocation-and-monitoring)

启动前、运行中、停止后分别检查。对实际 1Cat CUDA worker 或 Xolotl `ds41_generate`，以及同一个 Buck2 daemon，分别查以下 PID。停止模型后，继续跑的 Buck2 或 runner 应恢复到空闲 CPU 集合，其中仍排除推理核的 HT 伙伴。`-j` 与容器的 CPU 时间配额仍分别限制构建并发和 CPU 时间。

```bash
systemctl show z8infer.slice z8build.slice z8build-local.slice user.slice \
    -p Id -p AllowedCPUs -p EffectiveCPUs -p CPUWeight
# 分别用实际推理、编译 PID 替换 12345。
pid=12345
cat "/proc/$pid/cgroup"
grep -E '^(Cpus_allowed_list|Mems_allowed_list|VmLck|VmPin):' "/proc/$pid/status"
numastat -p "$pid"
cg=$(awk -F: '$1 == "0" {print $3}' "/proc/$pid/cgroup")
sudo grep -E '^(anon|file|pgdemote_.*) ' "/sys/fs/cgroup$cg/memory.numa_stat"
```

```bash
# 已启用 Buildbarn worker 时。
cd /opt/z8-kit/buildbarn
runner=$(sudo docker compose -p z8-tiered -f compose.tiered.yaml -f compose.worker.yaml \
    -f compose.cpu-layout.yaml ps -q runner)
sudo docker inspect --format '{{.HostConfig.CgroupParent}} {{.HostConfig.NanoCpus}}' "$runner"
pid=$(sudo docker inspect --format '{{.State.Pid}}' "$runner")
sudo cat "/proc/$pid/cgroup"
sudo grep '^Cpus_allowed_list:' "/proc/$pid/status"
```

用同一模型、请求回放和 Buck2 目标对照推理单跑、编译单跑、默认调度并跑和分核并跑。每轮保持相同的构建并行度和缓存状态。记录 decode tok/s、TTFT p95、构建墙钟时间，用 `pidstat -t -p <推理 PID> 2` 看忙线程数，再用 `sudo turbostat --quiet --interval 2` 看每核的 `Bzy_MHz` 以及每路的 `PkgWatt` 与温度。选择性能已接近本轮最好值、用核最少的配置。更改 K 时先停 `z8-infer.service`，重新生成并安装 slice 和 env，再 `sudo systemctl daemon-reload` 后启动。 [Linux 7.0 turbostat](https://github.com/torvalds/linux/blob/v7.0/tools/power/x86/turbostat/turbostat.8)

平时停 `z8-infer.service` 即归还推理主线程。若日志报告恢复失败，停服务后手动执行 `sudo /usr/local/libexec/z8-cpu-mode restore` 再核 CPU mask。完全撤销时，先停推理以及已启用的 worker，删除本节安装的 slice、服务与专用 drop-in，执行 `sudo systemctl daemon-reload` 后重启主机。普通任务恢复使用 104 个逻辑 CPU，已启用的 Buildbarn worker 按原 I5 配置启动。
