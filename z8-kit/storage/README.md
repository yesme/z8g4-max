# HC620 SATA 与 P4800X RAIDZ1 部署

SATA0–6 的七块 HC620 各配一个 P4800X **96 GiB** 分区，组成七个 dm-zoned target，再做 RAIDZ1。p8 固定 **192 GiB**，作为唯一 special vdev，承载元数据、小块和 ZIL。p9 用余下约 **533 GiB** 做 XFS，放 Buildbarn 冷索引和持久状态。池 `z8data` 的根下平铺 `buildbarn`、`other`、`reserve`。七块 HC620 中掉一块可降级，P4800X 是冷库和全池的共同依赖。 [dm-zoned 布局](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-zoned.html) · [OpenZFS 2.4 特殊分配类](https://openzfs.github.io/openzfs-docs/man/v2.4/7/zpoolconcepts.7.html#special-allocation-class)

## 1. 列出实体设备

从正式系统 I4 开始。关机断电接回 SATA0–6 与 P4800X，启动后用 T4 保存的 SMART、型号、序列号和 by-id 逐项对照。P4618 已在 I1 用作 XFS 根。以下建分区、dmzadm format 与建池会清除目标内容。重装或接回已建过的池时，复用原 GPT、映射表和 GUID，从第 4 节重新安装单元。

```bash
uname -r
sudo apt update
sudo install -m 0644 host/zfs-arc.conf.example /etc/modprobe.d/z8-zfs-arc.conf
sudo apt install dm-zoned-tools zfsutils-linux gdisk parted nvme-cli smartmontools fio sysstat xfsprogs
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

首装在安装 `zfsutils-linux` 前就放入配置。ARC 下限 2 GiB、上限 8 GiB。按 8 GiB ARC 上限预算，约 184 GiB 标称 DDR4 由推理、编译、系统和其他服务共享。llama.cpp 的实际驻留和锁页量从 T5 开始记录，正式模型以 I6 数据为准。runner 的 512 GiB 上限跨 DDR4 和 kmem 计费，实际混合负载以两层内存和 PSI 观测为准。kmem 以 movable 慢层上线，预算中仍按 DDR4 给 ARC 留空间。OpenZFS 2.4.1 的 `zfs_arc_shrinker_limit=0` 保持默认，这会取消 shrinker 的单次页数限制，实际回收仍受可驱逐内容、当前压力与目标限制。dirty data 上限保持自动，`zfs_txg_timeout` 保持 5 秒。I7 验固定配置，发生持续内存压力或冷读延迟明显异常时再按 ARC 和 I/O 统计定位。 [OpenZFS 2.4.1 ARC shrinker](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/os/linux/zfs/arc_os.c#L58) · [OpenZFS 2.4 模块参数](https://openzfs.github.io/openzfs-docs/man/v2.4/4/zfs.4.html)

```bash
sudo modprobe zfs
cat /sys/module/zfs/parameters/zfs_arc_{min,max}  # 2147483648, 8589934592
```

若 ZFS 之前已加载且显示旧值，先用 `lsinitrd "/boot/initrd.img-$(uname -r)"` 查启动镜像是否含 `zfs.ko`。镜像含该模块时按 I1.4 用 Dracut 重建，再重启一次。重启后复核两个参数再建池。

## 2. 建九分区与 mapper

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

### 新建 GPT 九分区

仅用于已确认可清空的 P4800X 首装。先用整盘 by-id 核对型号、序列号和容量，确认所有分区均未挂载，且未被 md、device-mapper 或已导入的 ZFS 池占用。P4618 的两个系统盘端点按 I1 留下的序列号区分。

```bash
P4800X=/dev/disk/by-id/nvme-REPLACE_P4800X
lsblk -o NAME,MODEL,SERIAL,SIZE,TYPE,FSTYPE,MOUNTPOINTS "$P4800X"
sudo sgdisk -p "$P4800X"
```

核对完再执行下面这一段。先清掉旧 GPT/MBR，再一次写入新布局。p1–p7 各 96 GiB，p8 为 192 GiB，p9 用 GPT 剩余空间。如已按旧布局建池，先导出需保留的数据并保存配置，再按重建处理。 [Ubuntu 26.04 sgdisk](https://manpages.ubuntu.com/manpages/resolute/man8/sgdisk.8.html)

```bash
(
    set -e
    [[ -b "$P4800X" && $(lsblk -dnro TYPE "$P4800X") == disk ]]
    # 清表前核对 p1–p8 固定大小，以及至少 500 GiB 的 p9 和 2 MiB 的对齐余量。
    (( $(sudo blockdev --getsize64 "$P4800X") >= (7 * 96 + 192 + 500) * 1024**3 + 2 * 1024**2 ))
    logical_bytes=$(sudo blockdev --getss "$P4800X")
    case "$logical_bytes" in
        512|4096) align_sectors=$((1048576 / logical_bytes)) ;;
        *) printf 'Unexpected LBA size: %s\n' "$logical_bytes" >&2; exit 1 ;;
    esac
    gpt_args=(--clear --set-alignment="$align_sectors")
    for i in {1..7}; do
        gpt_args+=(--new="$i:0:+96G" --change-name="$i:dmz-sata$((i-1))")
    done
    gpt_args+=(--new=8:0:+192G --change-name=8:z8-special --new=9:0:0 --change-name=9:z8-cold-index)
    sudo sgdisk --zap-all "$P4800X"
    sudo sgdisk "${gpt_args[@]}" "$P4800X"
    sudo sgdisk --verify "$P4800X"
    sudo partprobe "$P4800X"
    sudo udevadm settle
    sudo sgdisk --print "$P4800X"
    lsblk -b -o NAME,START,SIZE,PARTLABEL,FSTYPE,MOUNTPOINTS "$P4800X"
)
```

检查 p1–p7 各为 103,079,215,104 B、p8 为 206,158,430,208 B、p9 约 533 GiB。旧分区表清除后，盘面上的旧文件系统或池签名仍可能被识别。如果新分区显示旧 `FSTYPE`，先用 `sudo wipefs /dev/disk/by-id/实际名称-partN` 确认，在该分区确实可清空时用 `sudo wipefs --all /dev/disk/by-id/实际名称-partN` 清理签名，再做 dm-zoned 初始化和建池。 [Ubuntu 26.04 wipefs](https://manpages.ubuntu.com/manpages/resolute/man8/wipefs.8.html)

### HC620 盘头随机写区在混合方案里的用途

HC620 14 TB 的 HM-SMR 盘面有两种区。WD SATA 规范给出每区 256 MiB，盘头连续 **524 个 `CONVENTIONAL` 区，共 131 GiB**，可随机读写。其后是 **51,632 个 `SEQ_WRITE_REQUIRED` 区**，每次写入必须从**各区自己的写指针**开始。区内已写位置仍可随机读取。 [WD HC620 SATA 规范，第 23–24 页及 §10.20.5](https://documents.westerndigital.com/content/dam/doc-library/en_us/assets/public/western-digital/product/data-center-drives/ultrastar-dc-hc600-series/product-manual-ultrastar-dc-hc620-sata-spec.pdf#page=23)

**加 P4800X 后，HC620 盘头的随机写能力退出前台缓冲。** 新 chunk 首次写入、以及顺序区需要缓冲的覆写，都从 P4800X 的 `cache` 空闲链表分配。Optane 无空闲区时，前台等后台回收。每个 96 GiB 分区名义有 **384 个 256 MiB 区**。按厂家区数，两份元数据各跨两个区，预计 **380 个 cache 区**，以 `dmsetup status` 核对。16 个预留顺序区另在 HDD 上。 [dmzadm 2.2.2 映射和位图计算](https://github.com/westerndigitalcorporation/dm-zoned-tools/blob/v2.2.2/src/dmz_lib.c#L282-L340) · [Linux 7.0 cache 区数](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-metadata.c#L2880-L2920)如果用 HC620 单盘运行 dm-zoned，前台随机写与元数据才会直接使用盘头普通区。 [Linux 7.0 首次写入分配](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-metadata.c#L1918) · [覆写缓冲分配](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-metadata.c#L2028)

**盘头区仍在 mapper 内。** 第 0 区保存 HC620 的成员超级块，剩余健康普通区计入 mapper 的数据容量。回收 P4800X 上有有效数据的区时，内核优先找顺序目的区。顺序目的区完全分配不到时，才尝试用盘头普通区承载数据，之后已映射到这些区的数据可直接在 HDD 上读写。只要顺序区长期有空位，盘头普通区可以长期基本闲着。实机用 `sudo dmsetup status hc620-0` 看 `random` 的空闲数/总数，全健康时预期初建后接近 `523/523 random`。七块 HDD 都交给各自 mapper 管理。 [Linux 7.0 盘头区分类](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-metadata.c#L1296) · [回收目标选择](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-reclaim.c#L262) · [状态输出](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-target.c#L1008)

### 16 个预留顺序写区何时使用

Linux 7.0 的源码路径如下。

1. **启动时建空闲链表。** Ubuntu 26.04 的 `dmzadm` 默认每块 HDD 预留 16 个，将这个数写入 mapper 的元数据。启动时内核从当前未映射的顺序写区取区，标记 `DMZ_RESERVED` 并放入 `reserved_seq_zones_list`，其余空闲顺序区进入 `unmap_seq_list`。16 是建表目标，也是初始化时从导出容量扣掉的逻辑 chunk 数。每组折合 **4 GiB**，七组折合 **28 GiB 原始容量**。物理区号由启动时的映射状态决定。 [Ubuntu 26.04 dmzadm](https://manpages.ubuntu.com/manpages/resolute/man8/dmzadm.8.html) · [Linux 7.0 链表初始化](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-metadata.c#L1674)
2. **前台按 chunk 映射写。** 此双设备布局下，写一个尚未映射的 chunk 时先领 P4800X 的 cache zone，即使应用发出顺序写也走这条初始分配路径。已映射到 HC620 的 chunk，写入位置恰好等于当前写指针时直接写 HDD，位置不同则写到配对的 Optane buffer。前台申请 cache zone 时未带 `DMZ_ALLOC_RECLAIM`。 [Linux 7.0 首次映射](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-metadata.c#L1918) · [Linux 7.0 前台写分流](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-target.c#L298)
3. **回收从预留链表领区并真正发写。** 回收线程处理含有效数据的 cache/random 数据区时，`dmz_reclaim_rnd_data()` 用 `DMZ_ALLOC_SEQ | DMZ_ALLOC_RECLAIM` 申请搬迁目的地。普通空闲顺序区找不到时，`dmz_alloc_zone()` 摘下预留链表第一个区并减计数。随后 `dmz_reclaim_copy()` 将目的地址设为 HC620，调用 `dm_kcopyd_copy()`，按顺序写入有效数据，必要时补零推进写指针。复制成功后，`dmz_map_zone()` 把该物理区映射为 chunk 的数据区，释放原随机区。它随后能承担读取和符合写指针的前台写入。 [Linux 7.0 预留区回退](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-metadata.c#L2082) · [Linux 7.0 搬迁和重映射](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-reclaim.c#L262) · [Linux 7.0 提交顺序写](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-reclaim.c#L128)
4. **回收已有 HDD 数据区时还要看写指针。** buffer 中的有效块全在原 HDD 区当前写指针处或之后时，可以续写原区并释放 buffer。若有有效块在写指针之前，先把原 HDD 区仍有效的旧块合进随机写 buffer，再解除原 HDD 区的映射。合并后的 buffer 可由后续回收移回 HDD。预留列表为空时，回收的候选选择会优先找带 buffer 的顺序区来处理。标有 `DMZ_RESERVED` 的 HDD 区正常释放后，经 reset 回预留链表。运行中预留列表里的空闲区可以少于 16。 [Linux 7.0 回收候选选择](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-metadata.c#L1892) · [Linux 7.0 回收分支](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-reclaim.c#L341) · [Linux 7.0 释放归队](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-metadata.c#L2141)

**触发回收和领到预留区是两个条件。** 此布局下后台回收在 target 空闲约 10 秒，或忙时 cache 空闲比例降到 30% 及以下时可运行。普通顺序区耗尽是步骤 3 的分配回退条件。普通顺序区始终有空位，或者回收能直接续写原区时，预留区可以一直空着。ZFS 可用空间百分比无法直接推出 mapper 的空闲顺序区数量。 [Linux 7.0 回收触发](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-reclaim.c#L418)

**96 GiB 缓存供同时缓冲的 chunk。** 按约 380 个可用区、cache 从空开始、每区接近写满，忙时触达 30% 空闲对应每盘占约 66.5 GiB。七盘均匀写入且按六份数据折算时约 399 GiB，尚未扣 RAIDZ padding。零散写触及不同 chunk 时，同一个水位可在写入远少于 399 GiB 时触发。持续速度由 HDD、归并和 discard 决定，以 I4 的持续覆盖验收。 [Linux 7.0 回收与水位](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-reclaim.c#L467-L496)

### 首次初始化每组 dm-zoned

`dmzadm --format` 在 **I4 首次建池前，每组只做一次**。这是给「一个 P4800X 分区 + 一整块 HC620」建立 dm-zoned 自己的盘上布局。工具重置 HDD 顺序区的写指针，在 P4800X 分区里写两套映射表、有效块位图和超级块，并在 HC620 上写成员超级块。原顺序区的数据会失去有效状态，旧映射也会被覆盖。这是一项破坏性初始化，写入范围限于命令传入的那一整块 HDD 和那一个 SSD 分区。它使用 zone reset 和元数据写入，无需全盘覆零，P4800X 的 GPT、其他分区和 LBA 格式都在其目标之外。 [Ubuntu 26.04 dmzadm 手册](https://manpages.ubuntu.com/manpages/resolute/man8/dmzadm.8.html) · [WD 工具源码](https://github.com/westerndigitalcorporation/dm-zoned-tools/blob/master/src/dmz_format.c#L277)

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

核完身份后在同一终端执行。命令前先核第一项确为 96 GiB 分区，第二项确为 host-managed 整盘。`--label` 给每组固定名称，避免同一张 P4800X 的分区用相同序列号生成重名 mapper。保留默认预留和回收参数。

```bash
if [[ $(lsblk -bdnro TYPE,SIZE -- "$cache_device") == 'part 103079215104' &&
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

采用 OpenZFS 的自动预留。192 GiB 的 p8 扣除 vdev 标签和保留空间后，按默认目标 200 个 metaslab 计算，预计 `metaslab_shift=30`，约 191 个 1 GiB metaslab。区数超过默认阈值 64，预计其中一个 **1 GiB** metaslab 用作内嵌 ZIL 空间。同步日志也可以使用 special 普通空间。special 在 RAIDZ 池中不能缩小或移除，且 p9 紧随 p8。 [OpenZFS 2.4.1 metaslab 算法](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/zfs/vdev.c#L2951-L3018) · [内嵌日志区选择](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/zfs/vdev.c#L1686-L1718) · [移除 vdev 的限制](https://openzfs.github.io/openzfs-docs/man/v2.4/8/zpool-remove.8.html)

### 建池命令

```bash
maps=(/dev/mapper/hc620-{0..6})
special="${P4800X}-part8"
# 预览须显示七个 mapper 与 p8 special。-f 接受单盘 special 与
# RAIDZ1 数据 vdev 的冗余差异。请先核对所有 by-id 和容量。
(
    set -euo pipefail
    pool_opts=(-f -o ashift=12 -o cachefile=none -o autotrim=on -m none
        -O canmount=off -O compression=zstd-3 -O atime=off
        -O checksum=on -O dedup=off -O copies=1 -O redundant_metadata=all
        -O xattr=sa -O dnodesize=auto -O primarycache=all
        -O sync=standard -O logbias=latency)
    sudo zpool create -n "${pool_opts[@]}" z8data raidz1 "${maps[@]}" special "$special"
    read -r -p '核对预览并确认首次建池，输入 z8data：' confirmation
    [[ "$confirmation" == z8data ]]
    sudo zpool create "${pool_opts[@]}" z8data raidz1 "${maps[@]}" special "$special"

    available=$(sudo zfs list -Hp -o available z8data)
    [[ "$available" =~ ^[1-9][0-9]{0,15}$ ]]
    tib_bytes=$((1024**4))
    cold_tib=$((available * 55 / 100 / tib_bytes))
    (( cold_tib > 0 ))
    sudo zfs create -o mountpoint=legacy -o recordsize=1M -o compression=zle \
        -o special_small_blocks=0 -o refreservation="$((cold_tib * tib_bytes))" z8data/buildbarn
    sudo zfs create -o mountpoint=none -o canmount=off -o readonly=on \
        -o refreservation="$((available / 10))" z8data/reserve
    sudo zfs create -o mountpoint=legacy -o recordsize=1M -o special_small_blocks=24K z8data/other
    sudo zpool list -H -o guid z8data
    sudo zpool status -P z8data
    sudo zpool get autotrim z8data
    sudo zfs get -r compression,recordsize,special_small_blocks,mountpoint,canmount,refreservation,sync,logbias z8data
    sudo zfs get -r checksum,dedup,copies,redundant_metadata,xattr,dnodesize,primarycache,atime z8data
    sudo zdb -l "$special" | grep -E 'metaslab_shift:|asize:'
    sudo zpool export z8data
)
```

把 GUID 记入 `storage.env`，记录当前 `hostid` 和 `/etc/hostid`。p8 用 `zdb -l` 核对 `metaslab_shift=30`，用标签中的 `asize >> metaslab_shift` 估算区数。普通同步写可先由 p8 上的 ZIL 确认，CAS 数据块随后写 RAIDZ1。 [OpenZFS 2.4 数据集属性](https://openzfs.github.io/openzfs-docs/man/v2.4/7/zfsprops.7.html) · [zdb 标签检查](https://openzfs.github.io/openzfs-docs/man/v2.4/8/zdb.8.html)

### 容量分配与余量

空池创建后只读取一次 `available`。冷库 `refreservation` 取 55% 并向下取整到 TiB，预计 41 TiB。空的 `z8data/reserve` 在同一级扣住 10%，预计 7.5 TiB，通过 `refreservation` 调整。两项预留都按数据集记账。RAIDZ 的可用量按 128 KiB 记录换算；实际写入使用对应记录大小的校验与 padding，另有元数据和压缩影响。稀疏块文件开始只占已写入的空间，冷库的未使用份额仍受预留保护。冷库用量可超过预留，`other` 从共享剩余空间分配，约 35% 是规划值。空数据集的预留减少可分配预算，空闲区仍由 ZFS 管理，物理地址可以分散。 [OpenZFS 空间换算](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/zfs/vdev.c#L2078) · [OpenZFS 2.4.1 预留记账](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/zfs/dsl_dataset.c#L4598-L4623)

10% 是容量取舍。Buildbarn 淘汰逻辑块时只回收文件内偏移，下一次覆盖才可能释放旧 ZFS 物理块。ZFS 按 TXG 分配，三个逻辑写入前沿无法界定磁盘上的碎片带宽度。分配器也会取用能容纳当前写入的空洞。dm-zoned 的 16 个预留顺序区可帮助搬迁，持续可回收量还取决于有效位、写指针和 discard。首次实际占用达到 80% 时，用 `zpool list -Hp -o capacity z8data`（按池物理用量）、`zpool iostat -vlyP z8data 1`、七组 `dmsetup status` 和 `/proc/spl/kstat/zfs/z8data/txgs` 看冷库写入和回收。持续回收恶化时优先增大余量预留，若容量已无法重新分配，再规划缩小并重建冷库。 [Buildbarn 逻辑块释放](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/block_device_backed_block_allocator.go#L176-L187) · [OpenZFS 2.4.1 分配器](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/zfs/metaslab.c#L1874-L1956) · [Linux 7.0 搬迁目标选择](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-reclaim.c#L262-L316)

### 数据集用途与小块

| 数据集 | 挂载 | 本地覆盖与用途 |
|---|---|---|
| `z8data` | 无 | 公共属性与继承，`canmount=off` |
| `z8data/buildbarn` | `/data/buildbarn` | `recordsize=1M,compression=zle,special_small_blocks=0`。只存冷块文件，排除在快照计划之外 |
| `z8data/other` | `/data/other` | `recordsize=1M,special_small_blocks=24K`，继承 `zstd-3`。放能重建的归档、数据集、文档和源码快照 |
| `z8data/reserve` | 无 | `mountpoint=none,canmount=off,readonly=on`，只做空间预留 |

`recordsize=1M` 是新建文件的目标记录大小上限，小文件可用小块。修改 `recordsize` 只影响之后新建的文件。对七盘 RAIDZ1、4 KiB 扇区，未压缩的 4、8、16、24、32、128、256、512、1024 KiB 块分别占 8、16、24、32、40、152、304、600、1200 KiB。24 KiB 及以下的数据能放在六个数据扇区内，同时是 RAIDZ padding 和校验开销相对较高的范围。阈值看压缩及加密后的块大小，压得很小的大文件记录也可能去 special。默认达到 special 分配类的 75% 后，新小数据块转普通 vdev，已写数据保持原位置。元数据也要规划增长，用 `zpool list -v z8data` 看占用。 [OpenZFS 2.4.1 recordsize](https://github.com/openzfs/zfs/blob/zfs-2.4.1/man/man7/zfsprops.7#L1560-L1596) · [OpenZFS 2.4.1 RAIDZ 空间计算](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/zfs/vdev_raidz.c#L2305-L2316) · [24 KiB 属性校验](https://github.com/openzfs/zfs/blob/zfs-2.4.1/lib/libzfs/libzfs_dataset.c#L1263-L1277) · [special 分配规则](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/zfs/spa_misc.c#L2146-L2182)

整个池和冷索引都依赖单块 P4800X；可重建的资料和缓存放这个池，唯一副本的备份保存在独立设备。持续随机改写的 VM 镜像、数据库和容器层用 P4618，活跃模型用 PMem。

`autotrim=on` 由后台线程汇集近期释放的范围。七个 mapper 收到 discard 后将相应块标为无效，p8 走 NVMe discard。保持 2.4.1 的默认 32 TXG 批次、32 KiB 最小范围和 128 MiB 最大范围。mapper 的设备粒度和上限另为 4 KiB、256 MiB。对实体 HC620、P4800X 分区与池成员均不要手动运行 `blkdiscard`。 [OpenZFS 2.4.1 TRIM](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/zfs/vdev_trim.c#L65) · [Linux 7.0 dm-zoned discard](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-target.c#L355)

### 冷 CAS 压缩

Buildbarn 固定镜像 `ca3d8b4` 写盘前已经对每个 CAS chunk 做 Zstd 编码。冷库在 ZFS 层用 `compression=zle`，处理 ZFS 记录内部的连续零字节；全零记录由 ZFS 提前识别。压缩只影响盘上分配，Buildbarn 看到的文件偏移和长度保持不变。冷库继承 `primarycache=all`，同一个 1 MiB 记录内的多页读取可复用 ARC，重复 blob 读取由 P4618 的 512 GiB 热层承担。 [Buildbarn 磁盘编码](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/coder/chunk_coder.go#L13) · [OpenZFS 全零检查](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/zfs/zio.c#L1973-L1980) · [ZLE 编码](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/zfs/zle.c#L28)

## 4. I4 安装存储依赖链

从 `z8-kit` 根执行。将 `hybrid.tsv` 与 `storage.env` 放在当前目录，填入 p8 by-id 和建池取得的 GUID。**仅首装**且确认 p9 可清空后运行这一段。按 p8 by-id 推出同卡 p9，再核对分区标签。

```bash
(
    set -euo pipefail
    source ./storage.env
    [[ "$Z8_SPECIAL" == /dev/disk/by-id/nvme-*-part8 ]]
    index_device="${Z8_SPECIAL%-part8}-part9"
    [[ -b "$index_device" && "$index_device" -ef /dev/disk/by-partlabel/z8-cold-index ]]
    lsblk -b -o NAME,SIZE,PARTLABEL,FSTYPE,MOUNTPOINTS "$index_device"
    sudo mkfs.xfs -m reflink=0 "$index_device"
)
```

**安装和重装都从这里继续。** 重装保留已有 p9 文件系统和池，使用原来的 `hybrid.tsv` 与 `storage.env`。本机只管理这一个 ZFS 池，下方在首次启动专用导入链前屏蔽已安装的系统默认导入服务。

```bash
(
    set -e
    sudo install -d -m 0755 /etc/z8-storage /data /srv/bbindex
    sudo install -m 0600 hybrid.tsv storage.env /etc/z8-storage/
    sudo install -m 0755 storage/z8-storage /usr/local/sbin/
    sudo install -m 0644 storage/systemd/{z8-dmzoned.service,z8-zpool.service,data-buildbarn.mount,data-other.mount,srv-bbindex.mount} \
        /etc/systemd/system/
    for unit in zfs-import-cache.service zfs-import-scan.service; do
        if systemctl cat "$unit" >/dev/null 2>&1; then
            sudo systemctl mask "$unit"
        fi
    done
    sudo systemctl daemon-reload
    sudo systemd-analyze verify /etc/systemd/system/{z8-dmzoned.service,z8-zpool.service,data-buildbarn.mount,data-other.mount,srv-bbindex.mount}
    sudo systemctl enable --now data-buildbarn.mount data-other.mount srv-bbindex.mount
)
for point in /data/buildbarn /data/other /srv/bbindex; do
    findmnt -M "$point" -o SOURCE,TARGET,FSTYPE
done
sudo zpool status -P z8data
sudo journalctl -b -o short-monotonic -u z8-dmzoned -u z8-zpool \
    -u data-buildbarn.mount -u data-other.mount -u srv-bbindex.mount --no-pager
```

三个挂载单元由 `multi-user.target` 弱依赖拉起。两个 ZFS 挂载通过 `BindsTo=` 和 `After=` 等导入完成；手动启动池时也会尝试挂这两个数据集。三个挂载均设 `DefaultDependencies=no`，`multi-user.target` 不会为这些挂载自动添加等待关系。I5 的 tiered Buildbarn 服务另有显式依赖，会等冷数据集和 p9。

要给 `jackywang` 建普通数据目录，先核实挂载源，再在数据集内建目录。

```bash
if [[ $(findmnt -n -M /data/other -o SOURCE,FSTYPE) == 'z8data/other zfs' ]]; then
    sudo install -d -o jackywang -g "$(id -gn jackywang)" -m 0750 /data/other/jackywang
fi
```

如需把 **P4800X 的设备消失**也直接连到 systemd，在完成上面试启后为 p8 加设备依赖。只绑定这张共享卡，七块 HDD 继续由映射脚本按 RAIDZ1 容错处理。

```bash
(
    set -euo pipefail
    source ./storage.env
    [[ "$Z8_SPECIAL" == /dev/disk/by-id/nvme-*-part8 ]]
    device_unit=$(systemd-escape --path --suffix=device "$Z8_SPECIAL")
    systemctl is-active "$device_unit"
    sudo install -d "/etc/systemd/system/$device_unit.d" \
        /etc/systemd/system/z8-dmzoned.service.d
    printf '[Unit]\nJobTimeoutSec=90s\n' \
        | sudo tee "/etc/systemd/system/$device_unit.d/90-z8-timeout.conf"
    printf '[Unit]\nBindsTo=%s\nAfter=%s\n' "$device_unit" "$device_unit" \
        | sudo tee /etc/systemd/system/z8-dmzoned.service.d/20-optane-device.conf
    sudo systemctl daemon-reload
)
```

`is-active` 应显示 `active`。否则先核 by-id 是否在 udev 的设备属性及 systemd 单元列表，再装 drop-in。整卡突发离线时，这条绑定会发起停服务和卸载。底层 ZFS 已因 I/O 故障挂起时，按故障恢复流程处理。

本池用 `cachefile=none` 和 `zpool import -N`，两个 ZFS 数据集用 `mountpoint=legacy`。第一次冷启用 `systemctl is-enabled zfs-import-cache.service zfs-import-scan.service` 确认系统已安装的默认导入服务均为 `masked`，用 `sudo zpool get cachefile z8data` 核对 `none`。这三个挂载点都由 systemd 单元管理。由 systemd 持有 Compose 服务。 [缓存导入单元](https://github.com/openzfs/zfs/blob/zfs-2.4.1/etc/systemd/system/zfs-import-cache.service.in) · [扫描导入单元](https://github.com/openzfs/zfs/blob/zfs-2.4.1/etc/systemd/system/zfs-import-scan.service.in) · [systemd 依赖语义](https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html)

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

本节的回退命令在完成 I5 的软件和分核准备后使用。顺序覆盖未过线时，先用分钟日志区分 CPU 压缩、忙时回收和队列等待。若 HDD 路径仍达不到要求，CAS 回退到 P4618 的独立 XFS 目录，保留 ZFS 池供后续恢复。停用 `z8-buildbarn-worker.service` 和 `z8-buildbarn.service`，按 [Buildbarn 全 XFS 回退](../buildbarn/README.md#全-xfs-回退) 用新状态恢复同一农场入口。七个 mapper 已被 RAIDZ1 占用，故障回退直接用独立的 XFS 目录。

### 同步写与 ZIL 验证

等 scrub 完成、池空闲后单独测。先在另一个终端执行 `sudo zpool iostat -vlyP z8data 1`，按路径查看 p8 的写 IOPS、带宽和延迟。以下 fio 每写 128 KiB 就发一次 `fdatasync`，用来观察客户端实际等待的同步延迟。保持 `direct=0`，以覆盖 OpenZFS 2.4.1 的缓冲同步写路径。

```bash
test "$(findmnt -n -M /data/buildbarn -o SOURCE)" = z8data/buildbarn &&
sudo fio --name=cas-sync --filename=/data/buildbarn/zil-burnin.bin \
    --rw=write --bs=128k --ioengine=psync --direct=0 --fdatasync=1 \
    --size=4G --time_based=1 --runtime=60 --fallocate=none --refill_buffers=1 \
    --percentile_list=50:95:99:99.9 --group_reporting
```

前后分别用 `sudo awk '/^zil_commit_count[[:space:]]/ || /^zil_itx_(copied|needcopy)_bytes[[:space:]]/' /proc/spl/kstat/zfs/zil` 保存计数。该文件为系统级计数，应在其他池安静时采样。预期提交计数增加、p8 在同步写时有活动，RAIDZ1 仍会写入最终数据块。记录 fio 的同步延迟 p95/p99 和 p8 的 I/O。这两项是运行信号，p8 的 I/O 还包含元数据。测试完成后删除 `zil-burnin.bin`。 [OpenZFS 2.4.1 同步写路径](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/zfs/zil.c#L2066) · [zpool iostat](https://openzfs.github.io/openzfs-docs/man/v2.4/8/zpool-iostat.8.html)

Buildbarn 的冷 CAS 使用 `disk.libsonnet` 的 `minimumEpochInterval: '300s'`。这是持久化检查点对块文件调用 `fsync` 的最短间隔，活跃上传时可能观察到周期性同步。I5 用实际 Buck2 上传另测吞吐和尾延迟，测试窗口跨过至少一个活跃的持久化周期。 [Buildbarn 的持久化配置定义](https://github.com/buildbarn/bb-storage/blob/main/pkg/proto/configuration/blobstore/blobstore.proto)

### 缺盘、停机、恢复

- 单个 HC620 缺席时等待结束，尝试启动剩余六个 mapper，只有 p8 在且 RAIDZ1 可读时才会导入。`zpool status -P` 检查 DEGRADED 并按故障盘处理。P4800X 整卡、p1–p7 或 p8 缺席时，池和 Buildbarn 均不启动，根盘和 SSH 可用。单独缺 p9 时仍可导入池，Buildbarn 停在 p9 挂载关口。该链约束启动顺序；设备运行中 I/O 报错时，查 ZFS 状态并停服务，文件系统仍挂着时 systemd 不会仅凭 I/O 错误推断卸载。
- 正常停机或换盘前，从一条命令发起反向事务，先停应用再卸载、导出和拆 mapper。`umount` 或 `zpool export` 被占用时先查使用者，存储脚本会在池仍导入时拒绝拆映射。

```bash
sudo systemctl stop srv-bbindex.mount data-buildbarn.mount data-other.mount z8-zpool.service z8-dmzoned.service
sudo journalctl -b -u z8-dmzoned -u z8-zpool -u data-other.mount -u srv-bbindex.mount \
    -u data-buildbarn.mount -u z8-buildbarn --no-pager
```

- 冷启验证依次做全设备、一盘断电缺席、全恢复、P4800X 断电缺席、再全恢复。每次先关机再动线。单盘演练完成后先等恢复盘完成 resilver，再演练 P4800X。每轮先查本次开机的 dm-zoned、池导入和挂载日志，再核 ZFS 与系统盘。P4800X 缺席时，日志必须显示链路尝试启动并在设备关口失败。只看目录未挂载或 SSH 可用无法判定守卫通过。设备后来才出现，先停止本链、复核设备，再运行 `sudo systemctl start data-buildbarn.mount data-other.mount srv-bbindex.mount`。I5 已上线后可用 `sudo systemctl start z8-buildbarn.service` 同时恢复应用。如果前次只建成少数 mapper，脚本会核对并复用已正确创建的映射。P4800X 丢失后的常规恢复路线是从原数据/构建重建 CAS。保留项目、构建配置、GUID、分区表和映射表的独立副本。

临时缺盘回来时，原盘与原 P4800X 分区保持原配对。启动后用 `sudo zpool status -gP z8data` 观察旧成员、mapper、resilver 和校验计数。如果映射已恢复但 ZFS 仍标记 OFFLINE，先确认旧 vdev 标识，再对对应成员用 `sudo zpool online z8data <旧成员标识>`。仍是 UNAVAIL 时保留日志，检查 `dmsetup table` 与 `zdb -l /dev/mapper/hc620-N`，先核已有标签与池 GUID，避免重新格式化返回盘。

永久换盘先用 `zpool status -gP` 抄下失效数据 vdev 的 GUID。只对新的 HC620 与原编号的 cache 分区重建同名 mapper，再用 `zpool replace z8data <旧vdev-GUID> /dev/mapper/hc620-N` 并等待 resilver。执行前须确认另外六个成员和 p8 健康，更新 `/etc/z8-storage/hybrid.tsv` 中该 HDD 的 by-id。原 cache 分区有旧 dm-zoned 元数据时按对应工具版本清理或明确指定覆盖，只处理这一组。若 P4800X 整卡不可恢复，停 tiered 服务，按 I4 新建池和 p9，再执行下方的冷库重建步骤。源数据和构建配置从独立设备恢复。

#### 只有 p9 的冷索引丢失

如果仅丢了 `cold-layout.json`，且冷块文件、索引及持久状态均完好，从独立备份恢复同一套冷库的原记录，然后启动 tiered 服务。**索引或持久状态丢失时，重建整套冷 CS。** 停 tiered worker 和 cache。先确认池仍可读写、`/data/buildbarn` 的挂载源正确。若 p9 的 XFS 已损坏且决定清空，单独卸载 `srv-bbindex.mount`，按 I4 第 4 节用 p8 by-id 核对 p9。旧签名需要覆盖时，仅对校验通过且已卸载的 p9 使用 `mkfs.xfs -f -m reflink=0`。

若正用全 XFS 回退，先按[回退手册](../buildbarn/README.md#全-xfs-回退)停止该 Compose 项目。确认本机使用 I5 的默认状态目录后执行。以下清除冷 CS 与 CMS 缓存，保留其它数据集、热 CS 和 AC。

```bash
(
    set -euo pipefail
    sudo systemctl stop z8-buildbarn-worker.service z8-buildbarn.service
    sudo systemctl start data-buildbarn.mount srv-bbindex.mount
    [[ $(findmnt -n -M /data/buildbarn -o SOURCE,FSTYPE) == 'z8data/buildbarn zfs' ]]
    [[ $(findmnt -n -M /srv/bbindex -o FSTYPE) == xfs ]]
    index_source=$(findmnt -n -M /srv/bbindex -o SOURCE)
    [[ "$index_source" -ef /dev/disk/by-partlabel/z8-cold-index ]]
    [[ $(findmnt -n -T /srv/buildbarn/tiered -o FSTYPE) == xfs ]]
    sudo rm -f -- /data/buildbarn/blocks \
        /srv/bbindex/{key_location_map,cold-layout.json} \
        /srv/buildbarn/tiered/cms/{blocks,key_location_map}
    sudo install -d -m 0755 /srv/bbindex/persistent_state /srv/buildbarn/tiered/cms/persistent_state
    sudo find /srv/bbindex/persistent_state /srv/buildbarn/tiered/cms/persistent_state -mindepth 1 -delete
    sudo systemctl start z8-buildbarn.service z8-buildbarn-worker.service
)
sudo journalctl -b -u z8-buildbarn -u z8-buildbarn-worker --no-pager
```

守卫按原 `refreservation` 和 p9 可用量生成新几何，冷库文件长度不依赖旧块释放的进度。热 CS 的内容以 digest 寻址，可以继续提供直接读取；AC 每次返回结果前会检查引用对象。CMS 一起重建，因为固定镜像的 `SplitBlob` 可以直接返回旧清单，读路径此时未检查清单引用的 chunk 是否还在。mini 和 Mac 也有 CMS 读缓存，重接农场前按[边缘 CMS 恢复](../buildbarn/EDGE.md#权威冷库重建后的边缘-cms)清理。 [Buildbarn 热读与权威后端](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/readcaching/read_caching_blob_access.go#L21-L47) · [AC 完整性检查](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/completenesschecking/completeness_checking_blob_access.go#L219-L227) · [SplitBlob 读取清单](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/grpcservers/content_addressable_storage_server.go#L432-L443)

## 6. I5 交给 Buildbarn

先完成软件与目录准备，再装分核，最后启动服务。主方案要求 I4 持续写和缺盘演练通过、七盘接回且池 ONLINE。两路 kmem 应已上线，先执行 `systemctl is-active z8-pmem-kmem.service`，结果应为 `active`。以下从 `z8-kit` 根执行，`/srv/buildbarn/tiered` 在 P4618 XFS 上。

### I5.1 软件、目录与单元准备

主方案与全 XFS 回退都先执行这个安装块。

```bash
sudo apt install docker.io docker-compose-v2 jq
sudo systemctl enable --now docker.service
sudo docker compose version
sudo install -d -m 0755 /opt/z8-kit /srv/buildbarn/tiered
sudo install -m 0755 buildbarn/z8-buildbarn-check /usr/local/sbin/
sudo cp -a buildbarn /opt/z8-kit/
sudo install -m 0644 storage/systemd/{z8-buildbarn.service,z8-buildbarn-worker.service} \
    /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemd-analyze verify /etc/systemd/system/z8-buildbarn{,-worker}.service
```

**主方案**继续执行下面的 p9 和 tiered 目录准备。采用全 XFS 回退的机器直接去 I5.2，回退的目录由回退手册创建。

```bash
sudo systemctl start srv-bbindex.mount &&
    findmnt -M /srv/bbindex -t xfs -o SOURCE,TARGET,FSTYPE &&
    sudo install -d -m 0755 /srv/bbindex/persistent_state
sudo install -d -m 0755 /srv/buildbarn/tiered/{cs-hot,cms,ac}/persistent_state
findmnt -M /data/buildbarn -o SOURCE,TARGET,FSTYPE
findmnt -T /srv/buildbarn/tiered -o SOURCE,TARGET,FSTYPE
sudo docker compose --project-directory /opt/z8-kit/buildbarn \
    -p z8-tiered -f /opt/z8-kit/buildbarn/compose.tiered.yaml config --quiet
```

固定的 `bb-storage` 镜像的 OCI 配置是 `User=0`，默认 rootful Docker 无 userns-remap 时，首次创建的 root 目录即可使用。用 `docker image inspect <Compose 镜像引用> --format '{{.Config.User}}'` 复核。改镜像用户或启用 userns-remap 时，用实际映射 UID 初始化冷、热目录，随后用该容器做 CAS/AC 写读检查。 [Buildbarn 部署](../buildbarn/README.md)

首次启用存储前，I4 压测文件须已移除。`z8-buildbarn-check` 从 `z8data/buildbarn` 的整 TiB `refreservation` 读冷文件大小。索引按 p9 XFS 首次可用空间向下取整到 GiB，再减 8 GiB。几何记录写到 `/srv/bbindex/cold-layout.json`，连同农场配置备份。后续启动核对预留和已存在的两个文件长度，沿用记录的索引大小。

### I5.2 分核与启动

执行 [CPU 分核与 runner 归属](../host/CPU-PLACEMENT.md#生成并安装) 的两部分。先安装 CPU slice，再验证 Compose 和安装 runner drop-in。完成后回这里启用下面两个服务。走全 XFS 回退时，安装 CPU slice 后直接按 [回退手册](../buildbarn/README.md#全-xfs-回退) 启动，回退的 Compose 命令已包含分核覆盖。

```bash
sudo systemctl enable --now z8-buildbarn.service
sudo cat /srv/bbindex/cold-layout.json
sudo systemctl enable --now z8-buildbarn-worker.service
ss -ltn 'sport = :8980'
```

正式上线后正常冷启一次，观察 `journalctl -b -o short-monotonic -u z8-dmzoned -u z8-zpool -u data-other.mount -u srv-bbindex.mount -u data-buildbarn.mount -u z8-buildbarn --no-pager`。存储服务启动后启动 Linux worker，再做真实 Buck2 远程执行、冷读和热读。
