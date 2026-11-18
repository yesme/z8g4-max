# 冷 CAS 评审：每块 HC620 一个分片，每盘保留 24 GiB Optane

评审后的首装决定采用每盘一片、`12/30/3/3`。单个对象校验失败可能连带淘汰同片更旧的块，具体取舍见[冷 CAS 首装决定](cold-cas-shard-decision.md)。

**建议在首次建库时采用四盘四分片。** SATA0–3 的每块 HC620 各承载一个 Buildbarn 冷数据分片，每片配 212 GiB 裸索引。四盘合计少约 0.82 TiB 的可轮转块容量，换来空库填充时每盘的逻辑写入位置从 544 个降至 43 个。目的是让 24 GiB Optane 能容纳更多尚未写满的区，减少编译产物持续上传时被迫提前回收这些区的机会。

本文供 Fable 复核。讨论基线为 `ba23751`，部署脚本在该基线使用 32 片。下文容量按配置计算，吞吐和等待时间尚无 Z8 实机数据。[基线冷库配置](https://github.com/yesme/z8g4-max/blob/ba23751/z8-kit/buildbarn/tiered-cache.jsonnet#L21-L42)

## 为什么第一次填库比原先估计的更分散

新的构建数据块上传到冷 CAS。P4618 的 1,638 GiB 热层在读取未命中时回填。每个冷分片有自己的块分配器和索引。一个块内可以追加许多对象。下文的**写入位置**指一个能独立向前追加的块尾。分配器选择不同的逻辑地址，dm-zoned 再决定数据怎样落到 Optane 和 HDD。[读缓存实现](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/readcaching/read_caching_blob_access.go) · [现行冷库几何](../z8-kit/buildbarn/README.md#冷-cs-几何与容量)

`newBlocks=3` 描述的是库填起来后的目标。固定版本的 chunk storage 采用不可变对象的增长策略。空库第一次分配时，`current` 为零，分配器一直增加可写块，直到 `current + new` 达到配置的总数。写入时会轮转选择这些块，随靠前的块写满，它们才逐个移入 `current`。在稳态，三个 `new` 块按 4∶2∶1 的**分配次数**接收写入。[冷 CS 选择的策略](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/configuration/cs_blob_access_creator.go#L68-L71) · [增长条件](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/block_list_growth_policy.go#L15-L34) · [扩块和轮转](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/old_current_new_location_blob_map.go#L316-L376) · [分配次数权重](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/old_current_new_location_blob_map.go#L260-L273)

现行布局的 **24 个位置/盘** 来自稳态的 `8 × 3`。当八个分片都开始接收对象，空库填充阶段可能轮到 **`8 × (65 + 3) = 544` 个位置/盘**。之前讨论过的 `67 current + 1 new` 仍然得到 544，只把稳态位置数降到了 8。

## 两套布局的物理账

两套布局都使用每盘 52,080 个 256 MiB 区。D4800X 的 p1–p4 各 24 GiB，p5 共 848 GiB。四分片提案调整四块冷盘及 p5 向 Buildbarn 呈现的逻辑切片。SATA4–6 的归档 RAIDZ1 独立使用这张卡的其余分区。[当前 mapper 尺寸](../z8-kit/storage/z8-cold) · [分区布局](../z8-kit/storage/README.md)

| 项目 | 现行布局 | 建议布局 |
|---|---:|---:|
| 每块 HDD 的冷分片数 | 8 | **1** |
| 每片的 old / current / new / spare 块数 | 22 / 65 / 3 / 3 | **16 / 40 / 3 / 3** |
| 每个 Buildbarn 块 | 70 区，17.5 GiB | 840 区，210 GiB |
| 初次填库可轮到的位置 / 盘 | 544 | **43** |
| 稳态追加位置 / 盘 | 24 | **3** |
| 冷索引 | 32 × 26.5 GiB | 4 × 212 GiB |
| 四盘数据区，扣除 spare | 49.21875 TiB | **48.3984375 TiB** |

每盘 `16 + 40 + 3 + 3 = 62` 块，`52,080 ÷ 62 = 840` 区/块，块与区的边界对齐。扣除三个 spare，四盘可轮转容量为 `4 × 59 × 210 GiB ÷ 1024 = 48.3984375 TiB`。实际可留存的唯一对象还受块内空隙和旧对象刷新影响。保留三个 new 块，可以把同批对象将来变旧、被读取后重新写入的工作摊开。[块尺寸计算](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/configuration/new_blob_access.go#L189-L210) · [上游对 old、current、new 的说明](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/proto/configuration/blobstore/blobstore.proto)

## 24 GiB 缓冲能覆盖多少写入位置

按当前格式化几何，每盘 24 GiB 对应 96 个 256 MiB 区，扣掉元数据后预计有 **92 个可用 cache 区**。内核依据空闲区比例决定忙时回收，低水位为 30%，折合约 64–65 个区已占用。假设每个写入位置都有一个尚未写满、仍留在 Optane 的区，现行布局要 **136 GiB/盘** 才能同时容纳它们，提案要 **10.75 GiB/盘**。后者占 43 个区，到忙时回收线还有约 21 个区的余量。[当前缓存几何](../z8-kit/storage/README.md) · [Linux 7.0 回收阈值](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-reclaim.c#L36-L51)

这里有两件不同的量。**43 是分配器的位置数，10.75 GiB 是按每处一个区估算的缓存工作集。** 实际同时留在 Optane 的区数取决于对象大小、内核写回聚合、HDD 回收速度，以及是否已有可顺写的映射。上一批写满但尚未搬走的区也会占用缓存。由此能判断布局的压力方向，实际写放大和 p99 延迟仍未知。[dm-zoned 分配路径](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-metadata.c#L2041-L2076) · [回收路径](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-reclaim.c#L362-L454)

## 请 Fable 重点复核

1. **实际活跃的位置数。** 请复核空库初始化、正常轮转、从 checkpoint 恢复三条路径。尤其值得看未写满的块在重启后怎样重新分组，以及写回聚合能在多大程度上减轻 544 个逻辑位置之间的切换。[checkpoint 恢复时的分组](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/old_current_new_location_blob_map.go#L149-L174)
2. **四分片的代价。** 每片轮转单位从 17.5 GiB 增至 210 GiB，一次移出 old 块会影响更大一批对象。每盘上传与查缺也集中到一张 212 GiB 索引。请复核 88 个构建动作共享四个后端时的锁竞争、刷新成本和缓存留存率。索引槽数按 64 位容量计算，并发访问代价需另看读写路径。[索引大小计算](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/lossymap/configuration.go#L50-L72) · [索引读写](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/block_device_backed_location_record_array.go)
3. **验收能证明什么。** 现有 I4 在每盘一个地址窗口顺序覆盖，门槛为四盘合计 150 MB/s，平均每盘 37.5 MB/s。WD 对 14 TB SATA 型号给出的最大持续顺序写典型值为 233 MB/s/盘。I4 能检查磁盘路径的持续写。正式构建中交错追加、冷读与查缺同时发生时的吞吐和尾延迟，目前没有实测值。建议沿用已有的 I4 验机和 I5 水位记录，无需为此次选型建两次库。[I4 老化脚本](../z8-kit/storage/cas-aging.sh) · [WD HC620 SATA OEM 手册](https://documents.westerndigital.com/content/dam/doc-library/en_us/assets/public/western-digital/product/data-center-drives/ultrastar-dc-hc600-series/product-manual-ultrastar-dc-hc620-sata-spec.pdf)

**实施时点是首装空库。** 四个分片需要各自的数据范围、裸索引与 checkpoint。若评审采纳，应一起修订 mapper 几何、分片清单、启动守卫、按盘读扫与恢复流程、测试和手册。已写入 32 分片的库更换分片键会改变摘要的路由，已有索引和 checkpoint 无法直接套用四分片布局。[当前分片清单与恢复流程](../z8-kit/storage/README.md)
