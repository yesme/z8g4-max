# 双路 DDR4 装载偏斜评审的复核

**首装采用按页交错读取专家权重。** 下文保留当时对偏斜机制的复核，生产实现见[当前部署](#当前部署)。

复核对象是[装载偏斜与规避方案](llama-cpp-tiered-socket-skew.md)，基线 `fd2b105`。以下是源码核对，外加在开发环境里用真实的 `taskset` 和 `curl` 对一个替身进程的实跑。没有 Z8 实机数据。

## 核对结果

成立的：

- **绑定策略优先用本地节点。** 页落在触发缺页的线程当时所在的那一路，低于水位才去掩码里的另一路。 [分配节点的选择](https://github.com/torvalds/linux/blob/v7.0/mm/mempolicy.c#L2269-L2308)
- **专家由一个线程读入。** `load_all_data` 在调用它的线程里把张量读进缓冲，这个线程是服务的主线程。 [读入权重](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/src/llama-model-loader.cpp#L1838) · [主线程装载](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/tools/server/server.cpp#L698)
- **装载后不会自己抹平。** 分层模式不扫描已在 DDR4 上的页。 [跳过顶层页](https://github.com/torvalds/linux/blob/v7.0/mm/mempolicy.c#L835-L875)
- **做法 1 的内核依据。** `mbind` 接受带 NUMA 平衡标志的 preferred-many，不带迁移标志时只换策略不搬页，之后的提升按这段内存自己的策略判定。 [标志校验](https://github.com/torvalds/linux/blob/v7.0/mm/mempolicy.c#L1721-L1737) · [提升分支](https://github.com/torvalds/linux/blob/v7.0/mm/mempolicy.c#L3026-L3040)

要更正的：

1. **影响一不是直接回收。** 原文说满的那一路上的编译会被推入 `allocstall`。分配器在本地节点低于水位时直接换下一个节点分配，后台才去下沉。只有回退列表里所有节点都低于水位才会停下来回收，这里对面的 DDR4 和两个 PMem 节点都有空闲。 [水位不够就换节点](https://github.com/torvalds/linux/blob/v7.0/mm/page_alloc.c#L3915-L3938)
2. **真正的代价可能是编译拿到 PMem 页。** 回退顺序按固件给的节点距离排，同距离时优先没有 CPU 的节点。带 PMem 的机器上，本路的 PMem 节点通常比对面那路的 DDR4 更近；那样的话，满的那一路上的编译会直接分到 PMem，而对面还空着几十 GiB DDR4。这台机器的距离表要到 T3 看 `numactl -H`。所以要看的是编译进程的页落在哪个节点，不是 `allocstall`。 [回退顺序](https://github.com/torvalds/linux/blob/v7.0/mm/page_alloc.c#L5616-L5650)
3. **影响二可以划掉。** 解码时每个 token 最多读 240 个专家、约 2 GiB，每秒十几个 token 是一二十 GiB/s，离单路六通道的上限差得远。超过 32 个 token 的批走上传路径，速度由显卡链路决定。
4. **预加载库不能靠拦截 `mmap`。** 专家缓冲由 `posix_memalign` 申请，glibc 在内部调 `mmap`，外部拦不到。要拦的是 `posix_memalign`。 [缓冲的申请](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/ggml/src/ggml.c#L380)

## 当前部署

原版在装载期间轮换主线程，就绪后用 `taskset -a` 把主线程的原始掩码写给所有线程。在 Linux 替身服务上，显式绑定一个 CPU 的工作线程因此被放宽到两个 CPU。早期脚本还会因中文 `taskset` 输出解析失败；`643d9ec` 已用 `LC_ALL=C` 修正了这一点。

首装在固定的 llama.cpp v1.0.0 上应用一个本地补丁。启动器保留 `numactl --balancing --membind`；在 tiered 模式下，路由专家的同步读操作交给短期读线程。这个线程从内核读取继承的 DDR4 节点掩码，设置 `MPOL_INTERLEAVE`，读完一个张量即退出。父线程等待当前读操作完成后才移动文件偏移。计算线程创建时继续继承原来的绑定策略与 CPU 亲和性。升级引擎时需要重新检查这个补丁的读入位置和参数入口。 [内核策略说明](https://docs.kernel.org/admin-guide/mm/numa_memory_policy.html) · [构建步骤](../z8-kit/inference/README.md#llamacpp-v100-主服务)

## 仍待实机确认

- **专家页分布及回升。** I6 就绪时看推理 cgroup 的 `memory.numa_stat` 中 `anon` 和各 DDR4 节点的 `Normal` 水位；I7 编译并行和回到对话时再取数。匿名页包括其他进程内分配，不能从 `numastat -p` 总量判定两路专家精确各占多少。
- **节点距离表。** 决定一路 DDR4 紧张时，这一路上的编译先拿对面的 DDR4 还是本路的 PMem。
- **原文建议给 `pmem-numa-report.sh` 补分节点的水位和计数。** 2026-11-20 已补：每个节点每个内存域的水位，按节点的 `numa_miss`、`pgdemote_*` 和 `pgpromote_*`，全机的 `allocstall_*`。节点距离原来就在 `numactl --hardware` 的输出里。
