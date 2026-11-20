# 双路 DDR4 装载偏斜评审的复核

**结论：偏斜的机制成立。采用原文的做法 2，装载期间让加载线程在两路之间轮换，已在启动器里实现。原文列的两项影响里，第一项的表现要改写，第二项可以划掉。**

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

## 为什么选轮换

- **不碰上游，也不往进程里注入代码。** 只改套件自己的启动脚本。
- **保留绑定和 NUMA 平衡。** 被挤到 PMem 的页照常提升回来。
- **它不解决的一点**：两路 DDR4 都紧张时，绑定策略的新分配要等回收。做法 1 的 preferred-many 能解决这一点，留作后手。

## 实现

`serve-llama.sh` 在 `tiered` 模式下把服务命令包一层，进程号不变：

- **轮换**：后台每 0.2 秒用 `taskset` 把主线程换到另一路的推理核，每次换完查一次 `/health`，两路分到的时间相同。
- **停止**：`/health` 在装载期间返回 503，装载完才返回 200。 [就绪标志](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/tools/server/server.cpp#L706)
- **恢复**：结束时用 `taskset -a` 给所有线程恢复原来的 CPU。轮换期间新建的线程会继承当时被收窄的亲和性，HTTP 线程就是在装载前创建的。
- **自检**：恢复后在日志里打印 `numastat` 的各节点分布。上游以后若把装载挪到别的线程，轮换会悄悄失效，靠这行输出发现。
- **调参脚本**：它把同一条命令启动多次并追加自己的端口，轮换跟着每次启动生效，端口取最后一个。
- **开关**：`LOAD_ROTATE=0` 关掉。

替身进程的实跑：3 秒的“装载”里主线程在两组 CPU 之间切换了 14 次；装载末尾新建的线程只继承到一组 CPU；轮换结束后所有线程都回到完整的 CPU 集合。

## 仍待实机确认

- **实际分布和粒度。** I6 启动日志里那两行就是答案。按装载速度估，每段约几百 MiB。
- **节点距离表。** 决定一路 DDR4 紧张时，这一路上的编译先拿对面的 DDR4 还是本路的 PMem。
- **原文建议给 `pmem-numa-report.sh` 补分节点的水位和计数。** 2026-11-20 已补：每个节点每个内存域的水位，按节点的 `numa_miss`、`pgdemote_*` 和 `pgpromote_*`，全机的 `allocstall_*`。节点距离原来就在 `numactl --hardware` 的输出里。
