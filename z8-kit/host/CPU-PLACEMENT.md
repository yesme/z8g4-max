# 保留 HT，DeepSeek 启停时交还整颗物理核

F10 → Advanced → Performance Options 固定 NUMA 开、SNC 关，保持 HT、所有核心和 Turbo 开启。I5 启用 Buildbarn worker 前先[生成并安装分核配置](#生成并安装)。I6 通过手动推理验收后再[配置并启动推理服务](#启停本地模型)，I7 验证启停和混合负载。生成器从 Linux sysfs 读取每个逻辑 CPU 所属的 socket 和同核 HT 线程，按每路独立分配。DDR4 节点号用 [T3 拓扑报告](PMEM.md#核对双路-numa-拓扑) 确认。

| 每路推理预留 | 双路可运行的推理线程 | 双路系统与编译可用线程 | Xolotl CPU expert worker 起点 |
|---|---:|---:|---:|
| **6 颗物理核（首装）** | **12** | **80** | **10** |
| **推理服务已停止（仍预留 6 核/路的 HT 伙伴）** | — | **92** | — |

按双路各 26 核、每核两个 HT 线程计算。每路固定留 6 颗物理核给推理。 [8269CY 实机实验平台](https://www.vldb.org/pvldb/vol17/p4827-li.pdf)

用每路内部的示意编号 `0↔26、1↔27、…、25↔51`，每路取最后六颗物理核时，推理用 20–25，对应 HT 伙伴 46–51 始终保留。普通任务在推理停机时用 0–45，推理启动后用 0–19 与 26–45。每路推理核中的第一颗留给主控，其余五颗进入 Xolotl 的 worker 列表。

Linux 的 CPU 号全机唯一。脚本按 `thread_siblings_list` 配对，每对取编号较小的 CPU 作“主线程”，每路按这个编号排序取最后 K 对。这样 CPU0 所在物理核留给普通任务和系统。cgroup 的 CPU 集合约束其中的进程。硬件 IRQ 与内核线程有自己的亲和性，用 `/proc/interrupts` 和 `ps -eLo pid,tid,psr,comm` 核正在跑的网卡、存储和推理负载。CPU 核的执行资源分开，socket 的 Turbo、功耗、末级缓存、DDR4、PMem 和 UPI 仍然共享。 [Linux CPU 拓扑](https://docs.kernel.org/admin-guide/cputopology.html) · [Linux cgroup v2 cpuset](https://docs.kernel.org/admin-guide/cgroup-v2.html#cpuset) · [Linux IRQ 亲和性](https://docs.kernel.org/core-api/irq/irq-affinity.html)

**固定每路 6 核。** llama.cpp 的工作线程设 12。Xolotl 回退时每路 5 个 CPU expert worker，另各留 1 核给引擎控制和 helper。只有真实工单出现 CPU 连续饱和且推理未达要求时，再增加用核。

`z8-infer.service` 先把 `system.slice`、`user.slice`、`machine.slice` 和 `z8build.slice` 缩到编译集合，再启动模型。停止或启动失败时恢复普通任务的空闲集合，只交还推理的 12 个主线程；同核的 12 个 HT 伙伴一直排除。cgroup 更新会作用到正在运行的 Buck2 与 runner，已有进程主动设过的 affinity 也要一并核对。服务常驻时即使暂时没有 API 请求也保留核心。OMP/Pi/DSH 直连云端 API 不启动该服务。

`AllowedCPUs` 定运行位置。`CPUWeight` 决定同级 cgroup 争抢共同 CPU 时的相对份额。推理 slice 权重 200，构建 slice 权重 100，推理服务设普通调度的 `Nice=-5`。已显式放入 `z8build.slice` 的本地构建和远程 runner 共享编译集合，子 slice 权重分别为 200 和 100。推理运行时普通任务共享 80 个逻辑 CPU。runner 配 72 个活动 action 和 72 CPU 时间配额，给系统和协调进程留 8 个逻辑 CPU 的时间预算。并发数包括等待 I/O 和排队取输入的动作。runner 的 `mem_limit: 512g` 跨 DDR4 和 PMem kmem 计费。 [Ubuntu 26.04 systemd 资源控制](https://manpages.ubuntu.com/manpages/resolute/man5/systemd.resource-control.5.html)

推理 slice 与 service 都设 `MemoryLow=160G`。两条是父子层级的同一尽力保护，按实际用量生效，降低它会改变回收次序。CUDA 长期 pin 的页本身不可回收。两路 kmem 以 `ZONE_MOVABLE` 上线，承接可移动的匿名页和文件页。页表、其他不可移动内核内存、ARC 预算及长期锁页仍需给 DDR4 留空间。启动值沿用内核的 `vm.watermark_scale_factor=10`，I7 记录两路 `Normal` 水位、内存 PSI、`allocstall_normal` 和 `kswapd_low_wmark_hit_quickly`，用于定位直接回收和慢层下沉。可迁移页的下沉还取决于慢层是否可用和迁移是否成功。

如果 I7 的多个采样窗口里 `allocstall_normal` 持续增长，同时可见 `Normal` 水位紧张、PSI 或推理尾延迟抬升，在 `/etc/sysctl.d/90-z8-tiering.conf` 加入 `vm.watermark_scale_factor = 100`，执行 `sudo sysctl -p /etc/sysctl.d/90-z8-tiering.conf` 后重复同一负载。只有直接回收或尾延迟改善且构建吞吐可接受时保留该值。无改善时从配置移除该项并执行 `sudo sysctl -w vm.watermark_scale_factor=10` 恢复运行值。服务的 `OOMScoreAdjust=-900` 降低被选作 OOM victim 的优先级。 [Linux cgroup v2 memory.low](https://docs.kernel.org/admin-guide/cgroup-v2.html#memory-interface-files) · [Linux ZONE_MOVABLE](https://docs.kernel.org/admin-guide/mm/memory-hotplug.html#zone-movable) · [Linux 7.0 水位与直接回收计数](https://github.com/torvalds/linux/blob/v7.0/Documentation/admin-guide/sysctl/vm.rst#L1096-L1111)

## 运行时的 NUMA 内存策略

同一进程能用两路 DDR4，一个连续的虚拟地址范围可以映射到不同节点的物理页。对会在同一份数据上工作的线程，先看 CPU 和数据是否就近。对整台机，比较两路 DDR4 剩余量和 UPI 流量，按工作负载分配。 `AllowedCPUs` 控制线程可运行的位置，内存策略独立配置。 [Linux NUMA 内存策略](https://docs.kernel.org/admin-guide/mm/numa_memory_policy.html)

| 工作负载 | 起步配置 | 怎样看分配结果 |
|---|---|---|
| 系统、SSH、Xfce、harness 与 Buck2 | 使用两路对称 CPU 集合，Linux 默认本地优先。冷页可下沉到对应 PMem 慢节点 | 查实际构建或服务 cgroup 的 `memory.numa_stat` |
| llama.cpp 或 Xolotl 四卡 | 固定在两个 DDR4 节点之间交错，按 T3 填 `Z8_DRAM_INTERLEAVE`。模型文件统一在 PMem 条带 | 查实际进程的 `numastat -p PID`、`numa_maps` 和 `VmPin/VmLck`，与节点预算核对 |

顶层 slice 的 `AllowedMemoryNodes` 维持默认，构建页可正常回退和下沉。进程级交错申请的页按照应用和驱动实际分配行为核对。只有看到持续的单节点 DRAM 压力或 UPI 饱和时，才检查该 worker 的 first-touch 或 staging。 [Linux 7.0 下沉掩码](https://github.com/torvalds/linux/blob/v7.0/mm/vmscan.c#L978)

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

I5 先完成 [Buildbarn 的软件、目录与单元准备](../storage/README.md#i51-软件目录与单元准备)，再完成上面的 CPU slice 安装。使用 tiered Buildbarn 时，启用 worker 前继续给 runner 加下面的分核配置。走全 XFS 回退时，这里只安装 CPU slice，按回退 Compose 命令应用 runner 分核。Docker 应报告 `systemd 2`，对应 systemd cgroup 驱动和 cgroup v2。runner 启动真正的编译动作。scheduler、worker 协调进程和 CAS 继续由普通服务 CPU 集合管理。

```bash
(
    set -e
    test "$(sudo docker info --format '{{.CgroupDriver}} {{.CgroupVersion}}')" = 'systemd 2'
    cd /opt/z8-kit/buildbarn
    sudo docker compose -p z8-tiered -f compose.tiered.yaml -f compose.worker.yaml \
        -f compose.cpu-layout.yaml config --quiet
    sudo install -Dm0644 "$kit/buildbarn/worker-cpu-layout.conf.example" \
        /etc/systemd/system/z8-buildbarn-worker.service.d/80-z8-cpu.conf
    sudo systemctl daemon-reload
    sudo systemctl try-restart z8-buildbarn-worker.service
)
```

## 启停本地模型

以 `jackywang` 建 `~/.config/z8-infer`（0700）。将 I6 已确认的 `LLAMA_BUILD`、`DS41_GGUF`、`CUDA_VISIBLE_DEVICES`、`Z8_DRAM_INTERLEAVE` 写成 `env.sh` 中的 `export NAME=值`，文件设 0600。CUDA 库没有放在默认的 `/srv/work/jackywang/cuda-12.9-runtime` 时，也导出 `Z8_CUDA_RUNTIME`。只有六对 NVLink 与 NCCL 已在正式默认内核参数下验过才保存 `export Z8_NVLINK_P2P=1`。保存 I6 实际使用的 `SLOTS`、`SLOT_CTX`、`MOE_CACHE_MIB` 或 `CACHE_PROMPT` 覆盖项。systemd 从 `/etc/z8-infer-cpu.env` 自动传入 `Z8_INFER_THREADS`。以下 `launch.sh` 设 0700。

**llama.cpp 的 `launch.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$HOME/.config/z8-infer/env.sh"
exec /usr/bin/bash /path/to/z8-kit/inference/serve-llama.sh
```

**I6 触发 Xolotl 回退时的 `launch.sh`**

Buster 上游启动器会另用 `systemd-run --user` 创建 scope，使实际引擎回到 `user.slice`。在固定 SHA 的 checkout 中先运行 `git apply --check /path/to/z8-kit/inference/buster-inherit-scope.patch`，再执行同路径的 `git apply`。配套补丁保留锁和默认路径，下面的环境变量让引擎继承外层 cgroup。`STRATA_POOL_CORES` 使用生成的 worker 清单，生成的 Xolotl profile 保持 `--threads` 未设，让引擎按列表决定 worker 数。`STRATA_ENGINE_NICE=0` 关闭 launcher 对子进程额外增加 nice 的逻辑，让它继承 service 的 `Nice=-5`。 [Xolotl Buster launcher](https://github.com/Indras-Mirror/Xolotl/blob/main/tools/buster/buster-engine.sh) · [DS4.1 worker 参数](https://github.com/Indras-Mirror/Xolotl/blob/main/tools/v41/engine/ds41_generate.cpp) · [Xolotl 的 engine nice 逻辑](https://github.com/Indras-Mirror/Xolotl/blob/main/serve/server.py#L4053)

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$HOME/.config/z8-infer/env.sh"
source /etc/z8-infer-cpu.env
export Z8_BUSTER_INHERIT_SCOPE=1
export STRATA_POOL_CORES="$Z8_XOLOTL_POOL_CPUS"
export STRATA_ENGINE_NICE=0
cd /srv/work/jackywang/Xolotl
export LD_LIBRARY_PATH="/srv/work/jackywang/cuda-12.9-runtime${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export STRATA_BUILD_DIR="$PWD/build-buster"
exec /usr/bin/numactl --interleave="$Z8_DRAM_INTERLEAVE" .venv-serve/bin/python tools/v41/serve/serve_ds41.py \
    --engine strata --config local-1017.json --port 8150
```

Xolotl 原来给引擎单独设 `MemoryMax=140G`、`MemorySwapMax=0`。在 `sudo systemctl edit z8-infer.service` 中加下面两行资源设置，使外层同时覆盖 API 和引擎，再以峰值复核。

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

`Type=exec` 只确认启动器已执行，加载模型与 API 就绪继续从日志和 [I6 请求探针](../inference/README.md#i6-推理放行) 验证。llama.cpp 看 `/health`，Xolotl 用实际短生成跑过首次加载。服务的停止超时为 300 秒。

## 本地构建与验证

普通 SSH、Xfce 和 harness 已随 `user.slice` 切换。希望本地构建和远程 runner 使用前面定义的同级权重时，从项目目录进入专用 scope，并在同一 shell 启动 Buck2 或会编译的 harness。需要持久 tmux 时，在 scope 内首次运行 `tmux -L z8build new-session -s build`，再用相同 socket 名重连。`--isolation-dir z8-build` 让 Buck2 使用在这个 scope 内启动的 daemon。若已在别处使用同一个 isolation dir，先从原进程所在项目目录执行 `buck2 --isolation-dir z8-build kill`。

```bash
sudo systemd-run --scope --slice=z8build-local.slice \
    /usr/bin/setpriv --reuid="$(id -u)" --regid="$(id -g)" --init-groups \
    --reset-env /usr/bin/bash -il
# 以下在新 shell 内运行，目标换成真实项目目标。
buck2 --isolation-dir z8-build build --local-only -j 8 //path:target
```

### IRQ 与内核线程

用户态 slice 的 CPU 集合与 IRQ／内核线程亲和性独立。只有推理尾延迟异常且 `mpstat -P ALL 1` 或 `/proc/interrupts` 显示存储／网卡 IRQ 持续落在推理核时，才按实际向量检查 `/proc/irq/<IRQ>/effective_affinity_list`。需迁移时用 irqbalance 的 `IRQBALANCE_BANNED_CPULIST` 排开推理 CPU 和 HT 伙伴，屏蔽值取生成的 `/etc/z8-infer-cpu.env` 中 `Z8_IRQ_BANNED_CPUS`。全局 workqueue、CAT/MBA 保持默认。 [Ubuntu irqbalance](https://manpages.ubuntu.com/manpages/resolute/man1/irqbalance.1.html) · [Linux IRQ affinity](https://docs.kernel.org/core-api/irq/irq-affinity.html)

启动前、运行中、停止后分别检查。对实际 `llama-server` 或 Xolotl `ds41_generate`，以及同一个 Buck2 daemon，分别查以下 PID。停止模型后，继续跑的 Buck2 或 runner 应恢复到空闲 CPU 集合，其中仍排除推理核的 HT 伙伴。`-j` 与容器的 CPU 时间配额仍分别限制构建并发和 CPU 时间。

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
awk '/^Node / {zone=$0} zone ~ /zone[[:space:]]+Normal$/ && /pages free|^[[:space:]]+(min|low|high)[[:space:]]/ {print zone, $0}' /proc/zoneinfo
grep -E '^(allocstall_normal|kswapd_low_wmark_hit_quickly|pgdemote_\S+) ' /proc/vmstat
cat /proc/pressure/memory
```

从 `z8-kit` 根运行下面的命令检查 runner 的容器、cgroup 及实际 CPU 集合。全 XFS 回退把最后的参数换成 `xfs`。

```bash
bash host/run-step.sh i5-worker tiered
```

I7 跑固定的正式配置，记录 decode tok/s、TTFT p95 和构建墙钟时间。运行中执行一次 `sudo systemctl daemon-reload`，核普通任务仍为 80 个逻辑 CPU。停止推理后应还到 92 个。

平时停 `z8-infer.service` 即归还推理主线程。若日志报告恢复失败，停服务后手动执行 `sudo /usr/local/libexec/z8-cpu-mode restore` 再核 CPU mask。完全撤销时，先停推理以及已启用的 worker，删除本节安装的 slice、服务与专用 drop-in，执行 `sudo systemctl daemon-reload` 后重启主机。普通任务恢复使用 104 个逻辑 CPU，已启用的 Buildbarn worker 按原 I5 配置启动。
