# 冷 CAS 首装决定：每块 HC620 一个分片

**SATA0–3 各用整块盘的数据范围做一个冷分片，采用 `old/current/new/spare = 12/30/3/3`。** 每盘保留 24 GiB D4800X 写缓冲，每片配 212 GiB 裸索引。我的取舍是让这四盘优先服务日常构建：三处稳态追加位置，四盘合计 47.68 TiB 可轮转容量。代价是某次冷对象校验失败，可能连带淘汰同片数 TiB 的完好缓存。这里存的是可重新构建或上传的产物，我接受这项代价。部署基线 `b731908` 仍是每盘八片，下面是首装选型的依据。[现行分片几何](https://github.com/yesme/z8g4-max/blob/b731908/z8-kit/storage/z8-cold#L19-L24)

## 一次读取故障会淘汰多少

固定版 Buildbarn 先读取数据，再解码并校验。设备读取返回 `EIO` 时，这次调用直接报错。若读到了字节、解码校验失败，Buildbarn 则把**本分片从最旧块到出错块（含）**的引用立即标为不可用，等下次分配空间时再移出这些块。同片更新的块和其他盘的分片仍可用。日志中的 `Releasing N blocks due to a data integrity error` 给出这次新增的失效块数。[读错与解码失败的分支](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/flat_blob_access.go#L124-L148) · [引用失效](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/old_current_new_location_blob_map.go#L183-L199) · [淘汰范围及日志](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/old_current_new_location_blob_map.go#L235-L249) · [分配时释放](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/old_current_new_location_blob_map.go#L298-L313)

一块标称 14 TB 的盘给冷分片提供 52,080 个 256 MiB 区，共 12.71 TiB。每块占 1,085 个区，即 271.25 GiB。48 块中有 3 个备用，稳态有 45 个在用块。坏对象落在最旧块时淘汰 271.25 GiB，落在最新块时最多淘汰 11.92 TiB。如果 45 个位置等概率触发**一次**校验失败，平均是 `(1 + 45) / 2 = 23` 块，即 **6.09 TiB**。整盘永久损坏时，该盘的 11.92 TiB 可轮转容量都要重建。[分片和物理区的换算](cold-cas-one-shard-per-hc620-review.md)

这些数计的是失效块的**名义容量**。新块可能只写了一部分，同一对象也可能已有更新的副本。此后只有再次请求、且其他缓存也未命中的产物才需要回填。实际读请求集中在哪些块、校验失败多常见，本机都没有测量数据，不能由 6.09 TiB 推出一次故障需要重编多少或多久。

## 为什么仍选一片

三种布局都按每盘 52,080 个区、24 GiB 写缓冲计算。表中“单次失效”指一次解码校验失败，并沿用上面的等概率假设。每盘两片用来量化缩小淘汰范围的收益，两片各占 26,040 个区，各分 28 块，每块恰好 930 个区。[Buildbarn 分配权重](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/old_current_new_location_blob_map.go#L259-L273) · [首次填库与稳态轮转](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/old_current_new_location_blob_map.go#L315-L376)

| 每盘分片 | 每片 old/current/new/spare | 每盘追加位置，首次 → 稳态 | 四盘可轮转容量 | 单次失效，平均 / 最大 |
|---|---|---:|---:|---:|
| **1（首装）** | **12/30/3/3** | **33 → 3** | **47.68 TiB** | **6.09 / 11.92 TiB** |
| 2（折中） | 8/14/3/3 | 34 → 6 | 45.41 TiB | 2.95 / 5.68 TiB |
| 8（仓库现行） | 22/65/3/3 | 544 → 24 | 49.22 TiB | 0.78 / 1.54 TiB |

**一片与两片在首次填库时几乎打平。** 若主要追加位置各跨过一个区、前一区尚未搬完，预计每盘分别占 `33 + 30 = 63` 和 `34 + 28 = 62` 个缓存区。按预计 92 个可用区，忙时回收线在占用 64 个区处。对象大小、写回和搬迁进度都会改变实际占用，63 和 62 都只是这一场景的估算。[Linux 7.0 回收条件](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-reclaim.c#L418-L498)

**决定取舍的是稳态与恢复。** 双分片能把一次内容损坏的平均淘汰范围减半，但两个分片仍共享同一块机械盘，损失整盘时两个都不可用。单分片每天能多留 2.27 TiB 缓存，稳态每盘只有三处交错追加。写入位置数由分配器决定，实际快多少仍须上机。按这台工作站优先服务持续编译的目标，我选一片，把修复成本留给确实再次用到的产物。

I4 只验选定布局的 **33 路交错追加**，以同盘顺序写作为基线，记录每盘吞吐和缓存区水位。I5 的隔离损坏演练可直接从释放日志核对淘汰块数。两项分别回答实际写入能否持续、一次已检出的损坏波及哪些块。[I4 老化脚本基线](https://github.com/yesme/z8g4-max/blob/b731908/z8-kit/storage/cas-aging.sh) · [I5 隔离演练](https://github.com/yesme/z8g4-max/blob/b731908/tests/cold-cas-smoke.py)
