# 存储与内存分层

这台机器在同一机箱内跑推理、编译农场和多 CLI 工作环境。本页说明每类数据放在哪种介质、访问时是否经过页缓存，以及哪些选择已经否决。数字是按源码和规格估算的，I5、I7 用实测校对。

## 直通还是过缓存

Linux 把 DDR4 和 kmem 上线的 PMem 当作两层内存：冷的可移动页从 DDR4 下沉到 PMem，再冷才丢弃并回设备重读。一份数据走哪条路，看它的热集相对总量有多大，以及后端设备比 DDR4 慢多少。

| 通路 | 适合的数据 | 代价 |
|---|---|---|
| **DAX 直通**，不进页缓存 | 总量大、每次只碰一点的数据，后端是 PMem | 每次访问都付 PMem 延迟，随机读约 300 ns，约为 DDR4 的 3 倍；不占 DDR4 |
| **页缓存**，DDR4 → kmem → 设备 | 有热集、会反复读的数据，后端是 NVMe 或 HDD | 热页常驻 DDR4；每缓存 1 GiB 约占 4 MiB 不可移动的内核结构 |

PMem 和 DDR4 只差几倍，所以直通划算。例外是每次都要整块读、还要交给显卡的数据：1017 的 routed expert 每个 token 要用约 2 GiB，从 DAX 映射上传只能单线程拷贝，所以读进普通内存，走 DDR4 到 kmem 这条分层。Optane SSD 一次随机读约 10 µs，NAND 约 80 µs，和 DDR4 差两个数量级，页缓存在这两种设备上仍然有价值。NVMe 是块设备，对它做 mmap 映射的就是页缓存，内核没有绕开的开关；要绕开只能由应用使用 `O_DIRECT`。

## 各类数据的位置和通路

| 数据 | 介质 | 通路 |
|---|---|---|
| 1017 的 Engram、tokenizer | PMem fsdax 条带，`/srv/pmem-model` | DAX 直通，每个 token 只读几行 |
| 1017 的 routed expert，约 123 GiB | 文件在同一模型卷，启动时读进主机内存 | 匿名页，先占 DDR4，没在读的下沉到 kmem；`EXPERT_MEMORY=pinned` 时锁在 DDR4 |
| Buildbarn 热 CS 索引，26 GiB | 同一模型卷的 `bb-hot-index` | DAX 直通 |
| Buildbarn 热 CS 块、AC、CMS 及后两者的索引 | P4618 XFS | 页缓存，可下沉 |
| Buildbarn 冷索引，848 GiB | D4800X p5 裸分区 | 页缓存，预读为 0，可下沉 |
| Buildbarn 冷数据 | SATA0–3 dm-zoned | 页缓存；读命中后回填热层，停留时间短 |
| 工作树、`buck-out`、Git 对象 | P4618 XFS | 文件数据走页缓存；inode 和目录项在 DDR4 |
| worker 输入缓存和构建目录 | P4618 XFS | 同上；短命的输出在回写前就被删除，多数不落盘 |
| runner 的 `/tmp` | tmpfs | 可移动页，可下沉 |
| Buck2、agent、编译进程的匿名内存 | — | DDR4，冷页下沉 |
| `/data/other` | SATA4–6 RAIDZ1 加 D4800X special | ZFS ARC，只在 DDR4，上限 4 GiB |
| 推理的 KV、非专家权重和热专家 | 四卡显存 | — |

## 只能留在 DDR4 的部分

