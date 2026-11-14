# App Direct 与 NUMA 配置

## T3 准备工具

**验机和正式系统都用 Xubuntu 26.04.1 amd64。** 验机用装在独立 USB SSD 上的临时系统，重启后工具和日志还在。普通 Live 也能跑下面的安装命令，重启后需重新装工具。Live 镜像有 `dmsetup` 和 `jq`，缺 `ipmctl`、`ndctl`、`daxctl`、`fio`、`rasdaemon` 和 `stressapptest`。26.04 官方源提供后五个包；`ipmctl` 从 Canonical 的官方归档取三份同版 `.deb`，其余依赖由 26.04 APT 解析。软件源继续使用 26.04（`resolute`）。 [Xubuntu 26.04.1 官方 manifest](https://cdimage.ubuntu.com/xubuntu/releases/26.04/release/xubuntu-26.04.1-desktop-amd64.manifest) · [Ubuntu ipmctl 包索引](https://packages.ubuntu.com/ipmctl) · [Canonical 官方归档](https://archive.ubuntu.com/ubuntu/pool/universe/i/ipmctl/)

```bash
sudo apt update
sudo apt install curl ndctl daxctl fio jq dmsetup xfsprogs rasdaemon stressapptest
mkdir -p "$HOME/z8-ipmctl-packages"
cd "$HOME/z8-ipmctl-packages"
version=03.00.00.0485-1build1
base=https://archive.ubuntu.com/ubuntu/pool/universe/i/ipmctl
packages=(
    "ipmctl_${version}_amd64.deb"
    "libipmctl5_${version}_amd64.deb"
    "libipmctl-common_${version}_all.deb"
)
for package in "${packages[@]}"; do
    curl --fail --location --show-error --output "$package" "$base/$package" || break
done
sha256sum -c <<'EOF'
819e4b6d1deac9dcabdac70c15a84666191109cbe6fe3b8b5d36308358602253  ipmctl_03.00.00.0485-1build1_amd64.deb
2344ac0eae25fbac22f4592ae710619d537a6882208561b00d5929c5d3d0c7bf  libipmctl5_03.00.00.0485-1build1_amd64.deb
fbfe35dbb9ff4578b33850b1d1c561b748eaec3cef152b2c2fe7be4acd1370c1  libipmctl-common_03.00.00.0485-1build1_all.deb
EOF
```

三份校验均为 `OK` 后，在同一终端先模拟。新增依赖应来自 26.04，包括 `libndctl6` 和 `libdaxctl1`。看到模拟通过后再实际装。

```bash
apt-get -s install "${packages[@]/#/./}"
sudo apt install "${packages[@]/#/./}"
ipmctl version
/usr/bin/fio --enghelp | grep -E 'libpmem|dev-dax'
```

已在 Ubuntu 26.04 amd64 用户空间验证 APT 模拟通过，并用 26.04 的运行库成功执行 `ipmctl version`，输出 `03.00.00.0485-1build1`。已查 Ubuntu `7.0.0-43-generic` 的构建配置，包含 `CONFIG_ACPI_NFIT=m`、`CONFIG_LIBNVDIMM=y`、`CONFIG_BLK_DEV_PMEM=m`、`CONFIG_FS_DAX=y` 和 `CONFIG_DEV_DAX_KMEM=m`。26.04 的 `fio 3.41-2` 包含两个 PMDK 引擎。上机从 Z8 原生启动，按下面步骤确认 `show -dimm` 能识别 12 条模块。 [Ubuntu 26.04 ndctl](https://packages.ubuntu.com/en/resolute/ndctl) · [Ubuntu 26.04 fio](https://packages.ubuntu.com/resolute/fio)

## T3 配置 App Direct

顺序是 **F10 确认硬件和临时解冻 → Linux 提交 goal → 重启由 BIOS 应用 → Linux 用 ndctl 切空间**。`goal` 是下一次启动要执行的 PMem 容量分配请求。这里把 PMem 全部配置成 App Direct，后面再决定哪块用于文件卷、哪块交给 kmem。

### 每路容量上限

HP 对 Z8 G4 的 App Direct 混插按每颗 CPU 下的 **DDR4 + PMem DIMM 总容量**核算。HP 列出的基础档是每路 1 TiB，M 档每路 2 TiB。BIOS 先映射 App Direct，Linux 才能将其中的 `devdax` 范围转为 `system-ram`。用作 `fsdax` 和用作 kmem 的容量都计入这次固件映射。Intel Memory Mode 的口径是只计 PMem，因为 DDR4 在该模式下做硬件缓存。 [HP Optane 白皮书，第 5–6 页](https://h10032.www1.hp.com/ctg/Manual/c06527302.pdf#page=5) · [Ubuntu 26.04 daxctl 手册](https://manpages.ubuntu.com/manpages/resolute/man1/daxctl-reconfigure-device.1.html)

| 单路标称配置 | DDR4 | PMem | App Direct 合计 |
|---|---:|---:|---:|
| 本机首装 | 6×16 GiB | 6×128 GiB | 864 GiB |
| DDR4 扩容候选 | 6×32 GiB | 6×128 GiB | 960 GiB，距 1 TiB 还有 64 GiB |
| 512 GiB PMem 满插 | 6×32 GiB | 6×512 GiB | 3,264 GiB，超出 HP 公布的基础档和 M 档 |

8269CY 是 OEM 料号，具体 SKU 上限留待实机读取。阿里云公开了使用 8269CY、整机 384 GiB DDR4 + 1,536 GiB PMem 的实例，对称分摊相当于每路 960 GiB。HP 的 Z8 G4 清单列出了单条 128 GiB 的 App Direct 选项，未列出单条 512 GiB。32 GiB DDR4 扩容候选仍用 ECC RDIMM，沿用六个 DRAM 槽，换条后重跑 T2 和 T3。 [阿里云 ebmre6p 规格](https://www.alibabacloud.com/help/en/ecs/user-guide/elastic-bare-metal-server-overview#:~:text=Ebmre6p%3A%20Persistent%20memory) · [HP Z8 G4 QuickSpecs，第 15、21 页](https://h30434.www3.hp.com/psg/attachments/psg/Business-PC-Workstation-POS/44704/1/Z8%20G4%20Quickspecs%20v67.pdf#page=15)

### 1. 在 F10 查条并临时解冻

DDR4-only 测试通过后断电，把 12 条 PMem 插进空槽。第一次混插 POST 时按 F10。这个流程由 Xubuntu 的 `ipmctl` 提交 App Direct goal，F10 这次做以下两步。

1. 进 `Advanced → NVDIMM Management`，核两路各六条及其固件、当前状态。`NVDIMM Configuration` 保持原值，跳过 `Apply NVDIMM Configuration`。该菜单的 `Volatile Memory` 对应 Intel Memory Mode，`Persistent Memory with BTT` 对应扇区模式。本机需要后续在 Linux 划 `fsdax` 和 `devdax`。
2. 进 `Security → NVDIMM Security Freeze`，把 `Unfreeze NVDIMMs for this number of boot sequences` 暂设为 **`5`**。按 F10 保存退出。这个开关给 `ipmctl` 配置留出五次启动的窗口。二手模块若处于 `Locked`，还需原解锁方式。

[HP F10 NVDIMM 配置](https://h10032.www1.hp.com/ctg/Manual/c06527302.pdf#page=8) · [HP Linux 配置步骤](https://h10032.www1.hp.com/ctg/Manual/c06527302.pdf#page=11)

### 2. 在 Xubuntu 26.04.1 记录现状并提交 goal

从 F9 选已准备好的 Xubuntu 26.04.1 临时 SSD，打开终端。工具还没装时，先在该系统连 AX210 Wi-Fi 并执行 [T3 准备工具](#t3-准备工具)。运行下面的只读盘点，输出同时显示在终端并保存到 `~/z8-burnin/pmem-before.log`。

```bash
mkdir -p "$HOME/z8-burnin"
sudo modprobe acpi_nfit
{
    uname -r
    sudo ipmctl show -units GiB -socket
    sudo ipmctl show -topology
    sudo ipmctl show -dimm
    sudo ipmctl show -dimm -firmware
    sudo ipmctl show -memoryresources
    sudo ipmctl show -region
    sudo ipmctl show -goal
    sudo ndctl list -N
} 2>&1 | tee "$HOME/z8-burnin/pmem-before.log"
```

若 F10 识别 12 条而 `show -dimm` 识别不全，用 `sudo journalctl -k -b -g 'NFIT|nvdimm|pmem|dax'` 查固件表和内核枚举，再核 F10 解冻状态。仍不齐时先记录实际 DIMM 和 ACPI NFIT 错误，处理后在同版临时系统重新检查。

在日志里找 `show -socket` 的两行 `SocketID`。`MappedMemoryLimit` 是固件报告的该 CPU SKU 可映射容量上限，`TotalMappedMemory` 是这次开机已映射的容量。按工具显示直接抄，暂未分配 App Direct 时后者可能偏小。`show -dimm` 应列两路各 6 条可管理的 PMem。`show -region` 列固件已配置的 App Direct 地址范围，空白模块可没有 region。`show -goal` 查有无上次留下的待应用请求，`ndctl list -N` 查有无 Linux 已使用的 namespace。若 `show -socket` 未返回上限，记录实机 BIOS 版本和原输出。 [ipmctl show -socket](https://docs.pmem.io/ipmctl-user-guide/module-discovery/show-socket) · [ipmctl show -goal](https://docs.pmem.io/ipmctl-user-guide/provisioning/show-memory-allocation-goal)

先按 [T3 固件判定](FIRMWARE.md#t3-pmem-100) 处理该批模块；若刷过，冷启后再采一次现状。已有两路正确的 App Direct region 时直接去第 3 步核对。发现旧 namespace 或未处理的 goal 时，先确认旧配置和数据处置。对可初始化的 12 条执行下面的 **`create -goal`**。在终端核预览确实列出两路各 6 条，再输入 `y`。

```bash
sudo ipmctl create -goal MemoryMode=0 PersistentMemoryType=AppDirect
sudo ipmctl show -goal
```

`MemoryMode=0` 表示 PMem 的 0% 用作 Intel Memory Mode，DDR4 仍是主内存。`AppDirect` 请求让每路的六条 PMem 做硬件交错。`show -goal` 要看到 `Status: New`，即请求已提交、等 BIOS 执行。此时在终端运行 `sudo reboot`，从 F9 回同一个临时 SSD。启动期间 BIOS 应用 goal，无需到 F10 再点 Apply。 [ipmctl create -goal](https://docs.pmem.io/ipmctl-user-guide/provisioning/create-memory-allocation-goal) · [HP Linux 配置，第 11 页](https://h10032.www1.hp.com/ctg/Manual/c06527302.pdf#page=11)

### 3. 重启回 Xubuntu，核对生效再切 namespace

```bash
{
    sudo ipmctl show -goal
    sudo ipmctl show -units GiB -socket
    sudo ipmctl show -memoryresources
    sudo ipmctl show -region
    sudo ipmctl start -diagnostic
} 2>&1 | tee "$HOME/z8-burnin/pmem-after.log"
```

成功时同时满足两项。`show -goal` 无待处理请求，`show -region` 有两路状态健康的 App Direct 区域。每路装入标称 768 GiB，HP 给出的模块报告容量约少 2%，region 还受对齐影响。两边容量应相近，并与 `show -memoryresources` 的整机 App Direct 总量相符。若 goal 仍为 `New` 或显示 `Failed`，或只看到一边，先保存日志、检查 F10、DIMM、锁状态和固件，待修复后再切 namespace。把 `pmem-before.log` 和 `pmem-after.log` 一并留存。 [HP Z8 G4 QuickSpecs，第 15 页](https://h30434.www3.hp.com/psg/attachments/psg/Business-PC-Workstation-POS/44704/1/Z8%20G4%20Quickspecs%20v67.pdf#page=15)

```bash
sudo ndctl list -Ruv
sudo ndctl list -N
sudo ndctl list -RMC
```

region 是 BIOS 划出来的一大段空间，namespace 是 Linux 在这段空间里切出的一块。用 `ipmctl show -region` 的 `SocketID` 和 `ndctl` 的映射信息区分两个 socket，抄下各自的 region ID。以下示例用 255 GiB 作为约 256 GiB 的目标，便于满足 6 路交错乘 2 MiB 的 12 MiB 倍数要求。256 GiB 整数在 6 路布局上可能被 ndctl 拒绝。看每个 region 的对齐要求和 `available_size`，以实机返回为准。已有 namespace 时先核用途，切勿重复创建。 [ndctl 参数与对齐](https://docs.pmem.io/ndctl-user-guide/ndctl-man-pages/ndctl-create-namespace)

```bash
# 这两项替换为上面实际看到的 region ID，例如 region0。
R0=regionREPLACE_SOCKET0
R1=regionREPLACE_SOCKET1
sudo ndctl create-namespace -r "$R0" -m fsdax -s 255G --align=2M --name=z8-model0
sudo ndctl create-namespace -r "$R1" -m fsdax -s 255G --align=2M --name=z8-model1
sudo ndctl create-namespace -r "$R0" -m devdax --align=2M --name=z8-tier0
sudo ndctl create-namespace -r "$R1" -m devdax --align=2M --name=z8-tier1
sudo ndctl list -RNXu
```

预期两个 fsdax 块设备（`/dev/pmemX[.Y]`）给模型卷，两个 devdax 字符设备（`/dev/daxX.Y`）先跑 fio，之后才转 kmem。以输出为准记录四个 namespace UUID、容量、所属 socket。全部验证后恢复原 NVDIMM Freeze 策略。正式系统使用相同 UUID 恢复挂载和 kmem，已有 goal、namespace 和文件系统可直接复用。

两路按同样的方式划分，每路 255 GiB 给 fsdax，剩余约 500 GiB 给 devdax，再转 kmem。实际容量按 namespace 和上线后的 NUMA 节点记录。优先验证对称布局。把 CPU1 改成约 500 GiB 本地 fsdax 加约 256 GiB kmem，要在确实需要单路容纳实测模型文件、且本地 DAX 读取显著受益后再考虑。重切前先迁走模型、卸载并备份 namespace 记录。Engram 是静态查表，DSpark 是投机解码组件，KV 随请求变化；容量分别从所选引擎的实际文件与运行时统计获取。

| 物理插槽 | 每路 DDR4 | 每路的 fsdax namespace | 每路的 devdax namespace |
|---|---:|---|---|
| CPU0 | 96 GiB | 255 GiB，作模型卷的第一段条带成员 | 剩余约 500 GiB，上线为 CPU0 附近的慢内存节点 |
| CPU1 | 96 GiB | 255 GiB，作模型卷的第二段条带成员 | 剩余约 500 GiB，上线为 CPU1 附近的慢内存节点 |

两个 `fsdax` 合成一个约 510 GiB 的模型卷。2 MiB 条带按文件系统块地址分到两个 PMem 成员，线程的 `numactl` 策略无法改变已有文件的位置。文件路径对引擎只有一份，跨路读取仍可能走 UPI。两个 `devdax` 各自按固件给的目标节点上线，供 Linux 迁移可回收的页。四个 namespace 的数量和 Linux NUMA 节点的数量分别核对。

### App Direct、fsdax 与 devdax

`App Direct` 是 `ipmctl` 给固件提交的容量用途，重启后得到每路的 region。`fsdax` 与 `devdax` 是 Linux 在 region 内按 namespace 选择的访问方式。一套 App Direct 配置可以同时用两种 namespace。 [Linux NVDIMM namespace 模式](https://nvdimm.docs.kernel.org/index.html) · [daxctl system-ram](https://docs.pmem.io/ndctl-user-guide/daxctl-man-pages/daxctl-reconfigure-device)

| 方式 | 出现在 Linux 的形式 | 在本机的用途 |
|---|---|---|
| `fsdax` | `/dev/pmemN` 块设备。ext4 提供普通文件名、权限和 DAX `mmap` | GGUF、Engram、DSpark 和引擎显式保存的文件型快照。读取映射页直接访问 PMem，文件仍可用普通工具管理 |
| `devdax` | `/dev/daxX.Y` 字符设备。程序需要显式映射和管理偏移 | 上线前可逐路测设备。随后交给 `daxctl` 转 `system-ram`，由 `dax_kmem` 把该范围加进 Linux 的系统内存 |

转为 `system-ram` 后由 Linux 管理可移动页，按慢层测试冷页下沉。两路分别上线，不做条带。`fsdax` 文件仍固定在模型卷的物理地址上，内核慢层对可迁移页的处理与模型文件布局独立。CUDA 已长期 pin 的页留在原驻留内存中，也要从 DDR4 预算扣除。

## 模型卷

各 socket 一个 `fsdax` namespace。T3 先做两个本地 ext4 DAX 挂载，再在测试数据可清除时建立跨 socket 的约 510 GiB `dm-stripe` RAID0 模型卷。Linux v7.0 的 stripe target 有 direct_access。Engram 1/14 分放与绑定线程的组合可用两个本地挂载测试，前提是引擎支持拆文件。 [Linux dm-stripe](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-stripe.c) · [PMem 的 dm-stripe 操作](https://pmem.io/blog/2018/05/using-persistent-memory-devices-with-the-linux-device-mapper/)

2 MiB 条带在两路现有 region 之上，每个 2 MiB chunk 只在一路，连续 chunk 在两路间轮转。主要收益是约 510 GiB 的统一容量和目录。并发扫描可利用两路带宽。单次几十到几百字节的 Engram 查表仍由所在 PMem 服务，跨插槽访问会经过 UPI，所以随机读 p95 要测。两个本地 255 GiB 卷可以分别放约 129 GiB 主体和约 103 GiB Engram，并在引擎支持独立文件路径或分片链接时复用。同一套权重能在两个布局间做 A/B。比较 cold load、实际 Engram 查表 p95、长 prompt TTFT、decode 和加 Buck2 后的变化。条带中断一侧会使整卷不可用，本机用固定 revision 和 SHA256 恢复模型文件。 [dm-stripe 说明](https://pmem.io/blog/2018/05/using-persistent-memory-devices-with-the-linux-device-mapper/#creating-dm-striped-devices) · [2 MiB PMD 映射条件](https://nvdimm.docs.kernel.org/2mib_fs_dax.html)

若先跑两路单独测试，用 `sudo ndctl list -RNv` 记录每个 region 下 fsdax 的 `uuid`、`blockdev` 和 NUMA 归属。以下两条 `mkfs.ext4` 各写一个空的 fsdax namespace。测试结束先卸载两个文件系统，记录结果。若随后改成条带，两个原文件系统将被新布局覆盖，先把要留的文件复制到外部日志盘。

```bash
FS0=/dev/pmemREPLACE_SOCKET0
FS1=/dev/pmemREPLACE_SOCKET1
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS "$FS0" "$FS1"
sudo install -d /srv/pmem-local0 /srv/pmem-local1
sudo mkfs.ext4 -b 4096 -E stride=512 "$FS0"
sudo mkfs.ext4 -b 4096 -E stride=512 "$FS1"
sudo mount -t ext4 -o dax=always,noatime,data=ordered,nodiscard "$FS0" /srv/pmem-local0
sudo mount -t ext4 -o dax=always,noatime,data=ordered,nodiscard "$FS1" /srv/pmem-local1
findmnt -M /srv/pmem-local0
findmnt -M /srv/pmem-local1
```

```bash
# 用 ndctl 返回的 fsdax namespace UUID，按固定 socket 顺序。
sudo apt install jq
sudo bash host/pmem-dax-stripe.sh show "$FS0_UUID" "$FS1_UUID"
sudo bash host/pmem-dax-stripe.sh create "$FS0_UUID" "$FS1_UUID"
# 仅对首次创建的空 mapper 建文件系统。2 MiB chunk / 4 KiB = 512。
sudo mkfs.ext4 -b 4096 -E stride=512,stripe_width=1024 /dev/mapper/z8-pmem-model
sudo install -d /srv/pmem-model
sudo mount -t ext4 -o dax=always,noatime,data=ordered,nodiscard /dev/mapper/z8-pmem-model /srv/pmem-model
```

这里用 `noatime` 免去权重、Engram 热读触发的访问时间更新，保留 ext4 日志、`data=ordered` 和正常的写入同步语义。App Direct DAX 模型卷以读为主，使用 `nodiscard`。在该路径实际创建测试文件，执行 `xfs_io -r -c 'statx -r' /srv/pmem-model/burnin.bin`（也可对 ext4 文件运行）。核 `stx_attributes_mask` 和 `stx_attributes` 的 `STATX_ATTR_DAX` 位 `0x200000` 都为 1。此卷保存模型权重、Engram、DSpark 和支持持久化的 KV checkpoint，模型 revision、SHA-256 和下载清单留在 P4618。 [全机挂载表](MOUNTS.md) · [Linux 文件级 DAX 状态](https://docs.kernel.org/filesystems/dax.html) · [两个引擎的 KV 配置](../inference/README.md)

### 核实 Engram 是否实际使用 2 MiB 映射

fsdax 上的 `mmap` 让 CPU 直接读 PMem，省去同一文件内容在普通 DRAM 页缓存中的副本。2 MiB PMD 映射还可降低页表和 TLB 压力。除了 namespace 与条带对齐，文件 extent 要足够长且对齐，应用的虚拟地址与文件偏移也要匹配。T3 先测已完整写入的 `burnin.bin`；I7 对使用 mmap 的引擎把 `ENGRAM` 换成真实文件。Xolotl 当前 Engram 走 `pread`，用实际文件的 DAX 属性和 Engram 读取时延验证。 [Linux 2 MiB DAX 对齐](https://nvdimm.docs.kernel.org/2mib_fs_dax.html) · [Linux 7.0 ext4 DAX read](https://github.com/torvalds/linux/blob/v7.0/fs/ext4/file.c#L96)

```bash
sudo apt install trace-cmd
ENGRAM=/srv/pmem-model/burnin.bin
findmnt -n -o SOURCE,MAJ:MIN,OPTIONS -T "$ENGRAM"
printf 'inode=0x%x\n' "$(stat -c %i "$ENGRAM")"
filefrag -v "$ENGRAM"
sudo trace-cmd list -e fs_dax
# 窗口内在第二终端启动新进程，访问这份文件的 mmap。
sudo trace-cmd record -o /tmp/z8-pmem-pmd.dat -e fs_dax:dax_pmd_fault_done sleep 30
sudo trace-cmd report -i /tmp/z8-pmem-pmd.dat | grep dax_pmd_fault_done
```

T3 在第二终端可运行下面的只读探针，要求 `burnin.bin` 已写满至少 1 GiB。I7 用引擎本身替换它。

```bash
python3 - /srv/pmem-model/burnin.bin <<'PY'
import mmap
import sys

with open(sys.argv[1], "rb") as file:
    with mmap.mmap(file.fileno(), 1 << 30, access=mmap.ACCESS_READ) as mapped:
        print(sum(mapped[offset] for offset in range(0, len(mapped), 2 << 20)))
PY
```

在报告里按设备号和 inode 过滤。该事件的 `NOPAGE` 表示一次成功的 DAX PMD fault，`FALLBACK` 表示这次退回小页；有首尾或碎片回退时看实际比例。没有事件时查引擎是否真的映射了该文件。生产模型卷先用 ext4。若用空测试卷比较 XFS DAX，可在条带上用 `mkfs.xfs -b size=4096 -d su=2m,sw=2 -m reflink=0`，然后以 `dax=always` 挂载并做相同验证。Linux 7.0 的 XFS 对块设备分区上启用 reflink 加 `dax=always` 有明确限制。 [Linux 7.0 XFS DAX 挂载检查](https://github.com/torvalds/linux/blob/v7.0/fs/xfs/xfs_super.c#L342)

### 交给启动服务

首次测试后卸载并删除 mapper，再让服务接管。复制 `host/pmem-model.env.example` 为 `pmem-model.env`，填写两个 fsdax namespace UUID。

```bash
sudo umount /srv/pmem-model
sudo dmsetup remove z8-pmem-model
sudo install -d -m 0755 /etc/z8-storage
sudo install -m 0600 pmem-model.env /etc/z8-storage/
sudo install -m 0755 host/pmem-dax-stripe.sh /usr/local/sbin/
sudo install -m 0644 host/systemd/z8-pmem-model.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now z8-pmem-model.service
findmnt -M /srv/pmem-model
```

依赖该卷的推理 systemd 服务加 `BindsTo=z8-pmem-model.service` 与 `After=z8-pmem-model.service`，启动脚本查 `findmnt -M /srv/pmem-model` 后再读模型。

若首次启动在 mount 步骤失败，核 kernel 日志和 `blkid /dev/mapper/z8-pmem-model`。确认 mapper 没有挂载、没有在用后，用 `sudo dmsetup remove z8-pmem-model` 清掉旧映射，再重启服务。不要在已有模型数据的卷上重跑 mkfs。

## 剩余 PMem 转 kmem

先完成两块 devdax 的专用 fio 测试。用 `sudo daxctl list` 找到真实的两个 `daxX.Y`。把 `struct page` 等热插拔页描述符放在 PMem 内部，Linux 7.0 需要两个开关。T3 在 GRUB 临时给当前内核的 `linux` 行追加 `memory_hotplug.memmap_on_memory=on`，启动后在每个 DAX 设备上写 `1`，然后才绑定 kmem。Ubuntu `7.0.0-43-generic` 的配置包含 `CONFIG_MHP_MEMMAP_ON_MEMORY=y`。两个设备合计约 1 TiB，按 4 KiB 页和 64 B 页描述符估算约 16 GiB 元数据，实际在线容量和 DDR4 节约量按热插拔粒度、对齐和实机节点统计核算。 [Linux 7.0 全局热插拔参数](https://github.com/torvalds/linux/blob/v7.0/mm/memory_hotplug.c#L95) · [DAX 设备开关](https://github.com/torvalds/linux/blob/v7.0/drivers/dax/bus.c#L1244) · [kmem 绑定时应用](https://github.com/torvalds/linux/blob/v7.0/drivers/dax/kmem.c#L158)

```bash
grep -E '^CONFIG_(MHP_MEMMAP_ON_MEMORY|LRU_GEN|LRU_GEN_ENABLED)=' "/boot/config-$(uname -r)"
cat /sys/module/memory_hotplug/parameters/memmap_on_memory
sudo daxctl list
# 把 DAX0、DAX1 设成两路实测的 daxX.Y 名称。全局开关应显示 Y。
(
    set -euo pipefail
    [[ $(cat /sys/module/memory_hotplug/parameters/memmap_on_memory) == Y ]]
    [[ "$DAX0" != "$DAX1" ]]
    for device in "$DAX0" "$DAX1"; do
        [[ "$device" =~ ^dax[0-9]+\.[0-9]+$ ]]
        printf '1\n' | sudo tee "/sys/bus/dax/devices/$device/memmap_on_memory"
    done
    sudo daxctl reconfigure-device --mode=system-ram "$DAX0"
    sudo daxctl reconfigure-device --mode=system-ram "$DAX1"
)
sudo daxctl list
lsmem -o RANGE,SIZE,STATE,REMOVABLE,BLOCK,NODE,ZONES
numactl -H
grep MemTotal /sys/devices/system/node/node*/meminfo
cat /sys/devices/virtual/memory_tiering/memory_tier*/nodelist
cat /sys/kernel/mm/numa/demotion_enabled
cat /sys/kernel/mm/lru_gen/enabled
sysctl kernel.numa_balancing
```

用 `lsmem` 检查两路新内存均为 `online`、`Movable`，看 `daxctl list` 的 `target_node` 和慢层列表，节点编号按实测填写。如果设备开关返回 `Operation not supported`，保留内核日志，先查 `cat /sys/devices/system/memory/block_size_bytes` 与内存热插拔对齐。要验证节省量，可在两次干净启动中仅切换每设备 memmap 开关，比较同一范围在线后各节点 `MemTotal` 和 DDR4 启动空闲基线。若实机不支持，使用 `Z8_MEMMAP_ON_MEMORY=0` 的 kmem 对照，按实际 DRAM 余量重新评估 pinned arena。

MGLRU 管页回收顺序。`demotion_enabled` 控制回收时能否尝试把冷的可迁移页移往慢内存。`kernel.numa_balancing` 的标志 `2` 控制热点页向快层提升，首轮保留原 sysctl 值，先测下沉。用 `host/pmem-numa-report.sh <PID>` 对比 `pgdemote_*`、`pgpromote_*`、NUMA 页位置、memory PSI 和 swap 计数。Pinned 页不能下沉。通过后在 `pmem-kmem.env` 设 `Z8_ENABLE_DEMOTION=1`。在线退回 devdax 前先停止负载并检查内存能否 offline，对照实验优先重启。 [daxctl system-ram](https://docs.pmem.io/ndctl-user-guide/daxctl-man-pages/daxctl-reconfigure-device) · [Linux NUMA balancing 位定义](https://docs.kernel.org/admin-guide/sysctl/kernel.html#numa-balancing)

### 核实每路 DDR4 的冷页去向

Linux 7.0 根据 NUMA 距离为每个 DDR4 节点选择下一层首选目标，目标可受 cgroup 内存节点集合约束。两块 PMem 同处慢层、每个 DDR4 节点到同插槽 PMem 的距离较近时，预期各走本地。距离相同可能在两块之间选，本地慢节点分配失败也可能跨路回退。两个 devdax 分别上线。用 `ipmctl show -region` 的 `SocketID` 和 namespace UUID 对到 `daxctl` 的 `target_node`，用距离矩阵和当前启动日志核对，节点号以实机为准。 [Linux 7.0 内存分层与目标选择](https://github.com/torvalds/linux/blob/v7.0/mm/memory-tiers.c#L311) · [Linux 7.0 回收与回退](https://github.com/torvalds/linux/blob/v7.0/mm/vmscan.c#L927)

```bash
numactl -H
sudo daxctl list -RDu
sudo journalctl -k -b -g 'Demotion targets for Node'
printf '1\n' | sudo tee /sys/kernel/mm/numa/demotion_enabled
```

在临时 Xubuntu 上，每次选择一个实际 DDR4 节点，先在该节点分配约 1 GiB 普通匿名页并让进程保持空闲。以下 `fast=0` 是示例。节点号换成实际值，两次依次测，使用同一个临时 unit 名。用测试 cgroup 主动回收 256 MiB，避免压满整机。

```bash
fast=0
unit=z8-pmem-demotion-test.service
sudo systemd-run --unit="$unit" -p MemoryMax=2G -p MemorySwapMax=0 \
    /usr/bin/numactl --cpunodebind="$fast" --membind="$fast" /usr/bin/python3 -c '
import os
import time
pages = bytearray(1 << 30)
for offset in range(0, len(pages), os.sysconf("SC_PAGE_SIZE")):
    pages[offset] = 1
print("ready", flush=True)
time.sleep(300)
'
sudo journalctl -u "$unit" -n 10 --no-pager
```

看到 `ready` 后，再核 `anon` 大部分在目标 DDR4 节点并执行主动回收。

```bash
cg=$(systemctl show -p ControlGroup --value z8-pmem-demotion-test.service)
if [[ "$cg" == */z8-pmem-demotion-test.service ]]; then
    grep -E '^(anon|pgdemote_proactive) ' "/sys/fs/cgroup$cg/memory.numa_stat"
    printf '256M swappiness=max\n' | sudo tee "/sys/fs/cgroup$cg/memory.reclaim"
    grep -E '^(anon|pgdemote_proactive) ' "/sys/fs/cgroup$cg/memory.numa_stat"
    cat "/sys/fs/cgroup$cg/memory.swap.current"
fi
sudo systemctl stop z8-pmem-demotion-test.service
```

对照 `anon` 在源 DDR4 减少、在预期 PMem 节点增长，源节点的 `pgdemote_proactive` 增长，swap 保持 0。`memory.reclaim` 若返回 `EAGAIN`，表示回收量未达到请求值，先看计数和节点分布，再决定是否重试。源节点计数给出下沉量，目的节点的 `anon` 变化给出去向。两路分别跑完，再用真实混合负载比较延迟。 [cgroup v2 主动回收与节点统计](https://docs.kernel.org/admin-guide/cgroup-v2.html#memory-interface-files) · [Linux 7.0 回收计数](https://github.com/torvalds/linux/blob/v7.0/mm/vmscan.c#L4448)

## 核对双路 NUMA 拓扑

T3 两个 kmem 设备上线后，从 `z8-kit` 根目录保存报告。正式系统第一次启动 PMem 服务后复跑，与 T3 对照。用 `lscpu` 的 `SOCKET` 列对照 `numactl`，每颗 CPU 对应一个约 96 GiB 的 DDR4 节点。用 `ipmctl`、`ndctl` 与 `daxctl` 把每路 App Direct region、两个 namespace 的 UUID 和 kmem 目标节点对应起来。用 `lsmem` 和报告中的 `memory_tiering` 核两个 kmem 设备均已作为 `Movable` 内存进入慢层，并记录逐路冷页测试的源和目标。两个 **DDR4** 节点号用于推理启动器的 `Z8_DRAM_INTERLEAVE`。 [Linux 7.0 DAX kmem](https://github.com/torvalds/linux/blob/v7.0/drivers/dax/kmem.c) · [推理启动器](CPU-PLACEMENT.md#启停本地模型)

```bash
mkdir -p "$HOME/z8-burnin"
sudo bash host/pmem-numa-report.sh | tee "$HOME/z8-burnin/numa-topology-$(date +%F-%H%M%S).log"
lsmem -o RANGE,SIZE,STATE,NODE,ZONES
```

## I4 在正式系统复用 PMem

在 T3 把四个 namespace UUID 与两份填好的 env 文件存到独立介质。正式 Xubuntu 26.04.1 启动后用 `ndctl` 对照。BIOS 已应用的 goal、namespace 和已格式化的 DAX 模型卷跨系统保留。正式系统只装用户态工具、服务和环境文件，重启后由服务装配模型卷并把剩余空间 online 为 system RAM。

```bash
sudo apt install ndctl daxctl jq dmsetup xfsprogs
sudo ndctl list -RNXu
sudo install -d -m 0755 /etc/z8-storage /srv/pmem-model
# 把 T3 保存并已核对 UUID 的两个 env 文件放在 z8-kit 根。
sudo install -m 0600 pmem-model.env pmem-kmem.env /etc/z8-storage/
sudo install -m 0755 host/pmem-dax-stripe.sh host/pmem-kmem.sh /usr/local/sbin/
sudo install -m 0644 host/systemd/z8-pmem-{model,kmem}.service /etc/systemd/system/
# 仅在 env 中 Z8_MEMMAP_ON_MEMORY=1 时添加，与 T3 验证过的设置一致。
sudo install -d /etc/default/grub.d
sudo tee /etc/default/grub.d/60-z8-pmem.cfg >/dev/null <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} memory_hotplug.memmap_on_memory=on"
EOF
sudo update-grub
sudo systemctl daemon-reload
sudo systemctl enable z8-pmem-model.service z8-pmem-kmem.service
```

在 `pmem-kmem.env` 中填两路 devdax namespace UUID，照抄 T3 验证过的 `Z8_MEMMAP_ON_MEMORY` 和 `Z8_ENABLE_DEMOTION`。重启后用 `findmnt -M /srv/pmem-model`、`sudo daxctl list`、`numactl -H` 和 `journalctl -b -u z8-pmem-model -u z8-pmem-kmem` 核对。T3 的独立 fsdax 对照卷使用相同的 ext4 挂载参数；正式的推理服务依赖 `/srv/pmem-model` 条带卷。

## 量 UPI 与 pinned memory

```bash
nvcc -O3 -std=c++17 -arch=sm_70 -Xcompiler=-pthread host/pinned-copy.cu -o pinned-copy
# CUDA_VISIBLE_DEVICES 仅含 V100 UUID。先跑系统默认分配策略。
./pinned-copy 512 100
# 按实测 DDR4 节点号替换 0,1。
numactl --interleave=0,1 ./pinned-copy 512 100
numactl --cpunodebind=0 --membind=0 ./pinned-copy 512 100
numactl --cpunodebind=1 --membind=1 ./pinned-copy 512 100
# 同时另开终端，用 Intel PCM 对照实际活跃 UPI link / 双向流量：
sudo pcm 1 -csv=upi.csv
```

用两组各自只可见就近两张 V100 的进程同时跑，和单进程四卡交错比较。用 Intel MLC `--bandwidth_matrix`、`--latency_matrix` 做 CPU DRAM 基线。用同一请求回放比较真实 1Cat 和 Xolotl 的 TTFT、decode、pinned 峰值与跨路流量。普通 `numactl --interleave=0,1` 作用于进程政策，单独用 `numastat -p` 核实际页放置。两个 socket 共用地址空间，拆 rank 和 pinned 分配策略可放在 launcher 里。若 pin API 或引擎把 arena 集中到一节点、复制多份 GGUF 或触及约束，先减少 pinned arena 或改 rank-local staging，逐项重新测。 [Intel MLC](https://www.intel.com/content/www/us/en/developer/articles/tool/intelr-memory-latency-checker.html) · [Intel PCM](https://github.com/intel/pcm) · [Linux NUMA policy](https://docs.kernel.org/admin-guide/mm/numa_memory_policy.html)

四卡实验用同一 CPU 分核、模型卷布局、请求和 Buck2 并发，依次比较 Linux 默认本地优先、两 DDR4 节点交错，以及引擎支持时按卡就近放置 staging。DDR4 交错让假设的 101 GiB arena 平均每路约 50.5 GiB，名义各余 45.5 GiB，再扣系统与构建负载。按卡就近放置 staging 有机会减少跨 UPI 的 DMA。用四卡 pinned H→D、`pcm`、推理和 Buck2 混合负载验证收益。 [Linux NUMA policy](https://docs.kernel.org/admin-guide/mm/numa_memory_policy.html) · [Intel PCM](https://github.com/intel/pcm)

### I7 让推理与编译分用物理核

保留 HT，始终从普通任务中排除推理核的 HT 伙伴。推理服务启动时再划出主线程，停止后只归还主线程。推理按实测的两路 DDR4 节点分配，构建侧可以使用慢层。按 [CPU 分核手册](CPU-PLACEMENT.md) 配置、观察实际引擎 PID 和对照测试。
