# HC620 SATA 与 P4800X RAIDZ1 部署

最终设备链是 SATA0–6 的七块 HC620，各与 P4800X p1–p7 中一个 **160 GiB** 分区组成 dm-zoned target。七个 target 组成 RAIDZ1。P4800X p8 使用全部余量，约 **277 GiB**，是唯一 special vdev，承载元数据和 ZIL。池名 `z8data`，父数据集 `z8data/data` 和冷 CAS 都用 `compression=zstd-3`、`sync=standard`、`logbias=latency`。7×14 TB RAIDZ1 理想数据容量约 84 TB，实际再扣元数据、padding 和预留。七块 HC620 中掉一块可降级，P4800X 是整个池的共同依赖。 [dm-zoned 元数据布局](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-zoned.html) · [OpenZFS 2.4 特殊分配类](https://openzfs.github.io/openzfs-docs/man/v2.4/7/zpoolconcepts.7.html#special-allocation-class)

## 1. 列出实体设备

从正式系统 I4 开始。关机断电接回 SATA0–6 与 P4800X，启动后用 T4 保存的 SMART、型号、序列号和 by-id 逐项对照。P4618 已在 I1 用作 XFS 根。以下建分区、dmzadm format 与建池会清除目标内容。重装或接回已建过的池时，复用原 GPT、映射表和 GUID，从第 4 节重新安装单元。

```bash
uname -r
sudo apt update
sudo install -m 0644 host/zfs-arc.conf.example /etc/modprobe.d/z8-zfs-arc.conf
sudo apt install dm-zoned-tools zfsutils-linux gdisk parted nvme-cli smartmontools fio sysstat
grep -E '^CONFIG_(BLK_DEV_ZONED|DM_ZONED)=' "/boot/config-$(uname -r)"
sudo modprobe dm-zoned
sudo dmsetup targets | grep '^zoned'
lsblk -e 7 -o NAME,PATH,SIZE,MODEL,SERIAL,TRAN,ZONED,LOG-SEC,PHY-SEC
sudo nvme list
sudo dmzadm --version
ls -l /dev/disk/by-id/ata-* /dev/disk/by-id/nvme-*
```

**Xubuntu 26.04.1 的调度器设定是保留默认。** 官方 Desktop amd64 ISO 内核是 `7.0.0-30-generic`，本次核对的更新源提供 `7.0.0-43-generic`、`dm-zoned-tools 2.2.2-1build1` 和 `zfsutils-linux 2.4.1-1ubuntu5.1`。已核 `7.0.0-43-generic` 的 Ubuntu amd64 构建配置为 `CONFIG_BLK_DEV_ZONED=y`、`CONFIG_DM_ZONED=m`。实机用 `uname -r` 记实际 ABI，`modprobe` 后 `dmsetup targets` 应列出 `zoned`。Linux 7.0 块层用 zone write plugging 串行提交同一顺序区的写请求。HC620 保留系统选中的调度器，省掉强制 `mq-deadline` 的 udev 规则。以 SATA0 整盘为例，先跑下面命令，其他六盘同样核对。第一条区报告应见 `CONVENTIONAL`，第二条应见 `SEQ_WRITE_REQUIRED`。两条 `blkzone` 都只读。 [官方镜像清单](https://cdimage.ubuntu.com/xubuntu/releases/26.04/release/xubuntu-26.04.1-desktop-amd64.manifest) · [Ubuntu 26.04 GA 内核](https://documentation.ubuntu.com/release-notes/26.04/summary-for-lts-users/) · [Ubuntu dm-zoned-tools](https://packages.ubuntu.com/resolute/dm-zoned-tools) · [Zoned Storage 写顺序](https://zonedstorage.io/docs/linux/sched)

```bash
disk=/dev/disk/by-id/ata-REPLACE_SATA0
lsblk -dn -o NAME,MODEL,SERIAL,ZONED,LOG-SEC,PHY-SEC "$disk"
cat "/sys/class/block/$(basename "$(readlink -e "$disk")")/queue/scheduler"
sudo blkzone report -c 1 "$disk"
sudo blkzone report -o 274726912 -c 1 "$disk"
```

预期七盘的 `ZONED` 都是 `host-managed`，逻辑和物理扇区都是 4,096 B，盘区都是 256 MiB。配置中的 ATA ID 对应实际 SATA0–6，NVMe ID 全使用同一个 P4800X 根 ID 的 p1–p8。若某块盘没呈现上述区型，先按 [BIOS 与 ZAC 认盘](../host/BIOS.md) 复查实机料号、AHCI 枚举和盘区。

在解压后的 `z8-kit` 根目录执行 `cp storage/hybrid.tsv.example hybrid.tsv` 和 `cp storage/storage.env.example storage.env`。使用保留制表符的编辑器。以 SATA3 为例，在 `ls -l /dev/disk/by-id/ata-*` 中找已记录序列号的整盘 ID，填进 `hc620-3` 行第二列，第三列固定为同一个 P4800X 的 `-part4`。如系统同时给这张 NVMe 卡多个别名，全表选同一种。先用 `lsblk -S` 和 `udevadm info -q path -n /dev/sdX` 对照物理 SATA 口；`/dev/sdX` 只用于本次确认。准备阶段先填好 `Z8_SPECIAL`，建池导出前再填 `Z8_POOL_GUID`。

### 核对 ARC 上下限

首装在安装 `zfsutils-linux` 前就放入配置。ARC 下限 2 GiB、上限 8 GiB。192 GiB DDR4 扣去 101 GiB pinned 预算、8 GiB ARC 后还剩约 83 GiB DDR4 给编译、系统、推理 heap 和其他服务。runner 的 512 GiB 上限跨 DDR4 和 kmem 计费，实际混合负载以两层内存和 PSI 观测为准。kmem 以 movable 慢层上线，预算中仍按 DDR4 给 ARC 留空间。OpenZFS 2.4.1 的 `zfs_arc_shrinker_limit=0` 保持默认，这会取消 shrinker 的单次页数限制，实际回收仍受可驱逐内容、当前压力与目标限制。dirty data 上限保持自动，`zfs_txg_timeout` 保持 5 秒。I7 验固定配置，发生持续内存压力或冷读延迟明显异常时再按 ARC 和 I/O 统计定位。 [OpenZFS 2.4.1 ARC shrinker](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/os/linux/zfs/arc_os.c#L58) · [OpenZFS 2.4 模块参数](https://openzfs.github.io/openzfs-docs/man/v2.4/4/zfs.4.html)

```bash
sudo modprobe zfs
cat /sys/module/zfs/parameters/zfs_arc_{min,max}  # 2147483648, 8589934592
```

若 ZFS 之前已加载且显示旧值，先用 `lsinitrd "/boot/initrd.img-$(uname -r)"` 查启动镜像是否含 `zfs.ko`。镜像含该模块时按 I1.4 用 Dracut 重建，再重启一次。重启后复核两个参数再建池。

## 2. 建八分区与 mapper

### P4800X 的 LBA 与 I/O 队列

从头部署直接新建 GPT。P4800X 的 LBA 格式只决定一个逻辑扇区是 512 B 还是 4096 B，下面的分区命令读取该值来计算 **1 MiB** 对齐。首装无需执行 `nvme format`。dm-zoned 仍向上层报告 **4 KiB** 块大小，按 HC620 的几何将缓存分区划成 **256 MiB** 的软件区。ZFS 建池用 `ashift=12`。 [Ubuntu 26.04 sgdisk](https://manpages.ubuntu.com/manpages/resolute/man8/sgdisk.8.html) · [Ubuntu 26.04 nvme format](https://manpages.ubuntu.com/manpages/resolute/man1/nvme-format.1.html) · [Linux 7.0 mapper 队列参数](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-target.c#L928)

```bash
P4800X=/dev/disk/by-id/nvme-REPLACE_P4800X
ns=$(basename "$(readlink -e "$P4800X")")
sudo nvme id-ns -H "$P4800X"
sudo nvme id-ctrl -H "$P4800X"
lsblk -dn -o NAME,MODEL,SERIAL,LOG-SEC,PHY-SEC "$P4800X"
sudo blockdev --getss "$P4800X"
cat "/sys/class/block/$ns/queue/scheduler"
```

方括号标出实际使用的调度器。P4800X、P4618 和七块 HC620 沿用 Linux 7.0 默认队列配置，记录值供出错时定位。 [Linux 7.0 NVMe PCI 驱动](https://github.com/torvalds/linux/blob/v7.0/drivers/nvme/host/pci.c)

### 新建 GPT 八分区

仅用于已确认可清空的 P4800X 首装。先用整盘 by-id 核对型号、序列号和容量，确认所有分区均未挂载，且未被 md、device-mapper 或已导入的 ZFS 池占用。P4618 的两个系统盘端点按 I1 留下的序列号区分。

```bash
P4800X=/dev/disk/by-id/nvme-REPLACE_P4800X
lsblk -o NAME,MODEL,SERIAL,SIZE,TYPE,FSTYPE,MOUNTPOINTS "$P4800X"
sudo sgdisk -p "$P4800X"
```

核对完再执行下面这一段。先清掉旧 GPT/MBR，再一次写入新布局。p1–p7 各 160 GiB，p8 使用 GPT 最后的可用空间。已有 48 GiB 版混合 mapper 或池时，先保留数据和配置，重新分区与初始化按重建处理。 [Ubuntu 26.04 sgdisk](https://manpages.ubuntu.com/manpages/resolute/man8/sgdisk.8.html)

```bash
(
    set -e
    [[ -b "$P4800X" && $(lsblk -dnro TYPE "$P4800X") == disk ]]
    # 在清表前确认 7 × 160 GiB 后还能留至少 192 GiB 给 p8，加 2 MiB GPT/对齐余量。
    (( $(sudo blockdev --getsize64 "$P4800X") >= (7 * 160 + 192) * 1024**3 + 2 * 1024**2 ))
    logical_bytes=$(sudo blockdev --getss "$P4800X")
    case "$logical_bytes" in
        512|4096) align_sectors=$((1048576 / logical_bytes)) ;;
        *) printf 'Unexpected LBA size: %s\n' "$logical_bytes" >&2; exit 1 ;;
    esac
    gpt_args=(--clear --set-alignment="$align_sectors")
    for i in {1..7}; do
        gpt_args+=(--new="$i:0:+160G" --change-name="$i:dmz-sata$((i-1))")
    done
    gpt_args+=(--new=8:0:0 --change-name=8:z8-special)
    sudo sgdisk --zap-all "$P4800X"
    sudo sgdisk "${gpt_args[@]}" "$P4800X"
    sudo sgdisk --verify "$P4800X"
    sudo partprobe "$P4800X"
    sudo udevadm settle
    sudo sgdisk --print "$P4800X"
    lsblk -b -o NAME,START,SIZE,PARTLABEL,FSTYPE,MOUNTPOINTS "$P4800X"
)
```

检查 p1–p7 各为 171,798,691,840 B、p8 约 277 GiB。旧分区表清除后，盘面上的旧文件系统或池签名仍可能被识别。如果新分区显示旧 `FSTYPE`，先用 `sudo wipefs /dev/disk/by-id/实际名称-partN` 确认，在该分区确实可清空时用 `sudo wipefs --all /dev/disk/by-id/实际名称-partN` 清理签名，再做 dm-zoned 初始化和建池。 [Ubuntu 26.04 wipefs](https://manpages.ubuntu.com/manpages/resolute/man8/wipefs.8.html)

### HC620 盘头随机写区在混合方案里的用途

HC620 14 TB 的 HM-SMR 盘面有两种区。WD SATA 规范给出每区 256 MiB，盘头连续 **524 个 `CONVENTIONAL` 区，共 131 GiB**，可随机读写。其后是 **51,632 个 `SEQ_WRITE_REQUIRED` 区**，每次写入必须从**各区自己的写指针**开始。区内已写位置仍可随机读取。 [WD HC620 SATA 规范，第 23–24 页及 §10.20.5](https://documents.westerndigital.com/content/dam/doc-library/en_us/assets/public/western-digital/product/data-center-drives/ultrastar-dc-hc600-series/product-manual-ultrastar-dc-hc620-sata-spec.pdf#page=23)

**加 P4800X 后，HC620 盘头的随机写能力退出前台缓冲。** 新 chunk 首次写入、以及顺序区需要缓冲的覆写，都从 P4800X 的 `cache` 空闲链表分配。Optane 无空闲区时，前台等后台回收。每个 160 GiB 分区名义 **640 个 256 MiB 区**，原 48 GiB 对应 192 个。两套映射元数据等占用从实机 `dmsetup status` 的 cache 总数核对。如果用 HC620 单盘运行 dm-zoned，前台随机写与元数据才会直接使用盘头普通区。 [Linux 7.0 首次写入分配](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-metadata.c#L1918) · [覆写缓冲分配](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-metadata.c#L2028)

**盘头区仍在 mapper 内。** 第 0 区保存 HC620 的成员超级块，剩余健康普通区计入 mapper 的数据容量。回收 P4800X 上有有效数据的区时，内核优先找顺序目的区。顺序目的区完全分配不到时，才尝试用盘头普通区承载数据，之后已映射到这些区的数据可直接在 HDD 上读写。只要顺序区长期有空位，盘头普通区可以长期基本闲着。实机用 `sudo dmsetup status hc620-0` 看 `random` 的空闲数/总数，全健康时预期初建后接近 `523/523 random`。七块 HDD 都交给各自 mapper 管理。 [Linux 7.0 盘头区分类](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-metadata.c#L1296) · [回收目标选择](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-reclaim.c#L262) · [状态输出](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-target.c#L1008)

### 16 个预留顺序写区何时使用

Linux 7.0 的源码路径如下。

1. **启动时建空闲链表。** Ubuntu 26.04 的 `dmzadm` 默认每块 HDD 预留 16 个，将这个数写入 mapper 的元数据。启动时内核从当前未映射的顺序写区取区，标记 `DMZ_RESERVED` 并放入 `reserved_seq_zones_list`，其余空闲顺序区进入 `unmap_seq_list`。16 是建表目标，也是初始化时从导出容量扣掉的逻辑 chunk 数。每组折合 **4 GiB**，七组折合 **28 GiB 原始容量**。物理区号由启动时的映射状态决定。 [Ubuntu 26.04 dmzadm](https://manpages.ubuntu.com/manpages/resolute/man8/dmzadm.8.html) · [Linux 7.0 链表初始化](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-metadata.c#L1674)
2. **前台按 chunk 映射写。** 此双设备布局下，写一个尚未映射的 chunk 时先领 P4800X 的 cache zone，即使应用发出顺序写也走这条初始分配路径。已映射到 HC620 的 chunk，写入位置恰好等于当前写指针时直接写 HDD，位置不同则写到配对的 Optane buffer。前台申请 cache zone 时未带 `DMZ_ALLOC_RECLAIM`。 [Linux 7.0 首次映射](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-metadata.c#L1918) · [Linux 7.0 前台写分流](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-target.c#L298)
3. **回收从预留链表领区并真正发写。** 回收线程处理含有效数据的 cache/random 数据区时，`dmz_reclaim_rnd_data()` 用 `DMZ_ALLOC_SEQ | DMZ_ALLOC_RECLAIM` 申请搬迁目的地。普通空闲顺序区找不到时，`dmz_alloc_zone()` 摘下预留链表第一个区并减计数。随后 `dmz_reclaim_copy()` 将目的地址设为 HC620，调用 `dm_kcopyd_copy()`，按顺序写入有效数据，必要时补零推进写指针。复制成功后，`dmz_map_zone()` 把该物理区映射为 chunk 的数据区，释放原随机区。它随后能承担读取和符合写指针的前台写入。 [Linux 7.0 预留区回退](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-metadata.c#L2082) · [Linux 7.0 搬迁和重映射](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-reclaim.c#L262) · [Linux 7.0 提交顺序写](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-reclaim.c#L128)
4. **回收已有 HDD 数据区时还要看写指针。** buffer 中的有效块全在原 HDD 区当前写指针处或之后时，可以续写原区并释放 buffer。若有有效块在写指针之前，先把原 HDD 区仍有效的旧块合进随机写 buffer，再解除原 HDD 区的映射。合并后的 buffer 可由后续回收移回 HDD。预留列表为空时，回收的候选选择会优先找带 buffer 的顺序区来处理。标有 `DMZ_RESERVED` 的 HDD 区正常释放后，经 reset 回预留链表。运行中预留列表里的空闲区可以少于 16。 [Linux 7.0 回收候选选择](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-metadata.c#L1892) · [Linux 7.0 回收分支](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-reclaim.c#L341) · [Linux 7.0 释放归队](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-metadata.c#L2141)

**触发回收和领到预留区是两个条件。** 此布局下后台回收在 target 空闲约 10 秒，或忙时 cache 空闲比例降到 30% 及以下时可运行。普通顺序区耗尽是步骤 3 的分配回退条件。普通顺序区始终有空位，或者回收能直接续写原区时，预留区可以一直空着。ZFS 可用空间百分比无法直接推出 mapper 的空闲顺序区数量。 [Linux 7.0 回收触发](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-reclaim.c#L418)

**160 GiB 给的是更多同时缓冲的 chunk。** 从全空起、近似写满每个区且均匀分到七盘，忙时 30% 水位对应每盘已占用约 112 GiB。以六份数据加一份校验粗算，池侧约 672 GiB 对比原 48 GiB 布局下约 202 GiB。两者都是忽略元数据、padding 和分布偏差的量级估算。零散 4 KiB 写入触及不同 chunk 时，每次仍可占一个区，实际写入字节远低于这个数。耗尽后的等待取决于搬迁有效量、写指针、寻道与并发，实际读写可能命中仍在 cache 的数据。空闲回收受目的区可用量与候选状态制约。持续吞吐最终看 HDD、归并和 discard；较大的 cache 可能改变合并次数与写放大，用 I4 数据评估。 [Linux 7.0 回收与水位](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-reclaim.c#L418) · [dmzadm 2.2.2 容量计算](https://github.com/westerndigitalcorporation/dm-zoned-tools/blob/v2.2.2/src/dmz_lib.c#L331)

### 首次初始化每组 dm-zoned

`dmzadm --format` 在 **I4 首次建池前，每组只做一次**。这是给「一个 P4800X 分区 + 一整块 HC620」建立 dm-zoned 自己的盘上布局。工具重置 HDD 顺序区的写指针，在 P4800X 分区里写两套映射表、有效块位图和超级块，并在 HC620 上写成员超级块。原顺序区的数据会失去有效状态，旧映射也会被覆盖。这是一项破坏性初始化，写入范围限于命令传入的那一整块 HDD 和那一个 SSD 分区。它使用 zone reset 和元数据写入，无需全盘覆零，P4800X 的 GPT、其他分区、p8 和 LBA 格式都在其目标之外。 [Ubuntu 26.04 dmzadm 手册](https://manpages.ubuntu.com/manpages/resolute/man8/dmzadm.8.html) · [WD 工具源码](https://github.com/westerndigitalcorporation/dm-zoned-tools/blob/master/src/dmz_format.c#L277)

`hybrid.tsv` 是七行设备配对表，用持久的 by-id 记录每块 SATA 盘对应哪个 P4800X 分区。启动脚本也读这张表。填好 `hybrid.tsv.example`，另存为 `hybrid.tsv`。以下先展示 `hc620-0` 的单组命令。在 T4 已核盘型、zone 布局和 SMART 的基础上，再核 `lsblk` 中的真实设备、分区号、序列号和挂载状态。两者都确认可清空才运行初始化。若同一对设备已有正确的 dm-zoned 元数据，直接用 `--start`。

```bash
name=hc620-0
# 将两个路径换成 hybrid.tsv 对应行的实际值。第一项必须是 P4800X 的分区。
cache=/dev/disk/by-id/nvme-REPLACE-P4800X-part1
hdd=/dev/disk/by-id/ata-REPLACE-SATA0
cache_device=$(readlink -e -- "$cache")
hdd_device=$(readlink -e -- "$hdd")
lsblk -b -o NAME,PATH,MODEL,SERIAL,TYPE,SIZE,ZONED,MOUNTPOINTS "$cache_device" "$hdd_device"
```

核完身份后在同一终端执行。命令前先核第一项确为 160 GiB 分区，第二项确为 host-managed 整盘。`--label` 给每组固定名称，避免同一张 P4800X 的分区用相同序列号生成重名 mapper。保留默认预留和回收参数。

```bash
if [[ $(lsblk -bdnro TYPE,SIZE -- "$cache_device") == 'part 171798691840' &&
      $(lsblk -dnro TYPE,ZONED -- "$hdd_device") == 'disk host-managed' ]]; then
    sudo dmzadm --format "$cache_device" "$hdd_device" --label="$name"
else
    printf 'Device type or size did not match. Check both paths.\n' >&2
fi
```

上一步成功后可选做 `sudo dmzadm --check "$cache_device" "$hdd_device"`，它检查未启动设备的元数据。然后启动并检查 mapper。

```bash
sudo dmzadm --start "$cache_device" "$hdd_device"
sudo udevadm settle
sudo dmsetup table "$name"
sudo dmsetup status "$name"
lsblk -d -o NAME,LOG-SEC,PHY-SEC,ZONED "/dev/mapper/$name"
lsblk -D "/dev/mapper/$name"
```

首组通过后按 `hybrid.tsv` 核对其余六组，每组执行一次初始化。下次开机，`z8-storage map` 只会对原配对调用 `dmzadm --start`。暂时掉盘后回插也是同一路径。若 `--start` 失败，先检查盘是否齐全、配对、日志及现有元数据，保留原盘状态。 [内核 dm-zoned 使用说明](https://docs.kernel.org/admin-guide/device-mapper/dm-zoned.html)

检查时用 `sudo dmsetup status hc620-0`。`cache`、`random`、`sequential` 分别报告 P4800X 缓冲区、HC620 盘头普通数据区和 HC620 普通顺序区的空闲数/总数。顺序预留计数没有单独输出。I4 的持续写和覆盖测试可结合 HDD 写入量与 `cache` 空闲区回升观察后台搬迁。`blkzone report` 只报告 HDD 的区类型和写指针，盘头 `CONVENTIONAL` 的映射占用看 `dmsetup status` 的 `random`。 [Linux 7.0 status 字段](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-target.c#L1008)

## 3. 建 ZFS 池与 legacy mount 数据集

### P4800X 的 ZIL 空间

ZIL 是 ZFS 用来持久化和恢复同步事务的意图日志。SLOG 是通过 `log` 添加的独立日志 vdev。Xubuntu 26.04.1 使用的 OpenZFS 2.4.1 在有 SLOG 时优先用它，随后依次尝试 special 内嵌日志区、special 普通空间、RAIDZ1 内嵌日志区、RAIDZ1 普通空间。这台机器让 p8 同时承担 special 和低延迟日志。另从同一张 P4800X 切一块做 SLOG 仍共用同一设备队列和控制器。 [OpenZFS 2.4.1 分配顺序](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/zfs/zio.c#L4249)

采用 OpenZFS 的自动预留。以约 277 GiB 的 p8 和默认目标 200 个 metaslab 算，`277 / 200 ≈ 1.385 GiB`，`highbit64` 得到 `metaslab_shift=31`，预计约 138 个 **2 GiB** metaslab。区数超过 `zfs_embedded_slog_min_ms=64` 时，从中选一个内嵌日志区。同步日志可继续使用 special 普通空间。把尾部约 85 GiB 交给 p8 增加普通 special 余量，按默认算法仍是一个 2 GiB 内嵌区。25% 的 `zfs_special_class_metadata_reserve_pct` 是小数据块转向普通数据 vdev 的阈值。RAIDZ1 池的 p8 不能原地缩小或移除，扩容则要有后方连续空间或更换设备。 [OpenZFS 2.4.1 大小计算](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/zfs/vdev.c#L2766) · [内嵌日志区选择](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/zfs/vdev.c#L1582) · [移除 vdev 的限制](https://openzfs.github.io/openzfs-docs/man/v2.4/8/zpool-remove.8.html)

建池前用 `zfs version` 确认工具与正在加载的模块都是 2.4.1。用下列命令记录参数。前三项预计依次是 `1`、`64`、`25`，ARC 上下限应与刚安装的配置一致。`zil_special_is_slog=1` 使适合直接记录的同步写数据可先写到 special 上的 ZIL。 [Ubuntu OpenZFS 2.4.1 包](https://packages.ubuntu.com/resolute-updates/zfsutils-linux) · [OpenZFS 2.4 模块参数](https://openzfs.github.io/openzfs-docs/man/v2.4/4/zfs.4.html)

```bash
sudo modprobe zfs
zfs version
for setting in zil_special_is_slog zfs_embedded_slog_min_ms zfs_special_class_metadata_reserve_pct \
    zfs_arc_min zfs_arc_max zfs_arc_shrinker_limit zfs_dirty_data_max zfs_txg_timeout \
    zfs_trim_txg_batch zfs_trim_extent_bytes_min zfs_trim_extent_bytes_max; do
    printf '%s=' "$setting"
    cat "/sys/module/zfs/parameters/$setting"
done
```

### 建池命令

```bash
maps=(/dev/mapper/hc620-{0..6})
special="${P4800X}-part8"
# 预览须显示七个 mapper 与 p8 special。-f 接受单盘 special 与
# RAIDZ1 数据 vdev 的冗余差异。请先核对所有 by-id 和容量。
sudo zpool create -n -f -o ashift=12 -o cachefile=none -o autotrim=on -m none \
    z8data raidz1 "${maps[@]}" special "$special"
# 仅首次建池时对相同设备执行，去掉 -n。
sudo zpool create -f -o ashift=12 -o cachefile=none -o autotrim=on -m none \
    z8data raidz1 "${maps[@]}" special "$special"
sudo zfs create -o mountpoint=legacy -o compression=zstd-3 -o atime=off \
    -o checksum=on -o dedup=off -o copies=1 -o redundant_metadata=all \
    -o xattr=sa -o dnodesize=auto -o primarycache=all \
    -o sync=standard -o logbias=latency z8data/data
sudo zfs create -o mountpoint=legacy -o recordsize=1M \
    -o special_small_blocks=0 z8data/data/buildbarn
sudo zpool list -H -o guid z8data
sudo zpool status -P z8data
sudo zpool get autotrim z8data
sudo zfs get -r compression,recordsize,special_small_blocks,mountpoint,sync,logbias,primarycache z8data/data
sudo zfs get -r checksum,dedup,copies,redundant_metadata,xattr,dnodesize,primarycache,atime z8data/data
sudo zdb -l "$special" | grep -E 'metaslab_shift:|asize:'
sudo zpool export z8data
```

父数据集负责挂载和属性继承。CAS 子数据集显式设 `special_small_blocks=0`，应显示 `local`。CAS 最终数据块以 1 MiB 的记录尺寸写 RAIDZ1，文件间接块、其他元数据和同步日志仍可走 special。CAS 占用 special 的数量按 `zpool list -v` 和实际轮转测，容量规划不依赖 1 GiB 估计。池专用于这一个可重建的冷 CAS 数据集。日常保持空余空间，冷 CAS 不做快照，以便覆盖后的旧 ZFS 块释放给 dm-zoned。单个 P4800X 故障可造成整池丢失，备份保存在独立设备。活跃模型照常走 PMem，VM 镜像、数据库和容器层放 P4618。p8 用 `zdb -l` 核实际 `metaslab_shift`，31 对应 2 GiB，按 `asize >> metaslab_shift` 算区数并和 64 比较。记录当前 `hostid` 和 `/etc/hostid` 供重装后诊断导入。 [OpenZFS 2.4 数据集属性](https://openzfs.github.io/openzfs-docs/man/v2.4/7/zfsprops.7.html) · [zdb 标签检查](https://openzfs.github.io/openzfs-docs/man/v2.4/8/zdb.8.html)

`xattr=sa`、`dnodesize=auto`、`atime=off` 与 `redundant_metadata=all` 固定。冷 CAS 继承 `primarycache=all`。Buildbarn 对同一条 1 MiB ZFS 记录里的多页缺页可以复用 ARC 中的数据块，避免从记录中间开始读时因数据块过早驱逐而反复读盘。512 GiB P4618 热层承担后续 blob 的重复读取。ARC 全池共用 8 GiB 上限，不设 L2ARC。若已按旧配方创建冷 CAS，执行 `sudo zfs inherit primarycache z8data/data/buildbarn`。 [Buildbarn 块文件 mmap](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blockdevice/new_block_device_from_file_unix.go#L44) · [OpenZFS 缺页读](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/os/linux/zfs/zfs_vnops_os.c#L4122) · [OpenZFS 部分记录读取](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/zfs/dmu.c#L573)

`autotrim=on` 由后台线程汇集近期释放的范围，再向支持 discard 的叶设备提交回收提示。删除和覆盖时仍可能与后台 TRIM 争用队列。七个 mapper 收到 discard 后由 dm-zoned 把相应块标为无效，p8 则走 NVMe 自身的 discard。尚未收到 discard 的旧 LBA 可能继续占用有效位，直到覆盖或收到 discard。保持 2.4.1 的 `zfs_trim_txg_batch=32`、`zfs_trim_extent_bytes_min=32768` 和 `zfs_trim_extent_bytes_max=134217728`，队列和并发也保持默认。mapper 报告的 4 KiB 粒度、最多 256 MiB，是设备这一层的限制。对实体 HC620、P4800X 的 p1–p8 与池成员均不要手动运行 `blkdiscard`。 [OpenZFS 2.4.1 TRIM 实现](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/zfs/vdev_trim.c#L65) · [Linux 7.0 dm-zoned discard](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-target.c#L355)

### 冷 CAS 压缩

`compression=zstd-3` 在父数据集 `z8data/data` 设置一次，冷 CAS 子数据集继承。OpenZFS 2.4.1 默认对至少 128 KiB 的记录先试 LZ4，未达阈值再试 Zstd-1。任一试压通过后，才用 Zstd-3 生成最终压缩结果，两次都未通过则按未压缩写入。试压仍消耗 CPU，实际减少落到七块 HC620 的写入字节取决于数据。 [OpenZFS 2.4 参数](https://openzfs.github.io/openzfs-docs/man/v2.4/4/zfs.4.html#zstd_earlyabort_pass) · [OpenZFS 2.4.1 试压实现](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/zstd/zfs_zstd.c#L506)

Buildbarn 固定镜像 `ca3d8b4` 在写入冷块文件前已对每个 CAS chunk 做 Zstd 编码。ZFS 试压针对写入文件系统的整条记录，仍可能压缩记录里的填充等内容。I4 照常做高熵覆盖验收，I5 用真实 Buck2 产物填充后，可用 `sudo zfs get refcompressratio z8data/data/buildbarn` 查看 ZFS 层额外取得的压缩比。 [Buildbarn 本地 Chunk Storage](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/configuration/cs_blob_access_creator.go#L65) · [Buildbarn 磁盘编码](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/coder/chunk_coder.go#L13)

如果按旧文档建过冷 CAS 且父数据集已设 `zstd-3`，用下列命令移除子数据集的本地覆盖。子数据集应显示 `zstd-3`，来源为 `inherited from z8data/data`。属性只影响新写入的块。 [OpenZFS compression 属性](https://openzfs.github.io/openzfs-docs/man/v2.4/7/zfsprops.7.html#compression)

```bash
sudo zfs inherit compression z8data/data/buildbarn
sudo zfs get -r compression z8data/data
```

## 4. I4 安装存储依赖链

从 `z8-kit` 根执行。将 `hybrid.tsv`、`storage.env` 放在当前目录，`storage.env` 从样例填入 p8 by-id 和上一步 GUID。先只安装到挂载层。

```bash
sudo install -d -m 0755 /etc/z8-storage /data
sudo install -m 0600 hybrid.tsv storage.env /etc/z8-storage/
sudo install -m 0755 storage/z8-storage /usr/local/sbin/
sudo install -m 0644 storage/systemd/{z8-dmzoned.service,z8-zpool.service,data.mount,data-buildbarn.mount} \
    /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemd-analyze verify \
    /etc/systemd/system/z8-dmzoned.service /etc/systemd/system/z8-zpool.service \
    /etc/systemd/system/data.mount /etc/systemd/system/data-buildbarn.mount
sudo systemctl start data-buildbarn.mount
findmnt -M /data -o SOURCE,TARGET,FSTYPE
findmnt -M /data/buildbarn -o SOURCE,TARGET,FSTYPE
sudo zpool status -P z8data
sudo journalctl -b -o short-monotonic -u z8-dmzoned -u z8-zpool \
    -u data.mount -u data-buildbarn.mount --no-pager
```

正常启动时先看到七个 mapper，然后导入 GUID，最后依次挂载 `/data` 和 `/data/buildbarn`。第二个挂载源应为 `z8data/data/buildbarn`。

如需把 **P4800X 的设备消失**也直接连到 systemd，在完成上面试启后为 p8 加设备依赖。`systemd-escape` 处理实际 NVMe 序列号中的连字符。只绑定这张共享卡，七块 HDD 继续由映射脚本按 RAIDZ1 容错处理。

```bash
# 此处 special 仍是实际 P4800X p8 的 by-id。
device_unit=$(systemd-escape --path --suffix=device "$special")
systemctl is-active "$device_unit"
sudo install -d "/etc/systemd/system/$device_unit.d" \
    /etc/systemd/system/z8-dmzoned.service.d
printf '[Unit]\nJobTimeoutSec=90s\n' \
    | sudo tee "/etc/systemd/system/$device_unit.d/90-z8-timeout.conf"
printf '[Unit]\nBindsTo=%s\nAfter=%s\n' "$device_unit" "$device_unit" \
    | sudo tee /etc/systemd/system/z8-dmzoned.service.d/20-optane-device.conf
sudo systemctl daemon-reload
```

若 `is-active` 未显示 `active`，先核该 by-id 是否在 udev 的设备属性及 systemd 单元列表，确认后再装 drop-in。突发整卡离线时，这条绑定会发起停服务和卸载，底层 ZFS 已因 I/O 故障挂起时仍可能需要按故障恢复流程处理。

本池用 `cachefile=none`，两个 dataset 用 `mountpoint=legacy`，只由上述单元管理。专用主机且**没有其他 ZFS 池**时，确认系统实际有 stock import 服务，然后 `sudo systemctl mask zfs-import-cache.service zfs-import-scan.service`，避免启动并行扫描。若以后加别的池，需要按其引导策略保留 stock 服务，并安排显式只导入这些池。不要再为这两个挂载点写 `/etc/fstab`。不要对这套 Compose 配置设置 Docker 自动重启策略；由 systemd 持有它。

`cachefile=none` 覆盖按缓存导入的路径。OpenZFS 2.4.1 自带的 `zfs-import-scan.service` 在默认缓存文件缺失或为空时可以全盘扫描，因此单池部署同时 mask 两个 stock 服务。第一次冷启后用 `systemctl is-enabled zfs-import-cache.service zfs-import-scan.service` 核两条均显示 `masked`。启动专用链并查 `sudo zpool get cachefile z8data`，应为 `none`。用 `journalctl -b -o short-monotonic -u z8-dmzoned -u z8-zpool -u data.mount -u data-buildbarn.mount` 核日志顺序。 [缓存导入单元](https://github.com/openzfs/zfs/blob/zfs-2.4.1/etc/systemd/system/zfs-import-cache.service.in) · [扫描导入单元](https://github.com/openzfs/zfs/blob/zfs-2.4.1/etc/systemd/system/zfs-import-scan.service.in)

链路为 `z8-dmzoned.service → z8-zpool.service → data.mount → data-buildbarn.mount → z8-buildbarn.service`。每级以 `After=` 和 `BindsTo=` 串联。dm-zoned 等候物理盘最长默认 90 秒。zpool 只按 GUID 搜索已验证的 mapper 与 p8，`-N` 先导入，再由两个 `.mount` 依次挂载。应用启动前检查准确的 dataset 与 XFS 元数据目录。`DefaultDependencies=no` 避免晚挂载被拉回 `local-fs.target` 之前，挂载仍与 `umount.target` 明确排序。 [systemd 依赖语义](https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html) · [zpool import](https://openzfs.github.io/openzfs-docs/man/master/8/zpool-import.8.html)

## 5. I4 验证实际写入、scrub 与缺盘

先在空的冷 CAS 数据集跑顺序覆盖，Buildbarn、scrub 和手工 TRIM 暂停。脚本先写满一个 512 GiB 高熵文件，再连续覆写同一文件三遍。测试保持 `autotrim=on`，每分钟记录七组 cache 区数、ZFS 叶设备吞吐和 TXG 历史。每遍包含 fio 的最终 fsync 和池 `zpool sync`。 [fio I/O 范围和写入量](https://fio.readthedocs.io/en/latest/fio_doc.html#i-o-size) · [OpenZFS TXG 统计字段](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/zfs/spa_stats.c#L193)

```bash
sudo apt install fio sysstat
sudo systemctl start data-buildbarn.mount
logs=/path/to/external-log-disk
sudo bash storage/cas-aging.sh sequential "$logs"
sudo zpool scrub -w z8data
sudo zpool status -vP z8data
```

脚本用 **150 MB/s（十进制）和已完成 TXG 的 `stime` ≤60 秒**判定，最后两遍各自最多 3665 秒。输出 `PASS` 或 `FAIL`；记录不全也会失败。用分钟级 fio 带宽和 `cache` 水位确认确实进入回收期，并记录长停顿和 p99。若三遍结束仍未观察到忙时回收，延长同一文件的覆盖并保留采样，或用 I5 的真实轮转补测。TXG 的 `stime` 只统计实际同步完成的时长，卡住不完成的 TXG 还需看分钟日志和 `zpool sync` 是否返回。150/60 是本站起始门槛，I5 再用实测上传量、尾延迟和并发冷读验证。512 GiB 四遍在 150 MB/s 约 4.1 小时。scrub 无新增错误后删除本轮唯一的 `/data/buildbarn/i4-cas-aging.bin`，再做缺盘演练。

### 低峰 TRIM 与回退

保持 `autotrim=on`。只有冷库使用一段时间后空闲 cache 水位长期无法恢复、且日志支持旧块失效传播不足时，才在池健康、无 scrub/resilver、构建空闲时手动执行 `zpool trim -w -r 32M z8data /dev/mapper/hc620-{0..6}`。设备路径以 `zpool status -P` 为准，执行中看 `zpool status -t z8data`。按叶设备限速 32 MiB/s，全盘操作可能持续数日。本机不启用每月全量 TRIM。 [OpenZFS 手工 TRIM](https://openzfs.github.io/openzfs-docs/man/v2.4/8/zpool-trim.8.html)

顺序覆盖未过线时，先用分钟日志区分 CPU 压缩、忙时回收和队列等待。若 HDD 路径仍达不到要求，CAS 回退到 P4618 的独立 XFS 目录，保留 ZFS 池供后续恢复。停用 `z8-buildbarn-worker.service` 和 `z8-buildbarn.service`，按 [Buildbarn 全 XFS 回退](../buildbarn/README.md#全-xfs-回退) 用新状态恢复同一农场入口。七个 mapper 已被 RAIDZ1 占用，故障回退直接用独立的 XFS 目录。

### 同步写与 ZIL 验证

等 scrub 完成、池空闲后单独测。先在另一个终端执行 `sudo zpool iostat -vlyP z8data 1`，按路径查看 p8 的写 IOPS、带宽和延迟。以下 fio 每写 128 KiB 就发一次 `fdatasync`，用来观察客户端实际等待的同步延迟。保持 `direct=0`，以覆盖 OpenZFS 2.4.1 的缓冲同步写路径。

```bash
test "$(findmnt -n -M /data/buildbarn -o SOURCE)" = z8data/data/buildbarn &&
sudo fio --name=cas-sync --filename=/data/buildbarn/zil-burnin.bin \
    --rw=write --bs=128k --ioengine=psync --direct=0 --fdatasync=1 \
    --size=4G --time_based=1 --runtime=60 --fallocate=none --refill_buffers=1 \
    --percentile_list=50:95:99:99.9 --group_reporting
```

前后分别用 `sudo awk '/^zil_commit_count[[:space:]]/ || /^zil_itx_(copied|needcopy)_bytes[[:space:]]/' /proc/spl/kstat/zfs/zil` 保存计数。该文件为系统级计数，应在其他池安静时采样。预期提交计数增加、p8 在同步写时有活动，RAIDZ1 仍会写入最终数据块。记录 fio 的同步延迟 p95/p99 和 p8 的 I/O。这两项是运行信号，p8 的 I/O 还包含元数据。测试完成后删除 `zil-burnin.bin`。 [OpenZFS 2.4.1 同步写路径](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/zfs/zil.c#L2066) · [zpool iostat](https://openzfs.github.io/openzfs-docs/man/v2.4/8/zpool-iostat.8.html)

Buildbarn 的冷 CAS 使用 `disk.libsonnet` 的 `minimumEpochInterval: '300s'`。这是持久化检查点对块文件调用 `fsync` 的最短间隔，活跃上传时可能观察到周期性同步。I5 用实际 Buck2 上传另测吞吐和尾延迟，测试窗口跨过至少一个活跃的持久化周期。 [Buildbarn 的持久化配置定义](https://github.com/buildbarn/bb-storage/blob/main/pkg/proto/configuration/blobstore/blobstore.proto)

### 缺盘、停机、恢复

- 单个 HC620 缺席时等待结束，尝试启动剩余六个 mapper，只有 p8 在且 RAIDZ1 可读时才会导入。`zpool status -P` 检查 DEGRADED 并按故障盘处理。P4800X 或任一计划分区缺席，映射阶段失败，两个挂载点和 Buildbarn 均不启动，根盘和 SSH 可用。该链约束启动顺序；设备运行中 I/O 报错时，查 ZFS 状态并停服务，文件系统仍挂着时 systemd 不会仅凭 I/O 错误推断卸载。
- 正常停机或换盘前，从一条命令发起反向事务，先停应用再卸载、导出和拆 mapper。`umount` 或 `zpool export` 被占用时先查使用者，存储脚本会在池仍导入时拒绝拆映射。

```bash
sudo systemctl stop data-buildbarn.mount data.mount z8-zpool.service z8-dmzoned.service
sudo journalctl -b -u z8-dmzoned -u z8-zpool -u data.mount \
    -u data-buildbarn.mount -u z8-buildbarn --no-pager
```

- 冷启验证依次做全设备、一盘断电缺席、全恢复、P4800X 断电缺席、再全恢复。每次先关机再动线。单盘演练完成后先等恢复盘完成 resilver，再演练 P4800X。检查 ZFS、服务日志与系统盘裸路径均符合预期。设备后来才出现，先停止本链、复核设备，再启动 `data-buildbarn.mount`。I5 已上线后可用 `sudo systemctl start z8-buildbarn.service` 同时恢复应用。如果前次只建成少数 mapper，脚本会核对并复用已正确创建的映射。P4800X 丢失后的常规恢复路线是从原数据/构建重建 CAS。保留项目、构建配置、GUID、分区表和映射表的独立副本。

临时缺盘回来时，原盘与原 P4800X 分区保持原配对。启动后用 `sudo zpool status -gP z8data` 观察旧成员、mapper、resilver 和校验计数。如果映射已恢复但 ZFS 仍标记 OFFLINE，先确认旧 vdev 标识，再对对应成员用 `sudo zpool online z8data <旧成员标识>`。仍是 UNAVAIL 时保留日志，检查 `dmsetup table` 与 `zdb -l /dev/mapper/hc620-N`，先核已有标签与池 GUID，避免重新格式化返回盘。

永久换盘先用 `zpool status -gP` 抄下失效数据 vdev 的 GUID。只对新的 HC620 与原编号的 cache 分区重建同名 mapper，再用 `zpool replace z8data <旧vdev-GUID> /dev/mapper/hc620-N` 并等待 resilver。执行前须确认另外六个成员和 p8 健康，更新 `/etc/z8-storage/hybrid.tsv` 中该 HDD 的 by-id。原 cache 分区有旧 dm-zoned 元数据时按对应工具版本清理或明确指定覆盖，只处理这一组。若 P4800X 整卡不可恢复，重建池前也清除 P4618 上同一实例的冷 CS 索引、持久状态、热 CS、CMS、AC，或使用一个全新的状态目录，避免新块文件配到旧索引。

## 6. I5 交给 Buildbarn

确认第 5 节通过、七盘已接回、池 ONLINE。I4 的两路 kmem 应已上线，worker 启动依赖 `z8-pmem-kmem.service`。I4 重启后先执行 `systemctl is-active z8-pmem-kmem.service`，结果应为 `active`。以下从 `z8-kit` 根执行，`/srv/buildbarn/tiered` 在 P4618 XFS 上。

```bash
sudo apt install docker.io docker-compose-v2 jq
sudo systemctl enable --now docker.service
sudo docker compose version
sudo install -d -m 0755 /opt/z8-kit /srv/buildbarn/tiered
sudo install -m 0755 buildbarn/z8-buildbarn-check /usr/local/sbin/
sudo cp -a buildbarn /opt/z8-kit/
sudo install -m 0644 storage/systemd/{z8-buildbarn.service,z8-buildbarn-worker.service} \
    /etc/systemd/system/
sudo mkdir -p /srv/buildbarn/tiered/{cs,cs-hot,cms,ac}/persistent_state
sudo systemctl daemon-reload
sudo systemd-analyze verify /etc/systemd/system/z8-buildbarn{,-worker}.service
findmnt -M /data/buildbarn -o SOURCE,TARGET,FSTYPE
findmnt -T /srv/buildbarn/tiered -o SOURCE,TARGET,FSTYPE
sudo docker compose --project-directory /opt/z8-kit/buildbarn \
    -p z8-tiered -f /opt/z8-kit/buildbarn/compose.tiered.yaml config --quiet
```

固定的 `bb-storage` 镜像的 OCI 配置是 `User=0`，默认 rootful Docker 无 userns-remap 时，首次创建的 root 目录即可使用。用 `docker image inspect <Compose 镜像引用> --format '{{.Config.User}}'` 复核。改镜像用户或启用 userns-remap 时，用实际映射 UID 初始化冷、热目录，随后用该容器做 CAS/AC 写读检查。 [Buildbarn 部署](../buildbarn/README.md)

首次启用存储前，I4 压测文件须已移除。`z8-buildbarn-check` 读取空冷库数据集的字节级 `available`，按 72% 向下取整到 TiB，预计约 54 TiB，同时按每 TiB 配 16 GiB 的冷索引，预计 864 GiB。两项写入 `/opt/z8-kit/buildbarn/cold-layout.json`，与农场配置一并备份。后续启动使用已记录的容量并核对现有块文件和索引。已初始化旧索引时，按 [冷 CS 几何与容量](../buildbarn/README.md#冷-cs-几何与容量) 的旧库处理流程更新。

先完成 [CPU 分核与 runner 归属](../host/CPU-PLACEMENT.md#生成并安装)，再启用下面两个服务。

```bash
sudo systemctl enable --now z8-buildbarn.service
sudo cat /opt/z8-kit/buildbarn/cold-layout.json
sudo systemctl enable --now z8-buildbarn-worker.service
ss -ltn 'sport = :8980'
```

正式上线后正常冷启一次，观察 `journalctl -b -o short-monotonic -u z8-dmzoned -u z8-zpool -u data.mount -u data-buildbarn.mount -u z8-buildbarn --no-pager`。存储服务启动后启动 Linux worker，再做真实 Buck2 远程执行、冷读和热读。