inode 与目录项缓存、页表、页缓存的索引节点、ZFS ARC、CUDA 长期锁页和内核栈都不可移动，不能下沉到 kmem。192 GiB DDR4 的预算实际留给这一组；推理的专家默认是可下沉的普通内存，只有 `EXPERT_MEMORY=pinned` 时才把约 123 GiB 加进这一组；可移动的匿名页和文件页背后有约 964 GiB kmem。给 DDR4 减负时先看这一组的大小，例如工作树文件数和 ARC 上限，页缓存总量是次要的。kmem 自己的页描述符由 `memmap_on_memory` 放在 PMem 上。 [kmem 配置](PMEM.md#剩余-pmem-转-kmem) · [CPU 与内存保护](CPU-PLACEMENT.md)

## PMem 的三种用途

1. **模型卷。** 两路各 258 GiB fsdax 合成约 508 GiB 的条带。一套权重约 232 GiB。换模型时新旧并存约 464 GiB，加上 26 GiB 热索引约 490 GiB，放得下但余量只有约 18 GiB；长期并存多套引擎的权重前先核 `df`。
2. **热 CS 索引。** 索引是哈希表，地址上均匀分布。放在 P4618 时，它要么常驻约 26 GiB DDR4，要么在构建压力下被下沉到 kmem 后又被提升，来回迁移。放到 DAX 后不占 DDR4，也不参与 LRU。读变慢的幅度按每秒 10 万次查找估算不到一个核的 10%。 [位置与回退](../buildbarn/README.md#热-cs-索引的位置)
3. **kmem。** 其余容量作慢层内存，承接所有可移动页。这是剩余 PMem 最通用的用法。

索引直接放在模型卷里，没有单独切 namespace。每路六条 PMem 已由固件交错，跨两路的条带依赖全部十二条。索引的访问是 66 B 的随机读写，条带不提升它的吞吐；cache 的线程分布在两路上，放单路或条带的跨路比例相同。单切一路只把索引丢失的概率减半，而 PMem 换条本来就要停机，索引丢失的后果只是热层从冷库重新回填。

## 留在本地的元数据

各文件系统的元数据都记在自己的介质上，不跨设备：P4618 的在 P4618，模型卷的在 PMem，ZFS 的在 D4800X special。

- **模型卷自己的 XFS 元数据。** 超级块、AG 头、inode、extent 记录和内部日志都持久化在 PMem 条带上，没有外置日志设备。DAX 只对文件数据生效：Linux 7.0 的 XFS 读写元数据时仍把块拷进 DDR4 的缓冲区，这一点没有挂载选项可关。这份内存副本的大小跟文件数走，不跟容量走。模型卷只有几十个大文件加一个索引文件，预计是 MB 级，而且可回收，所以实际效果等同于不占 DDR4。上线后用下面的命令核对；文件数保持在这个量级，不要把小文件多的目录放进模型卷。 [XFS 缓冲区的内存来源](https://github.com/torvalds/linux/blob/v7.0/fs/xfs/xfs_buf.c#L160-L250)

```bash
sudo find /srv/pmem-model -xdev | wc -l
sudo xfs_io -r -c 'fiemap -v' /srv/pmem-model/bb-hot-index/key_location_map | tail -n 3
sudo grep -E '^xfs_(inode|buf|ili) ' /proc/slabinfo
```

`slabinfo` 是全机合计，P4618 的工作树占绝大部分；模型卷的份额按它的文件数和 extent 数估。

- **P4618 的 XFS 元数据和日志。** 放到 PMem 会让一条 PMem 故障连带丢掉系统和全部工作树，启动链也要在 initramfs 里先拼 PMem。XFS 的元数据更新先在内存攒批，瓶颈在 CPU 和锁；P4618 的日志落盘是几十微秒级。
- **ZFS 的 special。** 已在 Optane SSD 上。归档池的元数据从约 10 µs 降到 1 µs 没有实际意义，ZFS 也不使用 DAX。
- **AC 和 CMS 的索引。** 各 4 GiB，留在 P4618。CS 索引丢了只需回填，AC 索引丢了全部动作要重跑。
- **冷索引。** 848 GiB 放不进 PMem。Buildbarn 的读缓存只让热层接管读取，存在性查询和上传都直接走冷层，所以冷索引被查得比热索引更频繁，热门对象会被反复查。改成 `O_DIRECT` 会让这类查询从约 0.1 µs 变成约 10 µs 外加一次系统调用，还要给 bb-storage 打补丁。现状下预读为 0，只有被查到的 4 KiB 页进缓存，这些页最先被回收，也可以下沉。 [读缓存实现](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/readcaching/read_caching_blob_access.go)

冷索引按对象平均约 10 KiB 估算。真实装载率出来后，如果对象明显更大，索引可以缩小，那时再重新考虑它的位置。

## 故障域

| 部件 | 故障时受影响的部分 | 恢复来源 |
|---|---|---|
| P4618（RAID0，任一端点） | 系统、工作树、热 CS、AC、CMS | FIT 救援与重装；未推送的提交由开发者自己负责推到 GitHub |
| PMem（任一条） | 模型卷、热 CS 索引、该路 kmem | 重下权重；热层从冷库回填 |
| D4800X | 七个 dm-zoned 的元数据和写缓存、冷索引、special，冷库与 `/data/other` 同时不可用 | 冷库重建；`/data/other` 从独立备份恢复 |
| SATA0–3 任一盘 | 该盘八个冷分片，其余 24 片继续服务 | 换盘后重建该盘分片 |
| SATA4–6 任一盘 | RAIDZ1 降级，数据完整 | 换盘 resilver |
| 四张 V100 | 本地推理 | 云端 API 仍可用 |

SATA0–3 与 SATA4–6 分开的是盘体、线束和盘笼。两组的 dm-zoned 元数据都在 D4800X 上，所以这张卡是两组共同的单点，special 是否冗余不改变这一点。

## 等基线数据的项

以下各项先取 I5、I7 的基线再对照，无改善就不保留。 [逐项说明](../buildbarn/README.md#i5-基线之后再评估的项)

- worker 的输入缓存和构建目录是否改放 tmpfs。预期收益只有硬链接和删除的日志开销，代价是 128 GiB 可丢弃的页缓存变成不可回收的内存；准备输入的耗时占比超过 10% 才做对照。
- THP `always`、cache 容器的内存上限。
- 冷索引的大小与位置。
