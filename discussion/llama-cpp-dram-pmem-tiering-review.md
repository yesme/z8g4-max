# llama.cpp 专家内存分层评审的复核

**结论：采纳。`tiered` 改用 `numactl --balancing --membind`，`MemoryLow` 保留 90G 并取消随缓存重算。** 评审指出的是 PR #10 的一个实际缺陷：交错策略下，被编译挤到 PMem 的专家页不会再回到 DDR4。我在 PR #10 里写的“再用到时由内核提升回来”在当时的启动前缀下不成立。

复核对象是 [专家内存分层评审](llama-cpp-dram-pmem-tiering.md)，基线 `7a1f746`。以下是源码核对，没有 Z8 实机数据。

## 对两个复核问题的回答

**一、分配和提升路径适用于这一版 llama.cpp 的普通专家缓冲。**

- `--no-host` 时专家进普通的 CPU 缓冲，是匿名内存。llama.cpp 的源码里没有 `set_mempolicy` 或 `mbind` 调用，所以这些页用的就是 `numactl` 设下的任务策略。 [主机缓冲的选择](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/src/llama-model.cpp#L1257-L1271)
- 访问时迁移先看策略有没有 `MPOL_F_MOF`，没有就直接返回。NUMA 扫描也会跳过策略不带这个标志的映射，连提示缺页都不会产生。 [迁移判定](https://github.com/torvalds/linux/blob/v7.0/mm/mempolicy.c#L3001-L3004) · [扫描时跳过](https://github.com/torvalds/linux/blob/v7.0/kernel/sched/fair.c#L3455-L3459)
- 这个标志只能由 `MPOL_F_NUMA_BALANCING` 带上，内核只在绑定和 preferred-many 两种策略上接受它，交错策略会被拒绝。 [标志校验](https://github.com/torvalds/linux/blob/v7.0/mm/mempolicy.c#L1721-L1737)
- 下沉不看内存策略，绑定在 DDR4 上的进程，页照样可以被挪到 PMem。 [下沉目标](https://github.com/torvalds/linux/blob/v7.0/mm/vmscan.c#L1021-L1058)
- 绑定加这个标志之后，提示缺页发生在策略允许的节点上时，页迁往触发访问的那个 CPU 所在的节点，也就是某一路 DDR4。 [绑定策略下的迁移](https://github.com/torvalds/linux/blob/v7.0/mm/mempolicy.c#L3020-L3070)

**二、装载偏向一路的代价不足以推翻这个选择。**

- 偏斜的代价是容量：先被触碰的那一路可能有八九十 GiB 是专家，这一路上的编译拿到的 DDR4 更少。这些页是可下沉的，编译的内存压力会把其中不读的部分挤走。
- 另一路的推理线程要跨路读专家。每个 token 的未命中读取不到 0.5 GiB，远低于两条 UPI 的带宽。交错策略下每个专家也是一半在远端，所以这一点没有变差。
- 反过来，热页回不来的代价是持续的：一轮大编译之后，推理就一直从 PMem 读专家，直到重启服务。

## 一个可选的替代

内核也允许 preferred-many 带这个标志。它在 DDR4 不够时退到 PMem 分配，不会像绑定那样等回收，装载和新分配更不容易卡住。但 `numactl` 的 `--balancing` 只对 `--membind` 生效，用 preferred-many 得自己写一小段调用 `set_mempolicy` 的包装。先按评审的绑定做；I6 在编译负载下装载模型时如果出现长时间等回收，再换。

## MemoryLow

同意保留 90G 作为起点，并取消“调缓存就重算”。它保护的是服务的总用量，不能指定哪些页留在 DDR4，随缓存逐 GiB 调整没有对应的效果。评审指出的命令错误也成立：`systemctl set-property` 一次只接受一个单元，手册已改成对 slice 和 service 各执行一次。

## 已按评审修改的内容

- `serve-llama.sh`：`tiered` 用 `--balancing --membind`，`pinned` 和 `pmem` 的主机专家不迁移，保留交错。
- 推理手册和分核手册：说明提升依赖的策略标志、绑定带来的偏斜和等回收的可能；`uploads` 改述为拟合出的有效上传速度；`MemoryLow` 的说明去掉联动重算，改正命令。
- I7 增加评审提出的三时点采集：模型预热、并行编译、回到同一段对话，各记一次推理 cgroup 在两路 DDR4 和两个 kmem 节点上的匿名页。

## 仍待实机确认

编译期间专家页是否让出、回到对话后是否回升以及回升多快、装载时两路的实际偏斜、绑定策略下装载是否会等回收。这些都只有上面的三时点采集能回答。
