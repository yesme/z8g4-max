# 冷 CAS 四分片提案的复核

> **2026-11-18 起由[保留每盘八片、bb-storage 顺序填库](cold-cas-sequential-fill.md)取代。** 本文对机制和容量的核对仍然成立，布局结论不再采用。

**结论：采纳每块 HC620 一个分片。** 提案的核心机制在固定版本的源码里成立，而且影响比原文写的更久。另有两点补充：缓存压力要按约两倍的块数算，所以给出一个 48 块的备选；验收目标应按 HDD 顺序写的上限定，现有 I4 测不到两种布局的差别。

复核对象是 [四分片提案](cold-cas-one-shard-per-hc620.md)，基线 `7a1f746`。以下是源码核对和按规格的推导，没有 Z8 实机数据。

## 核对过的机制

1. **空库首次写入会一次建出 `current + new` 个可写块。** CAS 用不可变对象的增长策略，条件是 `current + new` 未达到配置总数。之后每一轮给前 `current` 个块各分配 8 次，给最后三个块分配 4、2、1 次。现行布局每片 68 个块，八片同盘，就是每盘 544 个追加位置；提案是每盘 43 个。 [增长策略](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/block_list_growth_policy.go#L15-L34) · [建块](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/old_current_new_location_blob_map.go#L315-L324) · [每轮分配次数](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/old_current_new_location_blob_map.go#L260-L273)
2. **这个阶段不是短暂的预热。** 前 `current` 个块按同样的次数推进，会一起写满，之后才逐个转成 current。现行布局要到每片写入约 65/90，即 72%；提案是 40/59，约 68%。冷库的头三十多 TiB 都处在这个状态。重启恢复时，最新的块同样会被重新提升为可写块。 [恢复时的分组](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/old_current_new_location_blob_map.go#L151-L165)
3. **未写满的区必须留在 Optane 上。** dm-zoned 的新 chunk 先占缓存区。回收挑的是映射最早的缓存区，不看它写没写满。chunk 挪到顺序区之后，只有对齐写指针的写入能直接落盘，其余要再占一个缓存区，之后合并。Buildbarn 的相邻对象共用扇区，并发上传的数据也会乱序到达，这两种写入都不对齐。所以追加位置多于缓存区时，会反复出现“挪走未写满的区、再为它占缓存区、再合并”。 [回收对象的选择](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-metadata.c#L1935-L1965) · [对齐与缓冲写](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-target.c#L318-L353) · [共用扇区](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/block_device_backed_block_allocator.go#L243-L260)

总块数上限是 100，现行的 93 和提案的 62 都在范围内。 [块数检查](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/configuration/new_blob_access.go#L199-L202)

## 补充一：边界时刻的缓存峰值约为块数的两倍

提案按“43 个位置各占一个区”算出 10.75 GiB，离 64 区的忙时回收线还有 21 个区。这个数只在区的中段成立。40 个块每轮各拿 8 次分配，推进几乎同步，会在很短的时间内一起跨过区边界。这一刻缓存里同时有约 40 个刚写满、还没搬走的区，加上 43 个新开的区，合计约 83 个，而可用的是 92 个。

连续负载下还有第二层限制。忙时回收在空闲缓存区回到 30% 以上就停，也就是只把占用压回约 64 个区，其中 43 个是未写满的。下一次边界需要 40 个新区，空闲的只有约 28 个，差的十几个要等回收逐个腾出，每个区一到两秒。这段等待由页缓存吸收，不会报错，但它每写 10.75 GiB 出现一次。 [回收的触发与节流](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-reclaim.c#L467-L530)

让 `2 × current + new` 不超过 64，就没有这段等待。每盘 52,080 个区，总块数要能整除它：

| 每盘块数 | old / current / new / spare | 每块 | 首次填库的位置 | 边界峰值 | 四盘容量 |
|---:|---|---:|---:|---:|---:|
| 62，提案 | 16 / 40 / 3 / 3 | 840 区，210 GiB | 43 | 约 83 区 | 48.40 TiB |
| 48，备选 | 12 / 30 / 3 / 3 | 1,085 区，271.25 GiB | 33 | 约 63 区 | 47.68 TiB |
| 42 | 9 / 27 / 3 / 3 | 1,240 区，310 GiB | 30 | 约 57 区 | 47.23 TiB |

三行的 old 与 current 之比都接近上游建议的 8∶24。不宜靠加大 old 来减少 current：上游说明 old 等于 `current + new` 时数据最多会重复一倍。备选比提案少 0.72 TiB，换来边界时刻不超过回收线。两者都能工作，差别要靠下面的交错测试来定。 [上游对 old、current、new 的说明](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/proto/configuration/blobstore/blobstore.proto)

## 补充二：性能目标按上限定

优化目标是吞吐最大化。原文沿用的四盘合计 150 MB/s 只能说明盘和链路没有故障。

**上限的来源。** 每个字节先写进 Optane 的缓存区，再由回收顺序拷到 HDD 一次。持续写入时，每盘的吞吐等于回收的拷贝速度。回收在空闲缓存区为 15%–30% 时按 75% 的速度跑，低于 15% 或设备空闲时全速。HC620 的顺序写典型值是 233 MB/s，内圈更低。所以外圈四盘合计的持续上限约为 700–930 MB/s。突发另由 Optane 吸收：提案布局下每盘约有 49 个空闲缓存区，12 GiB 左右。新布局的意义是让实际吞吐接近这个上限，旧布局下 HDD 要在几百个未写满的区之间来回追加和合并。

**现有 I4 分不出两种布局。** `cas-aging.sh` 每盘只写一条 128 GiB 的顺序流，再覆盖三遍。它检查的是单个位置的顺序写和覆盖回收，测不到多个位置交错追加。 [I4 老化脚本](../z8-kit/storage/cas-aging.sh)

**建议给 I4 加一项交错追加测试。** 在建库之前，直接对每盘的 mapper 做：

- 每盘 N 个位置，按块大小间隔，轮流追加，用和 Buildbarn 一样的缓冲写。
- N 取 43 和 33 各跑一次，对应上表的前两行；再跑一次 544 作对照。
- 记录每盘吞吐、缓存区水位和回收次数，写入量要跨过若干次区边界。
- 门槛定为同一块盘、同一区域纯顺序写速度的一个比例，比例看第一次实测再定。

这样两种布局用同一批数据比较，不需要建两次库。

## 没有核对的部分

- 四个分片下 88 个并发上传的锁竞争和 212 GiB 单张索引的并发访问代价。我没有读到这一版里 CS 写入路径持锁范围的源码，这一项留给 I5 的指标。
- 上面的吞吐、等待时间和峰值都是推导，实际值取决于对象大小分布和写回的批量。

## 若采纳，要一起改的地方

`z8-cold` 的分片数与数据、索引尺寸，`z8-cold-scan` 的每盘分片数和设备尺寸，`cas-aging.sh` 对 32 片的检查，`tiered-cache.jsonnet` 的块数，`cold-layout.json` 的分片名，对应的测试，以及存储和 Buildbarn 两份手册里的几何表。分片名变化会改变摘要的路由，所以要在首次建库前定下来。
