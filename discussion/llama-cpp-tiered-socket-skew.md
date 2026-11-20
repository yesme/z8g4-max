# `EXPERT_MEMORY=tiered` 的双路 DDR4 装载偏斜与规避方案

> **生产实现已更新。** 首装仅对读入路由专家的短期线程启用内存交错。下文是原始候选方案，机制更正和最终实现见[复核](llama-cpp-tiered-socket-skew-review.md#当前部署)。

**问题：`EXPERT_MEMORY=tiered` 改用 `numactl --balancing --membind=两路DDR4` 后，单主线程装载会把约 123 GiB 主机专家页优先塞满先触碰的那一路 DDR4（极端约 `90 : 33 GiB`），导致满载那一路在并行编译时过早触及低水位下沉，并把 12 线程 CPU 未命中计算的有效内存控制器带宽上限从 12 通道对半拉低到单路 6 通道主导。**

本文接着[专家内存分层评审](llama-cpp-dram-pmem-tiering.md)和[分层评审复核](llama-cpp-dram-pmem-tiering-review.md)。基线为 `a92710a`。以下是按源码与硬件拓扑的推导，尚无 Z8 实机测量。

## 一、先区分两组都等于 123 GiB 的拆分

1017 IQ2_XXS 的 routed experts 合计约 123 GiB。讨论中容易混淆的两组数字恰好都加起来等于 123 GiB，但管的是两层完全独立的机制：

| 维度 | 谁控制 | 拆分关系 | 含义 |
|---|---|---|---|
| **显卡显存 ↔ 主机内存** | `--moe-cache-mib 36864`（三种模式共有） | 显存 `36 GiB` 热副本 + 主机剩余 `87 GiB` 未缓存专家（主机仍保留完整 `123 GiB` 母本） | 显存缓存只是副本，换出后再用到仍要从主机重读；扣掉显存命中的 `36 GiB` 后，主机侧高频读取部分约 `87 GiB`，加约 `3 GiB` 引擎开销即为 `MemoryLow=90G` |
| **主机 `DDR4` ↔ 主机 `PMem kmem`** | `EXPERT_MEMORY=tiered`（[启动器](../z8-kit/inference/serve-llama.sh)默认） | 主机完整 `123 GiB` 母本放在普通可移动匿名内存，在 `192 GiB` DDR4 与约 `964 GiB` PMem 慢层之间迁移 | 空闲或已在显存里的冷页可随编译压力下沉到 PMem，推理重新访问时由内核提升回 DDR4 |
| **主机 DDR4 内部：Socket 0 ↔ Socket 1** | `numactl` 内存策略 | `--interleave` 约 `61.5 : 61.5 GiB`；`--balancing --membind` 极端约 `90 : 33 GiB` | 本文讨论的对象：这 `123 GiB` 主机母本在左右两颗 CPU 各自的 `96 GiB` DDR4 之间怎样落位 |

## 二、为什么 `--balancing --membind` 会产生左右 Socket 偏斜

1. **为了热页回升而放弃 `--interleave`。** Linux 7.0 的 `mpol_misplaced()` 要求策略带 `MPOL_F_MOF` 标志才做访问时迁移，内核只允许 `MPOL_BIND` 和 `MPOL_PREFERRED_MANY` 携带 `MPOL_F_NUMA_BALANCING`，显式交错策略（含 `MPOL_INTERLEAVE` 与 `MPOL_WEIGHTED_INTERLEAVE`）均返回 `EINVAL`。 [策略标志校验](https://github.com/torvalds/linux/blob/v7.0/mm/mempolicy.c#L1721-L1737) · [热点页的提升判定](https://github.com/torvalds/linux/blob/v7.0/mm/mempolicy.c#L2984-L3078)
2. **绑定策略按首次触碰本地优先分配。** `--load-mode dio --no-host` 下，llama.cpp 用 `ggml_backend_cpu_buffer_type` 申请匿名虚拟内存（不调 `set_mempolicy` 或 `mbind`），再由 `llama_model_loader::load_all_data` 在单个加载主线程上顺序读入全部张量并触发缺页。`MPOL_BIND` 在允许掩码内优先从当前运行线程所在的本地节点拿页，直到该节点触及低水位才溢去另一节点。 [主机缓冲的选择](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/src/llama-model.cpp#L1257-L1271) · [模型权重读取](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/src/llama-model-loader.cpp) · [分配节点的选择](https://github.com/torvalds/linux/blob/v7.0/mm/mempolicy.c#L2269-L2308)
3. **装载完不会自行抹平。** 若几分钟加载期间主线程主要留在某一路推理核上，该路 `96 GiB` DDR4（扣掉内核与固定开销后可用约 `88–90 GiB`）会先被塞满，余下约 `33–35 GiB` 才落到另一路；若调度器在加载中途把该线程跨路迁过几次，实测比例会介于 `90 : 33` 与 `61.5 : 61.5` 之间。全局 `kernel.numa_balancing=2` 跳过已在顶层 DDR4 上的页的 NUMA 提示扫描，装载结束后的两路偏斜不会自动均衡。 [分层模式下跳过顶层页扫描](https://github.com/torvalds/linux/blob/v7.0/mm/mempolicy.c#L835-L875)

## 三、偏斜在这台机器上的两项实际影响

[分层评审复核](llama-cpp-dram-pmem-tiering-review.md)已核对过双条 `10.4 GT/s` UPI 带宽不是瓶颈（每 token 未命中专家读取不到 `0.5–1.0 GiB`）。需要额外评估的是下面两项：

1. **并行编译时单侧 DDR4 过早承压（容量与水位不对称）。**
   - [分核手册](../z8-kit/host/CPU-PLACEMENT.md)给普通任务与构建留 80 个逻辑 CPU（每路 40 个），采用 Linux 默认本地优先分配。
   - 若 Socket 0 装载后已被推理占去约 `90 GiB`（剩余空闲 DDR4 仅 `0–2 GiB`，且受 `MemoryLow=90G` 尽力保护），而 Socket 1 只占约 `33 GiB`（剩余约 `60 GiB` 空闲 DDR4），跑在 Socket 0 上的 40 个编译线程一开始申请内存就会把该路推入 `kswapd` 回收/下沉甚至直接回收（`allocstall_normal`），此时 Socket 1 仍有数十 GiB 空闲 DDR4 未被利用。
   - 现有 [采集脚本](../z8-kit/host/pmem-numa-report.sh)只抓全机汇总的 `/proc/vmstat` 部分计数，未抓 `/proc/zoneinfo` 的两路 `Normal` 水位、`allocstall_normal`、`kswapd_low_wmark_hit_quickly` 以及 `/sys/devices/system/node/node*/vmstat` 的分节点 `pgdemote_*` / `pgpromote_*`，单侧承压容易被全机均值掩盖。

2. **12 线程 CPU 未命中计算的内存控制器（IMC）通道不对称（带宽上限折损）。**
   - 默认 `MOE_CACHE_CPU_SHARE=0.9`、双路共 12 个推理线程并发直接从主机内存算九成未命中专家。
   - `50 : 50` 交错时，两颗 8269CY 共 12 个 DDR4-2933 通道均匀供数（双路合计读上限约 `230 GB/s`）；`90 : 33`（约 `73% : 27%`）偏斜时，约 `73%` 的读取落在同一颗 CPU 的 6 通道内存控制器上，双路合计有效 DRAM 读上限降为单路 IMC 的 `1 / 0.73 ≈ 1.37` 倍（约 `155–165 GB/s`）。
   - 12 个线程跑 `IQ2_XXS` 解量化加点积可能先受限于 CPU 解量化算力（数十至百 GB/s 量级），未必打满单路 6 通道，因此这一项是否有实测折损取决于 I6 调参结果。

## 四、候选处理办法对比

如果实测证实偏斜影响了 I6 解码速度或导致 I7 单侧频繁 `allocstall_normal`，可以在不牺牲“PMem 热页回升”的前提下消除或缓解装载偏斜：

| 做法 | 装载后两路 DDR4 分布 | PMem 热页能否回升 | 两路 DDR4 同满时新分配 | 需要改什么 |
|---|---|---|---|---|
| **0. 维持现状，先测再定** | 偏向先触碰的一路（极端约 `90 : 33 GiB`） | 能（`MPOL_BIND` + `MPOL_F_MOF`） | 等回收 | 只补齐 `pmem-numa-report.sh` 的分节点水位与计数 |
| **1. 交错装载 + 装载后对专家 VMA 调 `mbind` 原地换策略** | 均匀对半（约 `61.5 : 61.5 GiB`，每路各余约 `34 GiB`） | 能（VMA 策略带 `MPOL_F_MOF`） | 用 `MPOL_PREFERRED_MANY` 时可退回 PMem，不卡死 | 小型 `LD_PRELOAD` 包装或给 llama.cpp 加十几行补丁 |
| **2. 装载期轮换主线程的跨路 CPU 亲和性** | 按时间片近似对半（张量块级交错） | 能（保持 `--balancing --membind`） | 等回收 | 启动包装在 `/health` 就绪前用 `taskset` 在两路推理核间切换 |

### 做法 1 的内核机制（兼得均匀初值与热页回升）

Linux 的 `mbind(2)` 作用于虚拟地址区间（VMA），优先级高于线程级 `set_mempolicy(2)`：

1. **装载阶段用交错**：进程以 `MPOL_INTERLEAVE(DDR4_0, DDR4_1)` 启动，`load_all_data` 顺序读入 `123 GiB` 期间，物理页按 4 KiB 页轮流落在两路 DDR4（各约 `61.5 GiB`），两路各留约 `34 GiB` 空闲空间给本地优先的编译进程，12 个内存通道均匀承担后续读取。
2. **就绪前原地替换 VMA 策略（零拷贝）**：装载完成后，对存放专家权重的匿名大 VMA 调用 `mbind(addr, len, MPOL_PREFERRED_MANY | MPOL_F_NUMA_BALANCING, nodemask, maxnode, 0)`（`flags = 0`，不传 `MPOL_MF_MOVE`）。内核 `do_mbind()` 经 `vma_replace_policy()` 只改 VMA 的策略指针，不搬动任何已分配物理页。 [mbind 实现](https://github.com/torvalds/linux/blob/v7.0/mm/mempolicy.c)
3. **运行期行为**：`kernel.numa_balancing=2` 不扫描顶层 DDR4 页，未下沉部分保持 `50 : 50` 交错；编译把冷页挤到 PMem 后，推理再次访问慢层页时，`mpol_misplaced()` 从该 VMA 策略读到 `MPOL_F_MOF`（`MPOL_BIND` 与 `MPOL_PREFERRED_MANY` 共用同一提升分支），照常把热页迁回触发访问的 DDR4 节点；同时 `MPOL_PREFERRED_MANY` 允许极端压力下的新分配回退到 PMem，避免 `MPOL_BIND` 等回收阻塞。 [下沉目标选择](https://github.com/torvalds/linux/blob/v7.0/mm/vmscan.c#L1021-L1058)

实现路径有两条，都不影响磁盘布局和其他组件：
- **不改 llama.cpp 源码**：一个约 50 行 C 的 `LD_PRELOAD` 共享库，记录长度超过阈值（如 `>= 1 GiB`）的 `MAP_ANONYMOUS` 映射地址与长度，加载期继承外层 `numactl --interleave`，在模型加载完成首次处理请求或收到信号时对该区间调一次 `mbind(..., MPOL_PREFERRED_MANY | MPOL_F_NUMA_BALANCING, ..., 0)`。
- **改 llama.cpp 源码**：像 `Dockerfile.storage` 管理小补丁一样，在 `load_all_data` 结束后对 CPU 模型缓冲区间调一次 `mbind`。

## 五、建议推进顺序

1. **先把分节点水位和计数补进 `pmem-numa-report.sh`**：补齐 `/proc/zoneinfo` 两路 `Normal` 水位、`/proc/vmstat` 的 `allocstall_*` 与 `kswapd_low_wmark_hit_quickly`，以及 `/sys/devices/system/node/node*/vmstat` 的分节点 `pgdemote_*` / `pgpromote_*`，让 I6、I7 的快照能直接看到单侧偏斜和单侧回收。
2. **I6、I7 先拿实测基线**：
   - I6 加载完默认 `tiered` 后立即跑 `numastat -p PID` 记录真实初始比例，并按[推理手册](../z8-kit/inference/README.md#llamacpp-v100-主服务)对比 `EXPERT_MEMORY=tiered` 与 `EXPERT_MEMORY=pinned`（交错）在 `serve-llama.sh --tune` 下的 12 线程解码速度和有效速率。
   - I7 混跑期间对比两路 DDR4 各自的 `Normal` 水位、`pgdemote_*` 与 `allocstall_normal` 增量。
3. **按数据决定是否上做法 1**：若 `tiered` 因单侧塞满导致 I7 出现单路持续 `allocstall_normal` / 推理尾延迟抖动，或 12 线程 CPU 路径明显慢于交错布局，再采用“交错装载 + 原地 `mbind(MPOL_PREFERRED_MANY | MPOL_F_NUMA_BALANCING)`”消除偏斜。
