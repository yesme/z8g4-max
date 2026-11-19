# 冷 CAS 的分片、分块与写入流程

**每个块只有一个追加位置，每片同时有 3 个块在写，所以每盘是 8 × 3 = 24 个追加位置。这个数只由“每盘片数 × new 块数”决定，和每片有多少块、old 与 current 怎么分无关。**

本文描述的是打过[顺序填库补丁](cold-cas-sequential-fill.md)的 bb-storage `ca3d8b49a5` 和现行每盘 8 片、每片 93 块的布局。old 与 current 共 87 块，同盘八片从 14 / 73 到 28 / 59 错开；下文的图和表以中间那片的 `22/65/3/3` 为例。流程按源码核对，Z8 上还没有跑过。

## 层级

| 层 | 数量 | 大小 |
|---|---:|---:|
| 一块 HC620 的冷库范围 | 52,080 个区 | 12.71 TiB |
| 片（shard） | 每盘 8 片，共 32 片 | 6,510 个区，1.59 TiB |
| 块槽位 | 每片 93 个 | 70 个区，17.5 GiB |
| 区（dm-zoned） | 每块 70 个 | 256 MiB |

每片另有一张自己的索引，放在 Optane 上，记录“摘要 → 第几块、偏移、长度”。

## 四组是角色，不是固定位置

每片的块按年龄排成一条队列，四组是队列上的四段：

```
最旧 ────────────────────────────────────────→ 最新
[ old ×22 ][       current ×65       ][ new ×3 ]    另有 3 个空槽位（spare）
  被查到要复制     被查到不动            正在写
```

