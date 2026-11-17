# HC620、D4800X 冷库与 RAIDZ1

| 设备 | 物理位置 | 用途 |
|---|---|---|
| SATA0–3 | 机箱原生 3.5 英寸位 | 四个 dm-zoned mapper，分成 32 个裸冷 CAS 分片，约 50.86 TiB |
| SATA4–6 | 双光驱位的三盘笼 | 三个 dm-zoned mapper 组成 `z8data` RAIDZ1，约 25 TiB，挂载 `/data/other` |
| SATA7 | 薄光驱位 | 原光驱 |
| 槽 5 D4800X | PCIe | 两组写缓存、冷库裸索引和 ZFS special。整卡故障会同时影响两组 |
| 槽 1 P4618 | PCIe | 系统 XFS、活跃工作树、`buck-out`、Buildbarn 热层及冷分片 checkpoint |
| 两路 PMem100 | DIMM | `/srv/pmem-model`（模型与 Buildbarn 热 CS 索引）和 kmem，按 [PMem 手册](../host/PMEM.md#i4-在正式系统复用-pmem)上线 |

冷 CAS 可重建。RAIDZ1 用于归档工作树、会话日志、数据集和源码快照。D4800X 的单 special vdev 包含池元数据，独立备份 `/data/other`。虚拟机镜像、数据库与容器层留 P4618。

## 1. 列出实体设备

T4 慢扫完成、I3 通过后，先做下方的[介质错误演练](#i4-介质错误演练)，然后关机断电接回 SATA0–6 和 D4800X。以 T4 的端口、型号、序列号与 by-id 清单识别设备。以下建 GPT、dm-zoned format、写零与建池是首装步骤。接回现有同版布局时沿用原 GPT、配对、GUID 和 `cold-layout.json`，直接到[安装启动单元](#安装启动单元)。

```bash
uname -r
sudo apt update
sudo install -m 0644 host/zfs-arc.conf.example /etc/modprobe.d/z8-zfs-arc.conf
sudo apt install dm-zoned-tools zfsutils-linux gdisk parted nvme-cli smartmontools fio sysstat jq python3
grep -E '^CONFIG_(BLK_DEV_ZONED|DM_ZONED)=' "/boot/config-$(uname -r)"
sudo modprobe dm-zoned
sudo dmsetup targets | grep '^zoned'
lsblk -e 7 -o NAME,PATH,SIZE,MODEL,SERIAL,TRAN,ZONED,LOG-SEC,PHY-SEC,PARTLABEL
sudo nvme list
sudo dmzadm --version
ls -l /dev/disk/by-id/ata-* /dev/disk/by-id/nvme-*
```

Xubuntu 26.04.1 使用 Linux 7.0 GA。保留内核选定的磁盘调度器，zone write plugging 在块层负责顺序区写入顺序。Ubuntu 的 `dm-zoned-tools` 是 2.2.2 系列，OpenZFS 是 2.4.1 系列。记录当前 ABI。七块 HC620 应为 SATA 4Kn、`host-managed`，一个区 256 MiB。用 SATA0 的整盘 by-id 替换样例，其余盘照做。前一条区报告是 conventional，后一条是 sequential write required。 [官方镜像清单](https://cdimage.ubuntu.com/xubuntu/releases/26.04/release/xubuntu-26.04.1-desktop-amd64.manifest) · [Linux 顺序区写入](https://zonedstorage.io/docs/linux/sched)

```bash
disk=/dev/disk/by-id/ata-REPLACE_SATA0
cat "/sys/class/block/$(basename "$(readlink -e "$disk")")/queue/scheduler"
sudo blkzone report -c 1 "$disk"
sudo blkzone report -o 274726912 -c 1 "$disk"
```

ARC 下限 1 GiB、上限 4 GiB，留约 188 GiB 标称 DDR4 给其他服务。池只承载归档，元数据和小块在 Optane special 上，未命中的代价低。内核使用默认 dirty data 上限、5 秒 TXG 和 `zfs_arc_shrinker_limit=0`。I7 记录每路 DDR4 Normal 水位、ARC 和 I/O。 [OpenZFS 2.4 参数](https://openzfs.github.io/openzfs-docs/man/v2.4/4/zfs.4.html)

### I4 介质错误演练

在接回生产数据盘之前运行。可在同版 Xubuntu 26.04.1 虚拟机预演。使用当前内核的 `scsi_debug`、`dm-zoned` 模块和第 1 节的工具，从仓库根执行：

```bash
sudo bash tests/cold-media-smoke.sh
```

脚本只写新建的 `scsi_debug`、loop 和临时 mapper，退出自动拆掉。它将一个区写满、等回收把数据移到顺序区，再向旧区尾部注入 4 KiB 介质错误并覆写前半区。预期空闲回收卡住，直接 I/O 返回 `ENODATA`；扫描仅改一个 4 KiB 块，注错仍开启时逻辑全文校验通过，空闲区回升。保存终端与 `sudo journalctl -k -b -g 'Medium Error|critical medium error|reclaim'`。若 `modinfo scsi_debug` 找不到模块，确认安装当前 ABI 对应的 `linux-modules-extra-$(uname -r)`。 [scsi_debug 介质错误](https://github.com/torvalds/linux/blob/v7.0/drivers/scsi/scsi_debug.c#L4388-L4399)

## 2. 建 GPT 与初始化 dm-zoned

| D4800X | GPT 标签 | 字节数 | 用途 |
|---|---|---:|---|
| p1–p4 | `dmz-sata0`–`dmz-sata3` | 每个 25,769,803,776（24 GiB） | SATA0–3 缓存，`--seq=96` |
| p5 | `z8-cold-index` | 910,533,066,752（848 GiB） | 32 个裸索引 |
| p6–p8 | `dmz-sata4`–`dmz-sata6` | 每个 85,899,345,920（80 GiB） | SATA4–6 缓存，`--seq=320` |
| p9 | `z8-special` | 228,990,524,928（512 B LBA）或 228,990,521,344（4Kn），约 213.26 GiB | RAIDZ1 的 special 和内嵌 ZIL |

### 新建 GPT 九分区

从 `z8-kit` 根目录执行。替换 D4800X 整盘 by-id、T4 记录的完整型号和序列号。脚本核对身份和 1,500,301,910,016 B 容量，拒绝已挂载、带 holder 或属于已导入池的设备。它沿用实测 512 B 或 4 KiB LBA，按 1 MiB 对齐，p9 取 GPT 尾部前的全部可用空间，核对实际字节数。

```bash
bash storage/partition-optane.sh /dev/disk/by-id/nvme-REPLACE_D4800X 'T4 完整型号' 'T4 序列号' --create
```

### 首次初始化每组 dm-zoned

复制模板后编辑。`hybrid.tsv` 的第二列填每个 SATA 口对应的 ATA 整盘 by-id，保留制表符和第三列 GPT 标签。`storage.env` 只填 `Z8_OPTANE` 整盘 by-id，池 GUID 在下一节回填。每个标签都必须解析到这张卡上的正确大小分区。`dmzadm --format` 重置顺序区并写映射元数据，两块后端设备的旧数据都应视为清除。

```bash
cp storage/hybrid.tsv.example hybrid.tsv
cp storage/storage.env.example storage.env
```

编辑完执行：

```bash
sudo install -d -m 0755 /etc/z8-storage
sudo install -m 0644 hybrid.tsv storage.env /etc/z8-storage/
sudo install -m 0755 storage/{z8-storage,z8-cold,z8-cold-scan,z8-cold-health} /usr/local/sbin/
for sata in {0..6}; do
    sudo z8-storage format "$sata" --create || break
done
```

每组回显型号、分区后，输入 `hc620-N`。失败时先保存终端日志并处理该组。重新执行时单独指定失败的端口，已有签名且确认可擦才使用 `--replace`。

两组都以缓存区数作为 `--seq`。dmzadm 2.2.2 计算导出长度时扣除两套元数据、预留顺序区与探测到的坏区，内核另保留 HC620 第 0 区的成员超级块。健康盘预计导出约 52,152 个 256 MiB chunk。守卫接受 52,080–52,156 个整区，并核对实际底层设备；每个冷盘只切 52,080 区，给初始化时的尺寸波动留出余量。已经运行的 mapper 仍按原超级块几何启动，运行后坏区增加可能导致已有映射无法读取或启动。预留顺序区供后台搬迁，HC620 盘头 conventional 区属于普通随机区。D4800X 承接前台写缓冲，逻辑 chunk 与物理区的映射随回收改变。 [dmzadm 2.2.2 元数据算法](https://github.com/westerndigitalcorporation/dm-zoned-tools/blob/v2.2.2/src/dmz_lib.c#L215-L340) · [Linux 回收路径](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-reclaim.c#L159-L307)

冷库每盘 92 个可用缓存区，三盘 ZFS 组每盘 316 个。忙时约 70% 占用启动回收，空闲约 10 秒也可启动。冷库四盘在空缓存起点约 64 GiB 的区容量会到该阈值，扣除按 24 写头/盘计算的 24 GiB 后，新增窗口量级约 40 GiB。I4、I5 记实测初次达到阈值的字节量，与交接的约 52 GiB 估算校对。ZFS 组每盘约 55 GiB 区容量到阈值，理想顺序大块约对应 110 GiB 用户数据。ZFS 默认四个分配器，主 vdev 预计每 metaslab 16 GiB；`4×16/3≈21 GiB` 只给每盘的量级，CoW 碎片和并行队列会改变区占用。 [回收水位](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-reclaim.c#L418-L454) · [OpenZFS 分配器](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/zfs/spa_misc.c#L396-L404)

### HC620 盘头随机写区在混合方案里的用途

HC620 的前 524 个 conventional 区共 131 GiB，支持随机写。第 0 区存该成员的超级块。D4800X 接管前台随机写，健康的盘头区仍由 dm-zoned 管理；回收找不到顺序目的区时可以尝试用普通区。这里和 `--seq` 预留给回收的顺序区是两类区。 [Linux 7.0 回收目的区选择](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-reclaim.c#L262-L279)

## 3. 建 ZFS 池与 legacy mount 数据集

首次建池先完成[安装启动单元](#安装启动单元)的第一段。填写新 GUID 后启用挂载。已有池用原 GUID 跳过建池。

```bash
sudo systemctl start z8-dmzoned.service
sudo dmsetup status --target zoned
sudo bash storage/create-pool.sh --create
```

检查预览只有 `hc620-4/5/6` 与 `z8-special`。建池脚本校验几何和现有签名。它取刚建好的 `available` 的 10% 设为 `z8data/reserve` 的 `refreservation`，输出 `Z8_POOL_GUID=…` 后导出。把该值写进 `/etc/z8-storage/storage.env`。检查 `zdb -l` 打印的 metaslab 参数。special 约 213 GiB，按 2.4.1 默认算法预计 `metaslab_shift=31`、106 个 2 GiB metaslab，其中一个 2 GiB 内嵌日志区。注入同步写的实测见下节。 [metaslab sizing](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/zfs/vdev.c#L2950-L3018) · [内嵌日志](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/zfs/vdev.c#L1686-L1718)

`z8data/other` 用 `recordsize=1M`、`special_small_blocks=16K`，继承 `compression=zstd-3,atime=off,sync=standard,logbias=latency`。三盘 RAIDZ1 在 `ashift=12` 时，4/8/12/16/32/128/1024 KiB 依次分配 8/16/24/24/48/192/1536 KiB。默认 special 达到约 75% 后新小块回普通 vdev。`autotrim=on` 异步汇集 ZFS 释放范围，让三个 mapper 的底层映射失效；每月继续 scrub。大文件的原始两份数据列约 25.46 TiB，建池的实际可用量以 `zfs list` 为准。 [RAIDZ 空间公式](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/zfs/vdev_raidz.c#L2186-L2206) · [special 分配](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/zfs/spa_misc.c#L2146-L2182) · [TRIM](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/zfs/vdev_trim.c#L65)

## 4. I4 安装存储依赖链

### 安装启动单元

首装和重装复用都做这一段。复用时恢复 `/etc/z8-storage/{hybrid.tsv,storage.env,cold-layout.json}`，清单须与原数据及索引几何一致。

```bash
sudo install -m 0755 storage/{z8-storage,z8-cold,z8-cold-scan,z8-cold-health} /usr/local/sbin/
sudo systemctl mask zfs-import-cache.service zfs-import-scan.service
sudo install -m 0644 storage/systemd/{z8-dmzoned.service,z8-zpool.service,z8-cold.service,data-other.mount,z8-cold-scan.service,z8-cold-scan@.service,z8-cold-health.service,z8-cold-health.timer,z8-cold-selftest.service,z8-cold-selftest.timer} /etc/systemd/system/
sudo install -d -m 0755 /data/other /srv/buildbarn/tiered
sudo systemctl daemon-reload
```

两条链共享 `z8-dmzoned.service`。ZFS 链用 `z8-zpool → data-other.mount`，至少要 SATA4–6 中两个健康 mapper 和 p9。冷库链用 `z8-cold → z8-buildbarn`，仅需 p5 和已经初始化且可用的冷盘。开机各自启动，停机逆序。将单元装好、填过 GUID 后执行：

```bash
sudo z8-cold init
sudo systemctl enable --now data-other.mount z8-cold.service
bash host/run-step.sh i4-status
```

`z8-cold init` 首次写 `/etc/z8-storage/cold-layout.json`，启用清单为空。此前若已按 6,519 区初始化，停 cache、worker 和 `z8-cold.service`，把旧清单另存再 `init`，按本节重建冷分片索引和 checkpoint，并退役 CMS。GPT 和一般数据池可沿用。`z8-cold.service` 建出最多 32 个 `/dev/mapper/z8-cold-sataN-S` 及 32 个 `z8-index-sataN-S`。数据每分片 6,510 区、1,747,514,818,560 B，索引每段 28,454,158,336 B。`dm-linear` 以 512 B 扇区计数，边界按 256 MiB 对齐，索引设预读为 0。`/run/z8-cold/cold-layout.json` 记录本次有效分片，`/run/z8-cold/compose.json` 只授权相应裸设备。`/etc` 那份是持久清单，`/run` 每次启动重建。

已有 v2.20 池的迁移须先备份 `/data/other`、验证外部恢复源、停止 Buildbarn，禁用并卸载旧冷库的两个挂载单元，再导出旧池、停 mapper。此版本重建 D4800X 分区与三盘池，从外部恢复普通数据。旧冷 CAS 和所有 CMS 是可丢缓存。保留 AC。热 CS 的容量和索引同时更改，旧热 CS 块、索引、checkpoint 应整套退役后再启动。全新安装跳过迁移。

### 冷库连续覆写

首次初始化索引前做，要求四块冷盘齐备、缓存服务停止且持久启用清单为空。命令会提示输入 `EMPTY-COLD`，四路各写 `sataN-0` 开头 128 GiB，再覆盖三遍。每 5 秒记录写入量和 cache 区水位，最后两遍各至少 150 MB/s（合计、含 flush）。额外检查 NVMe 温度/节流、I/O 错误，记录首次采到 70% 水位的每盘写入量。使用 P4618 上现有日志目录。

```bash
mkdir -p ~/z8-burnin
bash host/run-step.sh i4-cold-aging "$HOME/z8-burnin"
```

通过后清零索引、建立空 checkpoint、启用已初始化分片。`reset all` 只用于首次或全量重建，整张索引分区约 848 GiB 会被清零，终端逐个报告。未达到门槛时先按盘看 `watermark.tsv` 与 NVMe 温控，必要时走[全 XFS 回退](../buildbarn/README.md#全-xfs-回退)。该回退和 `/data/other` 可以同时运行。

```bash
sudo z8-cold reset all
sudo systemctl restart z8-cold.service
sudo z8-cold check
```

### ZFS 同步写与 scrub

先确认 `/data/other` 的源，再写一份 8 GiB 临时文件；另开终端观察 `zpool iostat -vlyP z8data 1`、`/proc/spl/kstat/zfs/zil` 的 commit 计数、p9 写 I/O 和 fio 的同步 p95/p99。同步写先看日志，最终数据仍由 RAIDZ1 落盘。scrub 验毕后移除文件。

```bash
test "$(findmnt -n -M /data/other -o SOURCE)" = z8data/other &&
    sudo fio --name=zil-burnin --filename=/data/other/zil-burnin.bin --size=8G \
        --rw=write --bs=128k --ioengine=psync --direct=0 --fdatasync=1 --end_fsync=1 &&
    sudo zpool scrub -w z8data &&
    sudo zpool status -v z8data &&
    sudo rm -- /data/other/zil-burnin.bin
```

安装每月 ZFS scrub，保持池的自动 TRIM：

```bash
sudo systemctl enable --now zfs-scrub-monthly@z8data.timer
sudo zpool get autotrim z8data
```

### 缺盘停机恢复

停机换设备前从服务链停到 mapper，关机后动线：

```bash
sudo systemctl stop z8-buildbarn-worker.service z8-buildbarn.service z8-cold-scan.service 'z8-cold-scan@*.service' z8-cold.service
sudo systemctl stop data-other.mount z8-zpool.service z8-dmzoned.service
```

I4 分开做三种冷启演练，每轮检查 `bash host/run-step.sh i4-status`。SATA0–3 的一盘缺席应见 24 个可用分片，ZFS 保持 ONLINE；I5 的 cache 上线后复验启动、未命中和剩余分片读写。SATA4–6 的一盘缺席时池应 DEGRADED、32 个冷分片仍可用。整张 D4800X 拔除后二者都应由设备守卫拦下，系统仍可 SSH。接回原盘按原序列号与端口配对，ZFS 等 resilver 完成后再做下一轮。短时缺席的原冷盘带着原索引和 checkpoint 直接回归，启动时按 `/etc` 清单恢复原哈希键。

冷盘永久换盘以 SATA0 为例。关机换盘、重启，更新 `/etc/z8-storage/hybrid.tsv` 中该槽的 ATA by-id，再执行下面的命令。开机时启用的服务会自动拉起；重启后先停冷库应用、扫描及冷分片，显式运行 `map` 补装新 mapper。`reset sata0` 清空该盘八份索引和 checkpoint。只重建一片时可传完整分片名。

```bash
sudo systemctl stop z8-buildbarn-worker.service z8-buildbarn.service z8-cold-scan.service 'z8-cold-scan@*.service' z8-cold.service
sudo z8-cold disable sata0
sudo z8-storage format 0 --replace
sudo z8-storage map
sudo systemctl start z8-cold.service
sudo z8-cold reset sata0
sudo systemctl restart z8-cold.service
sudo z8-cold check
```

当天无法重建时保留禁用状态，按剩余分片启动。加回时降级阶段落到替代分片的部分对象可能再次 miss。恢复 cache 和 worker 前按 [Buildbarn 恢复](../buildbarn/README.md#冷分片恢复与-cms)处理 CMS。

ZFS 盘永久损坏时先在 `zpool status -gP z8data` 里记失效 vdev GUID。关机换盘、重启并更新 `/etc/z8-storage/hybrid.tsv`，以 SATA4 为例显式补装 mapper 后替换。池已降级导入时可继续挂载，未导入则先启动 `data-other.mount`。替换设备仍须达到 ZFS 要求的大小。

```bash
sudo z8-storage format 4 --replace
sudo z8-storage map
sudo z8-storage check-map 4
sudo systemctl start data-other.mount
sudo zpool replace z8data OLD_GUID /dev/mapper/hc620-4
sudo zpool status -gP z8data
```

等待 resilver 完成。临时掉线的原盘保持原配对，按需用 `zpool online` 恢复。只丢 p5 内容或 P4618 的 checkpoint 时，停 cache 和 worker，用 `z8-cold disable all` 后重新初始化索引及状态。若冷盘不足四块，就对已接盘逐个运行 `reset sataN`。几何记录的备份只能恢复清单。

若整张 D4800X 永久损坏，原冷库和池需重建。停 cache 和 worker，先用 `sudo z8-cold disable all` 清空持久有效清单，`init` 不会替换既有清单。按 I4 重建 GPT，更新 `/etc/z8-storage/storage.env` 的整卡 by-id，**七个 mapper 均以 `z8-storage format N --replace` 重新格式化**。重建三盘池后回填新 `Z8_POOL_GUID`，从外部备份恢复 `/data/other`。持久清单为空后才能跑 I4 覆写，再运行 `reset all` 装回冷分片。保留 P4618 的有效热 CS 与 AC，退役 CMS。恢复后留一份 [FIT 与机器外记录](../host/FIT-RECOVERY.md#每个阶段留一份到另一台机器)。

### 冷库介质扫描

冷 CAS 没有冗余，逻辑扫描找到坏块只能写零；读一遍 50.86 TiB 要按四盘线速占用一昼夜以上，并计入硬盘的年负载额度。因此定时任务只做两件事，全量逻辑读取留给有证据的盘。

- **每月自检。** `z8-cold-selftest.timer` 每月 8 日让 SATA0–3 各自启动 SMART 扩展自检。表面扫描由盘在后台完成，主机 I/O 优先，断电或重启会中止当次自检。
- **每日取证。** `z8-cold-health.timer` 每天读四盘的 SMART 和上次检查以来的内核日志。某盘出现 `critical medium error`、新的自检读失败或待处理扇区增加时，只对该盘启动 `z8-cold-scan@sataN.service`。首次运行把二手盘已有的失败自检记为历史，当前待处理扇区大于 0 仍会触发；换盘后序列号变了，该槽按首次运行重新记。状态存 `/var/lib/z8-cold-health`。
- **扫描跑完才销账。** 检查发现证据时在状态目录写 `scan-owed-sataN`，该盘的扫描跑完（退出 0 或 1）才删除它，扫描期间又有新证据时保留。扫描没能启动，或被重启、停 `z8-cold.service` 打断时，之后每天的检查会再启动一次，直到跑完。内核日志里的介质错误不依赖当天能否读到 SMART。`z8-cold.service` 没运行时当天的检查不执行，证据留到下一次。

逻辑扫描每盘串行八片，以 4 MiB 直接读；遇 `EIO` 或 `ENODATA` 才下探到 4 KiB，同一块连续两次读取失败才写零，flush 后直接读回。每片会打印字节数和逻辑偏移，退出 1 表示修过，2 表示缺盘或未完成。多块盘同时触发时按锁排队。扫描会同构建读流量竞争，按日志看进度。出现 SATA 介质错误先用 `lsblk -S`、`journalctl -k -b` 对照实际 ATA by-id。物理 LBA 经过 dm-zoned 映射，不能直接当逻辑偏移。修复后的 4 KiB 逻辑读取成功也不能证明固件重映射了原 LBA。持续报介质错误时按坏盘处理。`z8-cold-scan.service` 保留给手动四盘全量扫描。

```bash
sudo journalctl -u z8-cold-health.service -u z8-cold-selftest.service -u 'z8-cold-scan@*' -n 100 --no-pager
sudo smartctl -l selftest /dev/disk/by-id/ata-REPLACE_SATA0
sudo flock -n /run/lock/z8-cold-scan.lock /usr/local/sbin/z8-cold-scan sata0
```

同一冷盘反复报同一介质错误且 `dmsetup status` 的空闲 cache 区数迟迟不回升时，立即对该盘运行上面的单盘扫描。合并被坏块中断后会重新排队，候选未变时可能继续读同一坏块。写零落入缓存后旧位置不再有效，回收可以跳过它。回收仍停滞就保留日志并按坏盘处理。 [回收失败与重排](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-reclaim.c#L393-L514) · [缓存写入的位图更新](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-target.c#L281-L291)

直接读出 I/O 错误时 Buildbarn 会回报错误；逻辑位置恢复可读但内容校验失败后，Buildbarn 才淘汰该块及同分片更旧的块。I5 用隔离的裸设备演练。

## 5. I5 交给 Buildbarn

### I5.1 软件、目录与单元准备

主方案和全 XFS 回退从 `z8-kit` 根执行：

```bash
sudo apt install docker.io docker-compose-v2 curl jsonnet jq sysstat
sudo systemctl enable --now docker.service
sudo install -d -m 0755 /opt/z8-kit /srv/buildbarn/tiered
sudo install -m 0755 buildbarn/z8-buildbarn-check /usr/local/sbin/
sudo cp -a --no-preserve=ownership buildbarn /opt/z8-kit/
sudo install -m 0644 storage/systemd/{z8-buildbarn.service,z8-buildbarn-worker.service} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemd-analyze verify /etc/systemd/system/z8-buildbarn{,-worker}.service
cd /opt/z8-kit/buildbarn
sudo docker compose -f compose.tiered.yaml -f compose.worker.yaml build scheduler
sudo docker compose -f compose.tiered.yaml -f compose.worker.yaml pull cache runner-installer runner worker
```

主方案在 P4618 上创建热存储目录，在 PMem 模型卷上创建热 CS 索引目录并设 2 MiB extent 提示。固定镜像默认 UID 0，使用 rootful Docker 默认用户映射。Compose 由 `z8-cold.service` 生成 `devices` 列表及容器可见的固定路径，启动前守卫核对所有可用切片的表和大小、活动分片的 checkpoint、热层 XFS 路径、热索引目录的 DAX 挂载与 extent 提示，以及既有文件几何。模型卷暂不可用时按 [热 CS 索引的位置](../buildbarn/README.md#热-cs-索引的位置)把索引放回 P4618。

```bash
sudo install -d -m 0755 /srv/buildbarn/tiered/{cs-hot,cms,ac}/persistent_state
findmnt -rn -M /srv/pmem-model -t xfs -O dax=always
sudo install -d -m 0755 /srv/pmem-model/bb-hot-index
sudo xfs_io -c 'extsize 2m' /srv/pmem-model/bb-hot-index
sudo z8-buildbarn-check
sudo docker compose -p z8-tiered -f compose.tiered.yaml -f /run/z8-cold/compose.json config --quiet
```

### I5.2 分核与启动

按 [CPU 分核与 runner 归属](../host/CPU-PLACEMENT.md#生成并安装) 安装 slice 及 runner drop-in。全 XFS 回退按 [专用命令](../buildbarn/README.md#全-xfs-回退) 启动。主方案先起 cache，再起 worker：

```bash
sudo systemctl enable --now z8-buildbarn.service
sudo cat /run/z8-cold/cold-layout.json
sudo systemctl enable --now z8-buildbarn-worker.service
ss -ltn 'sport = :8980'
```

### I5.3 损坏对象、24 分片降级和定时扫描

先从仓库根运行隔离演练。脚本用已拉取的固定版 bb-storage 和两个临时 loop 设备，写坏单个测试对象，核 `NotFound`、重传读回与淘汰日志。全 XFS 回退跳过本节。

```bash
sudo python3 -B tests/cold-cas-smoke.py
```

正式服务健康时，从同一目录运行 `python3 -B tests/cold-cas-smoke.py --seed`，保存输出的 SEED。脚本预先上传 64 个小对象。关机断开 SATA0，保留原盘配对。临时冷启后确认 24 个分片，再检查缺盘对象 miss、在线对象可读与缺失对象回填。分片名单变化时，服务启动守卫会退役 max 的 CMS；边缘节点按[边缘 CMS 恢复](../buildbarn/EDGE.md#权威冷库重建后的边缘-cms)处理后再接入。

```bash
sudo jq -e '.active | length == 24' /run/z8-cold/cold-layout.json
python3 -B tests/cold-cas-smoke.py --degraded REPLACE_SEED
```

关机接回原盘，用 `i4-status` 核 32 分片，再启用每月自检和每日取证。第一次全量构建期间从 `z8-kit` 根另开终端采样，完毕按 Ctrl+C，日志末尾有四盘各自的最小空闲 cache 区数。I7 同样采一次。多次达到 70% 且写入确实受阻时，再评估前 944 GiB 配比。

```bash
sudo systemctl enable --now z8-cold-health.timer z8-cold-selftest.timer
systemctl list-timers 'z8-cold-*.timer'
bash host/run-step.sh i5-cold-watermark
```
