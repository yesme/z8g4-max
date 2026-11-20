# 保留 HT，DeepSeek 启停时交还整颗物理核

F10 → Advanced → Performance Options 固定 NUMA 开、SNC 关，保持 HT、所有核心和 Turbo 开启。I5 启用 Buildbarn worker 前先[生成并安装分核配置](#生成并安装)。I6 通过手动推理验收后再[配置并启动推理服务](#启停本地模型)，I7 验证启停和混合负载。生成器从 Linux sysfs 读取每个逻辑 CPU 所属的 socket 和同核 HT 线程，按每路独立分配。DDR4 节点号用 [T3 拓扑报告](PMEM.md#核对双路-numa-拓扑) 确认。

| 每路推理预留 | 双路可运行的推理线程 | 双路系统与编译可用线程 | 编译另可借用的推理主线程 | Xolotl CPU expert worker 起点 |
|---|---:|---:|---:|---:|
| 每路 2 核 | 4 | 96 | 4 | — |
| 每路 4 核 | 8 | 88 | 8 | 6 |
| **每路 6 核（llama.cpp 首装，Xolotl 回退相同）** | **12** | **80** | **12** | 10 |
| **推理服务已停止** | — | **104** | — | — |

按双路各 26 核、每核两个 HT 线程计算。每路默认预留最后 6 颗物理核，运行时连同它们的 HT 伙伴共 24 个逻辑 CPU 不给普通任务。其中 12 个主线程在推理线程睡着时借给 `z8build.slice` 里的编译，12 个 HT 伙伴对所有任务留空。 [8269CY 实机实验平台](https://www.vldb.org/pvldb/vol17/p4827-li.pdf)

用每路内部的示意编号 `0↔26、1↔27、…、25↔51`，默认推理占 20–25 的主线程。运行时其 HT 伙伴 46–51 留空，普通任务用 0–19 和 26–45，编译另可在 20–25 上插空。停止后普通任务用 0–51。

Linux 的 CPU 号全机唯一。脚本按 `thread_siblings_list` 配对，每对取编号较小的 CPU 作“主线程”，每路按这个编号排序取最后 K 对。这样 CPU0 所在物理核留给普通任务和系统。cgroup 的 CPU 集合约束其中的进程。硬件 IRQ 与内核线程有自己的亲和性，用 `/proc/interrupts` 和 `ps -eLo pid,tid,psr,comm` 核正在跑的网卡、存储和推理负载。CPU 核的执行资源分开，socket 的 Turbo、功耗、末级缓存、DDR4、PMem 和 UPI 仍然共享。 [Linux CPU 拓扑](https://docs.kernel.org/admin-guide/cputopology.html) · [Linux cgroup v2 cpuset](https://docs.kernel.org/admin-guide/cgroup-v2.html#cpuset) · [Linux IRQ 亲和性](https://docs.kernel.org/core-api/irq/irq-affinity.html)

**llama.cpp 首装每路 6 核，共 12 个工作线程，CPU 份额 0.9。** 专家默认不锁页，上传慢；显卡缓存未命中的专家有九成由 CPU 直接从主机内存算。这条路的速度随线程数涨，直到内存带宽用满。上游合并这项功能时的实测里，8–22 线程的 CPU 路径是 30–85 GiB/s，上传只有 6.5–11.6 GiB/s；内存带宽不够的机器上它帮不上忙。本机是 12 通道 DDR4，上传却只有 Gen3 x8，所以限制它的是线程数。缓存够大、上传够快时开份额反而变慢，上游也有这样的结果，所以 I6 用[上游调参脚本](../inference/README.md#i6-推理放行)按 12 线程定份额，再用 4 线程测一次：4 线程的推荐速度不低于 12 线程的 95% 就退回每路 2 核，把核还给编译。 [上游的 CPU 份额实测](https://github.com/ggml-org/llama.cpp/pull/30966) 改核数前停服务，按本页重生成，保持同一推理档再验证。

`z8-infer.service` 先把 `system.slice`、`user.slice` 和 `machine.slice` 缩到编译集合，把 `z8build.slice` 缩到编译集合加推理主线程，再启动模型。停止或启动失败时恢复普通任务的空闲集合，推理主线程和同核 HT 伙伴全部归还。cgroup 更新会作用到正在运行的 Buck2 与 runner，已有进程主动设过的 affinity 也要一并核对。CPU 集合只跟服务的启停走，中间不再变动：服务运行期间，推理的 12 个 HT 伙伴一直留空，12 个主线程在推理线程睡着时由编译使用。不用本地模型时停掉服务，HT 伙伴才归还。OMP/Pi/DSH 直连云端 API 不启动该服务。

`AllowedCPUs` 定运行位置。`CPUWeight` 决定同级 cgroup 争抢共同 CPU 时的相对份额。推理 slice 权重 200，推理服务设普通调度的 `Nice=-5`。构建 slice 设 `CPUWeight=idle`，不参与按权重分配：同一个 CPU 上有别的 slice 的任务要跑时它几乎不拿时间，对方一醒就被抢占，对方睡着时才运行。已显式放入 `z8build.slice` 的本地构建和远程 runner 共享同一个集合，两个子 slice 之间的权重是 200 和 100。默认推理运行时普通任务共享 80 个逻辑 CPU，编译是 92 个。runner 配 72 个活动 action，不设 CPU 时间配额：配额用尽时整个 runner cgroup 在该周期剩余时间停转，多线程的链接和编译最先受影响。系统、存储和协调进程靠同级 slice 的权重取得份额。并发数包括等待 I/O 和排队取输入的动作。runner 的 `mem_limit: 512g` 跨 DDR4 和 PMem kmem 计费。 [Ubuntu 26.04 systemd 资源控制](https://manpages.ubuntu.com/manpages/resolute/man5/systemd.resource-control.5.html)

推理 slice 与 service 都设 `MemoryLow=90G`，等于不在显存里的专家加引擎自己的工作内存。专家共 123 GiB，默认 36 GiB 的显存缓存里那部分在主机上的副本不会被读，剩下约 87 GiB 才需要留在 DDR4，另留约 3 GiB 给引擎。这是给常驻服务挑的起点，之后调显存缓存时不跟着逐 GiB 重算；要改时对 `z8infer.slice` 和 `z8-infer.service` 各执行一次 `sudo systemctl set-property 单元名 MemoryLow=…`。`MemoryLow` 按服务的内存总量计，不分 DDR4 和 PMem，也不是下限：占用约 126 GiB、保护 90G 时，内核对这个服务的回收力度降到约 29%，被挪走的先是最久没读的页，也就是显存里已有的那些专家的副本。llama.cpp 的专家默认是普通内存，绑定在两路 DDR4 上分配，之后可以下沉，也可以被提升回来。 [按比例减轻回收](https://github.com/torvalds/linux/blob/v7.0/mm/vmscan.c#L2458-L2520)`EXPERT_MEMORY=pinned` 时这 123 GiB 是 CUDA 锁页内存，不回收也不下沉，其余任务每路能用的 DDR4 约 30 GiB。 [三种放法](../inference/README.md#llamacpp-v100-主服务) 两路 kmem 以 `ZONE_MOVABLE` 上线，承接可移动的匿名页和文件页。页表、其他不可移动内核内存、ARC 预算及长期锁页仍需给 DDR4 留空间。启动值沿用内核的 `vm.watermark_scale_factor=10`，I7 记录两路 `Normal` 水位、内存 PSI、`allocstall_normal` 和 `kswapd_low_wmark_hit_quickly`，用于定位直接回收和慢层下沉。可迁移页的下沉还取决于慢层是否可用和迁移是否成功。

如果 I7 的多个采样窗口里 `allocstall_normal` 持续增长，同时可见 `Normal` 水位紧张、PSI 或推理尾延迟抬升，在 `/etc/sysctl.d/90-z8-tiering.conf` 加入 `vm.watermark_scale_factor = 100`，执行 `sudo sysctl -p /etc/sysctl.d/90-z8-tiering.conf` 后重复同一负载。只有直接回收或尾延迟改善且构建吞吐可接受时保留该值。无改善时从配置移除该项并执行 `sudo sysctl -w vm.watermark_scale_factor=10` 恢复运行值。服务的 `OOMScoreAdjust=-900` 降低被选作 OOM victim 的优先级。 [Linux cgroup v2 memory.low](https://docs.kernel.org/admin-guide/cgroup-v2.html#memory-interface-files) · [Linux ZONE_MOVABLE](https://docs.kernel.org/admin-guide/mm/memory-hotplug.html#zone-movable) · [Linux 7.0 水位与直接回收计数](https://github.com/torvalds/linux/blob/v7.0/Documentation/admin-guide/sysctl/vm.rst#L1096-L1111)

### 编译共用推理核

推理线程不是一直在算：没有请求时全部睡着，一次请求里显卡在算时也会短暂睡着。这些空档里编译可以用推理的 12 个物理核。按一对 HT 线程约合 1.25 个核、72 个并发动作估算，模型空闲时编译能力多约两成。

让路用 idle 调度，不用权重。按 200 对 100 分时，推理线程持续计算的核上只能拿到三分之二。开发环境的 Linux 6.18 上，一个 CPU 放两个忙循环，对手是权重 100 的组时推理拿到约 66%，是 idle 组时拿到约 99%。Z8 上的实际影响由 I7 对照。 [非 idle 任务唤醒时抢占 idle 任务](https://github.com/torvalds/linux/blob/v7.0/kernel/sched/fair.c#L8856-L8866) · [只跑 idle 任务的 CPU 按空闲选核](https://github.com/torvalds/linux/blob/v7.0/kernel/sched/fair.c#L6893-L6902) · [决定与实测](../../discussion/build-idle-priority.md)

- **代价一**：一次请求中间，推理线程短暂睡眠时编译会插进来，推理线程醒来要先把它换下去。
- **代价二**：编译相对全机其他任务都是最低优先级。被别的任务占满的核上如果滞留一个持锁的编译进程，等这把锁的进程会被拖住，直到负载均衡把它挪到空闲的核。
- **长期关掉**：把 `/etc/z8-infer-cpu.env` 里的 `Z8_BUILD_SHARED_CPUS` 改成和 `Z8_BUILD_CPUS` 相同，重启推理服务。
- **临时关掉**：执行下面的命令，到下次启动推理服务为止。

```bash
source /etc/z8-infer-cpu.env
sudo systemctl set-property --runtime z8build.slice "AllowedCPUs=$Z8_BUILD_CPUS"
```

## 运行时的 NUMA 内存策略

同一进程能用两路 DDR4，一个连续的虚拟地址范围可以映射到不同节点的物理页。对会在同一份数据上工作的线程，先看 CPU 和数据是否就近。对整台机，比较两路 DDR4 剩余量和 UPI 流量，按工作负载分配。 `AllowedCPUs` 控制线程可运行的位置，内存策略独立配置。 [Linux NUMA 内存策略](https://docs.kernel.org/admin-guide/mm/numa_memory_policy.html)

| 工作负载 | 起步配置 | 怎样看分配结果 |
|---|---|---|
| 系统、SSH、Xfce、harness 与 Buck2 | 使用两路对称 CPU 集合，Linux 默认本地优先。冷页可下沉到对应 PMem 慢节点 | 查实际构建或服务 cgroup 的 `memory.numa_stat` |
| llama.cpp 或 Xolotl 四卡 | 按 T3 填 `Z8_DRAM_INTERLEAVE`。llama.cpp 默认的 `tiered` 用 `--balancing --membind` 绑定这两个 DDR4 节点，被挤到 PMem 的页才能提升回来；读入路由专家张量时，专用读线程在这两个节点交错分配新页，计算线程继续使用原有亲和性；锁页的 `pinned`、`pmem` 和 Xolotl 在两个节点之间交错。模型文件统一在 PMem 条带 | 查实际进程的 `numastat -p PID`、`numa_maps` 和 `VmPin/VmLck`，与节点预算核对 |

顶层 slice 的 `AllowedMemoryNodes` 维持默认，构建页可正常回退和下沉。进程级交错申请的页按照应用和驱动实际分配行为核对。只有看到持续的单节点 DRAM 压力或 UPI 饱和时，才检查该 worker 的 first-touch 或 staging。 [Linux 7.0 下沉掩码](https://github.com/torvalds/linux/blob/v7.0/mm/vmscan.c#L978)

## 生成并安装

之前已生成 CPU masks 的机器，先停止 `z8-infer.service`，再重新生成。安装步骤会移除本仓库旧的四份 slice `80-z8-cpu.conf`。`10-z8-cpu.conf` 先于 `systemctl set-property --runtime` 生成的 `50-AllowedCPUs.conf` 读取。默认推理运行时重载 systemd 后，核普通任务的 `EffectiveCPUs` 仍为 80 个。 [systemd drop-in 合并顺序](https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html)

从解压后的 `z8-kit` 目录执行。预览每路核心数、保留的 HT sibling 和 Xolotl worker 列表。T1–T5 验机阶段沿用默认调度。

```bash
kit=$(realpath .)
lscpu -e=CPU,CORE,SOCKET,NODE,ONLINE
numactl -H
grep -w cpuset /sys/fs/cgroup/cgroup.controllers
layout=$(mktemp -d)/cpu-layout
python3 "$kit/host/cpu-layout.py" "$layout"
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

安装到这一步，四个 slice 的 `AllowedCPUs` 应与 `Z8_IDLE_CPUS` 一致，共 104 个。四份 drop-in 让重启后也应用空闲集合；启动默认推理时再用运行时属性把普通任务缩到 80 个、`z8build.slice` 缩到 92 个。若已有其它 CPU 限制，先用 `systemctl cat` 和 `EffectiveCPUs` 核对合并结果。

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

以 `jackywang` 建 `~/.config/z8-infer`（0700）。将 I6 已确认的 `LLAMA_BUILD`、`DS41_GGUF`、`CUDA_VISIBLE_DEVICES`、`Z8_DRAM_INTERLEAVE` 写成 `env.sh` 中的 `export NAME=值`，文件设 0600。CUDA 库没有放在默认的 `/srv/work/jackywang/cuda-12.9-runtime` 时，也导出 `Z8_CUDA_RUNTIME`。只有六对 NVLink 与 NCCL 已在正式默认内核参数下验过才保存 `export Z8_NVLINK_P2P=1`。保存 I6 实际使用的 `SLOTS`、`SLOT_CTX`、`KV_TYPE`、`KV_OFFLOAD`、`MOE_CACHE_MIB`、`MOE_CACHE_CPU_SHARE`、`EXPERT_MEMORY`、`INTERLEAVE_EXPERT_READS` 或 `CACHE_PROMPT` 覆盖项。已有 `env.sh` 中的 `LOAD_ROTATE` 继续生效；两者都设置时优先使用 `INTERLEAVE_EXPERT_READS`。systemd 从 `/etc/z8-infer-cpu.env` 自动传入 `Z8_INFER_THREADS`。以下 `launch.sh` 设 0700。

**llama.cpp 的 `launch.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$HOME/.config/z8-infer/env.sh"
exec /usr/bin/bash /path/to/z8-kit/inference/serve-llama.sh
```

**I6 触发 Xolotl 回退时的 `launch.sh`**

Xolotl 沿用默认的每路 6 核。先给每路 5 个 CPU expert worker，另留 1 核给控制线程。[worker 并发](../buildbarn/shared-worker.jsonnet)默认 72，对应每路 6 核；把推理调到每路 4 核时改成 80，每路 2 核时改成 88，改后重启 worker 服务。

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

启动前、运行中、停止后分别检查。对实际 `llama-server` 或 Xolotl `ds41_generate`，以及同一个 Buck2 daemon，分别查以下 PID。模型运行中，`z8build.slice` 里的 Buck2 或 runner 应是 92 个逻辑 CPU：编译集合加推理主线程，不含推理的 HT 伙伴。停止模型后，继续跑的 Buck2 或 runner 应恢复到包含推理核及其 HT 伙伴的 104 个逻辑 CPU。构建并发仍由 Buck2 的 `-j` 和 runner 的活动 action 数限制，runner 没有 CPU 时间配额。

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

I7 跑固定的正式配置，记录 decode tok/s、TTFT p95 和构建墙钟时间。另跑一轮“模型预热、并行编译、回到同一段工具对话”，在三个时点各执行一次 `sudo bash host/pmem-numa-report.sh "$(systemctl show -p MainPID --value z8-infer.service)"`，按推理 cgroup 的 `memory.numa_stat` 里 `anon` 一项记两路 DDR4 和两个 kmem 节点的字节数：编译期间 DDR4 上的专家页应让出，回到对话后应回升，同时记同一工具前缀的首字延迟。I6 首次装载就绪时也运行同一条命令，以 `anon` 近似观察专家页的初始分布。它还包含其他匿名分配，`numastat -p` 的总量则另含文件映射；两者都不是逐专家计数。同一份报告按节点列出各内存域的水位和 `numa_*`、`pgdemote_*`、`pgpromote_*` 计数：一路 DDR4 的 `free` 贴近 `low` 而另一路宽裕就是单侧承压，`numa_foreign` 增长的节点是没分到页的一路，`numa_miss` 增长的节点是这些页实际落到的地方。 [计数的含义](https://github.com/torvalds/linux/blob/v7.0/Documentation/admin-guide/numastat.rst)

运行中执行一次 `sudo systemctl daemon-reload`，核默认档普通任务仍为 80 个逻辑 CPU、`z8build.slice` 仍为 92 个。停止推理后都应还到 104 个。

**I7 对照编译共用推理核的影响。** 下面三个数各取两遍，一遍按默认，一遍按[上面的命令](#编译共用推理核)临时关掉共用：构建满载时的 decode tok/s，构建满载时长提示词的 `prompt_ms`，模型空闲时同一次构建的墙钟时间。推理低于关掉时的 95%，或者构建没有改善，就长期关掉。

平时停 `z8-infer.service` 即归还推理主线程和 HT 伙伴。若日志报告恢复失败，停服务后手动执行 `sudo /usr/local/libexec/z8-cpu-mode restore` 再核 CPU mask。完全撤销时，先停推理以及已启用的 worker，删除本节安装的 slice、服务与专用 drop-in，执行 `sudo systemctl daemon-reload` 后重启主机。普通任务恢复使用 104 个逻辑 CPU，已启用的 Buildbarn worker 按原 I5 配置启动。
