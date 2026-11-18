# llama.cpp 的专家权重怎样在 DDR4 与 PMem 之间移动

**给 Fable 的建议：生产默认保留 `EXPERT_MEMORY=tiered`，只把这个模式的启动前缀改为 `numactl --balancing --membind="$Z8_DRAM_INTERLEAVE"`，推理 slice 和 service 的 `MemoryLow` 均保留 `90G`。** 取舍在两路 DDR4 的均衡方式上。现行交错策略有利于装载时把专家页均摊到两路。建议策略允许编译挤到 PMem 的页在推理恢复后重新升入 DDR4，但装载时两路拿到的页数可能不同。

评审对象是 `jackywang-xubuntu-max` 上常驻的 llama.cpp v1.0.0，与 Buildbarn 混跑。基线为 `7a1f746`。Fable 的 PR #10 将主机专家改成可迁移的普通内存并设置 90G 保护，PR #11 将推理预留提高到每路六个物理核。以下是源码核对和容量推导，尚无这台 Z8 的冷热迁移或工具响应实测。[Fable 的内存改动](https://github.com/yesme/z8g4-max/pull/10) · [基线启动器](https://github.com/yesme/z8g4-max/blob/7a1f746/z8-kit/inference/serve-llama.sh#L14-L38)

## 123 GiB 主机副本何时能把 DDR4 让给编译