- **new**：只有这 3 个块接收写入。
- **current**：已写满，只读。被查到时不动。
- **old**：已写满，快被淘汰。被查到的对象会复制一份到 new 块保活。
- **spare**：不装数据的 3 个空槽位，用于周转。被释放的块要等读它的请求结束、持久状态更新后才能重用，这期间新块用空槽位开。 [延迟释放](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/persistent_block_list.go#L114-L123)

一个块一生的顺序是 new → current → old → 释放 → 槽位重用。93 个槽位里最多 90 个装数据，所以可用容量是 90/93。

## 一个对象怎么写进去

1. **选片**：取摘要的前 8 个字节做 rendezvous 哈希，落到 32 片之一。各片权重相同，所以均匀。 [选片](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/sharding/sharding_blob_access.go#L39-L44)
2. **选块**：在该片的 3 个 new 块里轮流。最旧的 new 块连续拿 4 个对象，第二个拿 2 个，最新的拿 1 个，然后循环。 [4:2:1](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/old_current_new_location_blob_map.go#L263-L273)
3. **占位**：持该片的写锁，从选中块的写指针处划出对象长度的一段，指针后移。对象首尾相接，不按扇区对齐。 [块内分配](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/block_device_backed_block_allocator.go#L217-L241)
4. **写数据**：放开锁，把数据写到刚划出的那段。多个上传在这一步并行，所以数据到达的先后不一定等于占位的先后。 [写入流程](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/flat_blob_access.go#L204-L229)
5. **登记**：再持锁，把位置写进索引。此后这个对象才查得到。

写入走页缓存，由内核回写。有写入时 bb-storage 至少每隔 300 秒同步一次数据，并保存块队列的状态。

## 块怎么轮转

触发点只有一个：**最旧的 new 块放不下当前这个对象**。这时：

1. 它变成 current。
2. 从空槽位里取下一个，开一个新块排到队尾。new 仍是 3 个。
3. current 已满 65 个时，最旧的 current 变成 old。
4. old 已满 22 个时，最旧的 old 被释放，槽位排到空槽队列的末尾。

[轮转代码](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/old_current_new_location_blob_map.go#L326-L363)

一片从空库到稳态的过程：

| 该片累计写入 | old | current | new | 发生了什么 |
|---|---:|---:|---:|---|
| 0 | 0 | 0 | 3 | 开槽位 0、1、2 |
| 约 1 个块 | 0 | 1 | 3 | 槽位 0 写满，开槽位 3 |
| 约 65 个块，1.11 TiB | 0 | 65 | 3 | current 到额定数 |
| 之后每满一块 | +1 | 65 | 3 | 最旧的 current 变 old |
| 约 87 个块，1.49 TiB | 22 | 65 | 3 | 90 个槽位都在用 |
| 之后每满一块 | 22 | 65 | 3 | 用一个空槽位开新块，释放最旧的 old |

上游在第一行会一次开 68 个块一起写，补丁改的就是这一点；从第三行往后两者相同。

### 上游首次填库怎么选块

**上游在首次填库时不区分 current 和 new：68 个块全部算 new，current 是 0。** current 指“写满了、还没变老”的块，空库里没有这样的块。配置里的 65 和 3 是目标数；current 不足时，上游用多开 new 块来补。 [补块的条件](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/block_list_growth_policy.go#L32-L34)

选块用的是同一套轮转，只是队列更长。前 65 个块每轮各拿 8 个对象，最后 3 个仍是 4、2、1，一轮 527 个对象： [轮转的次数](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/old_current_new_location_blob_map.go#L263-L273)

```
对象   1–8   → 块 0
对象   9–16  → 块 1
  …
对象 513–520 → 块 64
对象 521–524 → 块 65
对象 525–526 → 块 66
对象 527     → 块 67
对象 528–535 → 块 0，从头再来
```

轮转按对象个数，不按字节。前 65 个块以同样的速度变满，在该片累计写入约 57 到 66 个块的量时相继写满。每当队首的块放不下当前对象，它被改标为 current，这时不开新块。65 个都改完之后是 current 65、new 3，最后三个块此时约 43%、21%、11% 满，之后与稳态相同。 [改标而不开新块](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/old_current_new_location_blob_map.go#L326-L335)

| 该片累计写入 | 上游 current / new | 补丁 current / new |
|---|---:|---:|
| 0 | 0 / 68 | 0 / 3 |
| 30 个块的量 | 0 / 68，每块约 45% 满 | 29 / 3 |
| 约 66 个块的量 | 65 / 3 | 65 / 3 |

以上序列用真实的轮转代码跑过：前 527 个对象的落点和 68 → 3 的过程与此一致。

## 读、查缺和保活

- **读**：查索引，定位到块和偏移，读出来。对象在 old 块时，顺手复制到 new 块。
- **查缺**：只查索引。命中但落在 old 块的对象，逐个读出来，按上面同样的步骤写进 new 块，索引改指新位置。每片同一时刻只有一个查缺请求在做复制。 [查缺与保活](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/flat_blob_access.go#L231-L363)
- **旧副本**：留在原来的块里，随块释放才消失。
- **没人查的对象**：随块一路变老，最后随块释放。这就是淘汰。
- **校验失败**：从最旧的块到出错的块一并释放。

保活的复制和新上传走同一条写入路径，写进同样的 3 个 new 块，不增加追加位置。

## 落到盘上

- **槽位按盘上位置顺序发放**，之后按释放的先后重用，所以写入位置绕着这片的 93 个槽位循环前进，3 个 new 块通常是相邻的 3 个槽位。重启后空槽位的发放顺序会被打乱，新块可能不相邻。 [槽位发放](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/block_device_backed_block_allocator.go#L74-L86) · [重启时取回槽位](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/block_device_backed_block_allocator.go#L141-L156)
- **每个正在写的块对应 dm-zoned 的一个追加位置**：写指针在块的 70 个区里依次推进，当前这个没写满的区放在 Optane 缓存上，写满后搬到 HDD。
- **每盘 24 个追加位置**：8 片 × 3 个 new 块，对应 24 个没写满的缓存区，每盘可用的是 92 个。

## 24 之外还占多少缓存区

24 是没写满的区的常态数量，实际占用会高一些，原因有三个：

- **跨区的瞬间是两个。** 一个位置刚写满一个区、开始写下一个时，写满的那个还没搬走。全部位置同时跨区是上限，48 个，仍低于 64 个区的忙时回收线。
- **写入前沿是一段，不是一个点。** 占位在先、数据在后，前沿的宽度是“已占位但数据还没到”的总量。72 路并发、每个对象最多 2 MiB 时不超过 144 MiB，小于一个区，所以每个位置最多同时碰两个区，已包含在上一条的 48 里。
- **空闲 10 秒后没写满的区也会被搬走。** dm-zoned 空闲时全速回收所有缓存区。恢复写入时，相邻对象共用的那个扇区会被重写一次，不在 HDD 顺序区的写指针上，于是这个位置要重新占一个缓存区，之后再合并。位置数不变，多的是每次空闲之后每盘最多 24 个区的重复搬运。 [空闲回收](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-reclaim.c#L484-L486) · [共用扇区写两次](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/block_device_backed_block_allocator.go#L371-L387) · [不对齐的写入走缓存](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-target.c#L318-L353)

## 每个参数管什么

| 参数 | 影响追加位置 | 影响什么 |
|---|---|---|
| 每盘片数，现为 8 | 是，乘以 new 块数 | 一次校验失败波及多大；保活能并行几路 |
| new 块数，现为 3 | 是，乘以片数 | 同一批对象被摊到几个块里 |
| old 与 current 的划分，现为 14 / 73 到 28 / 59，同盘八片错开 | 否 | 保活窗口多长；被查到的对象多久复制一次；同一批对象在各片何时变老 |
| 每片总块数，现为 93 | 否 | 可用容量 `1 − 3/块数`；块的大小，即轮转和释放的粒度 |

上游策略下第三行也会影响追加位置：首次填库、填库中途重启和 current 块损坏之后，每片的可写块数是 `current + new`。前几轮讨论的片数和缓存大小，都是在迁就这一项。