机器有两路 DDR4，每路 96 GiB。I6 选定的 1017 IQ2_XXS 权重中，routed experts 合计约 123 GiB。`tiered` 通过 `--load-mode dio --no-host` 把这部分读入普通主机内存，Linux 可以迁移符合条件的页。约 103 GiB 的 Engram 查表大张量另按需映射 PMem 模型文件。四卡合计的 36 GiB 专家缓存保存主机权重的副本，命中时可省掉主机读取，缓存填满后那份约 123 GiB 的主机权重依然存在。[权重与 Engram 的放置](../z8-kit/inference/README.md#llamacpp-v100-主服务) · [主机缓冲区选择](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/src/llama-model.cpp#L1242-L1294) · [按需张量映射](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/src/llama-model.cpp#L2049-L2064)

按只扣专家权重的口径，如果 123 GiB 全在 DDR4，其余用途合计剩约 `192 − 123 = 69 GiB`。如果后来**确有** 36 GiB 专家页迁到 PMem，这个数才升到约 105 GiB。两个数都还要扣内核、推理临时缓冲和其他服务开销。采用 `pinned` 且成功锁住全部专家时，在服务运行期间编译拿不回这 123 GiB。这正是混合负载选择 `tiered` 的理由。

## 为什么要给 tiered 改启动前缀

设想一次实际使用过程：模型已预热，随后 Buildbarn 进行一轮大编译，编译结束后 harness 把工具结果交回同一模型。PR #11 将 `MOE_CACHE_CPU_SHARE` 默认设为 `0.9`。解码时专家缓存填满后，对可分流的未命中，CPU 目标承担九成，直接读取主机权重。若这些页已下沉，下一轮交互除了上传耗时，还可能直接受 CPU 读 PMem 的延迟和带宽影响。因此要分开看下面三个阶段。[PR #11](https://github.com/yesme/z8g4-max/pull/11) · [llama.cpp 的未命中分流条件](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/src/llama-moe-cache.cpp#L794-L816)

| 阶段 | 当前 `--interleave=两路DDR4` | 建议 `--balancing --membind=两路DDR4` |
|---|---|---|
| 装载专家，首次分配匿名页 | 在两个指定节点间轮流选首选分配节点，内存充足时容易接近各半 | 在两个节点内分配，受首先触碰该页的 CPU 和当时可用内存影响，可以偏向一路 |
| 编译使 DDR4 承压 | 回收线程可把符合条件的冷页下沉到已上线的 PMem kmem | 同样可下沉。回收迁移独立选择合格的慢层目标，进程的 DDR4 分配掩码不会把既有页锁死在 DDR4 |
| 工具返回，推理再次频繁访问某些页 | 普通显式交错策略缺少访问时迁移标志，无法依靠这条 NUMA 热点提升路径 | 内核可采样访问，把符合热度条件的慢层页提升到允许的 DDR4 节点。是否提升还取决于访问方式、快层余量及迁移能否成功 |

Linux 7.0 的 `demote_folio_list()` 按内存层级和允许的目标选择下沉节点。反方向上，`mpol_misplaced()` 首先检查 `MPOL_F_MOF`，缺少该标志就跳过访问时迁移。`--balancing --membind` 使绑定策略带上该标志。只开全局 `kernel.numa_balancing=2` 不能替显式交错策略补上它。在 Ubuntu 26.04 的 `numactl` 中，把 `--balancing` 加在 `--interleave` 旁也不起这个作用。[Linux 7.0 下沉目标选择](https://github.com/torvalds/linux/blob/v7.0/mm/vmscan.c#L1021-L1058) · [策略标志校验](https://github.com/torvalds/linux/blob/v7.0/mm/mempolicy.c#L1723-L1737) · [热点页的提升判定](https://github.com/torvalds/linux/blob/v7.0/mm/mempolicy.c#L2984-L3078) · [Ubuntu 26.04 numactl 手册](https://manpages.ubuntu.com/manpages/resolute/man8/numactl.8.html)

**对两路均衡的具体影响。** 现方案的理想装载分布约为每路 61.5 GiB 专家。改用绑定后，CPU 亲和性仍由推理 slice 控制。若装载线程主要跑在一路，该路会先承担更多页。单路 96 GiB 容不下全套专家，但这只说明必须利用更多容量，推不出两路各占一半。全局模式 `2` 也会跳过已在顶层 DDR4 上的页的 NUMA 提示扫描，因此不能指望它事后自动抹平两路 DDR4 的偏斜。另一个代价是新的专家匿名页要从指定的 DDR4 节点分配。两路都紧张、回收又跟不上时，即使 PMem 尚有空间，新分配仍可能阻塞或失败。[分配节点的选择](https://github.com/torvalds/linux/blob/v7.0/mm/mempolicy.c#L2269-L2308) · [分层模式下跳过顶层页扫描](https://github.com/torvalds/linux/blob/v7.0/mm/mempolicy.c#L835-L875)

这里沿用变量 `Z8_DRAM_INTERLEAVE` 存放 T3 识别出的两个 DDR4 节点号。绑定策略由命令选项决定。两路 kmem 应已作为慢层上线，允许下沉，并保留服务对慢层的访问。**建议优先满足“编译结束后推理能恢复”，接受首次分配可能偏斜。** 对成功锁页的 `pinned` 模式，交错仍有均摊固定 DDR4 占用的价值。[基线启动前缀](https://github.com/yesme/z8g4-max/blob/7a1f746/z8-kit/inference/serve-llama.sh#L83-L91) · [本机 PMem 上线配置](../z8-kit/host/PMEM.md)

## 为什么保留 MemoryLow=90G

`123 − 36 + 3 ≈ 90 GiB` 是给常驻交互服务挑初始保护值的预算：扣去可能由 GPU 命中承担的专家权重，再给引擎本身留一个约 3 GiB 的估量。在 192 GiB DDR4 上，保护推理服务的一部分用量，同时让它参与内存回收，符合混跑优先级。建议保留这个起点。父 slice 和子 service 的 90G 是同一层级链上的保护，不相加成 180G。[Fable 的预算说明](https://github.com/yesme/z8g4-max/blob/7a1f746/z8-kit/host/CPU-PLACEMENT.md#L24-L26) · [cgroup v2 内存保护语义](https://docs.kernel.org/admin-guide/cgroup-v2.html#memory-interface-files)

`memory.low` 对 cgroup 的已计费用量提供尽力保护，DDR4 和 PMem kmem 都算。匿名页从 DDR4 迁到 PMem 后，服务仍持有它，所在节点可以变化而总用量接近不变。内核看得到页的访问历史，读不到 GPU 缓存的专家名单。假设用量 126 GiB、有效保护 90 GiB，`1 − 90/126 ≈ 29%` 只是特定回收路径下的扫描比例估算。它无法指定 87 GiB 专家常驻 DDR4，也无法预测编译能拿回多少。**以后调整显存缓存大小，应独立保留这项主机内存决策，取消逐 GiB 联动重算。** [Linux 7.0 按比例保护的实现](https://github.com/torvalds/linux/blob/v7.0/mm/vmscan.c#L2458-L2519) · [llama.cpp 专家缓存的动态替换](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/src/llama-moe-cache.cpp#L211-L285)

若后续修订手册，`systemctl set-property` 每次接受一个 unit，修改 slice 与 service 需分别执行。调参器输出的 `uploads … GiB/s` 是按运行耗时拟合的有效上传速度，不能用它证明专家页在哪路内存或直接当作 PCIe 链路测量值。[Ubuntu systemctl 手册](https://manpages.ubuntu.com/manpages/resolute/man1/systemctl.1.html) · [llama.cpp 调参器的拟合和输出](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/scripts/moe-cache-tune.py#L575-L603)

## 复核与实机判据

请 Fable 优先复核两点：上述分配和提升路径是否适用于本版本 llama.cpp 的普通专家缓冲。在这台双路机器上，装载时偏向一路的代价是否足以推翻优先保留热页回升的选择。T3 现有流程验证冷页能下沉，生产判断还要看推理重新活跃后的回程。

上机只需复用原定构建，运行一轮“模型预热 → 并行编译 → 回到同一段工具对话”。在预热后、编译压力期间、恢复对话后三个时点，从仓库根目录对同一服务 PID 运行下列只读采集。按 `memory.numa_stat` 的 `anon` 分别记录两路 DDR4 与两个 kmem 节点的字节数，同时看同一工具前缀的首字延迟和恢复后的解码速度。

```bash
pid=$(systemctl show -p MainPID --value z8-infer.service)
if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
    sudo bash z8-kit/host/pmem-numa-report.sh "$pid"
fi
```

重点是编译期间推理 cgroup 的 DDR4 匿名页能否让出、恢复对话时热页去向和响应时间怎样变化。全机 `pgpromote_*`、`pgdemote_*` 也包含 Buildbarn 等进程，只作旁证。节点统计覆盖推理服务的全部匿名页，不能逐页辨认某个专家。上述预期仍待实机确认。[现有采集脚本](../z8-kit/host/pmem-numa-report.sh)
