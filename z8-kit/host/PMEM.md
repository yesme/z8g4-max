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

region 是 BIOS 划出来的一大段空间，namespace 是 Linux 在这段空间里切出的一块。用 `ipmctl show -region` 的 `SocketID` 和 `ndctl` 的映射信息区分两个 socket，抄下各自的 region ID。新装每路取 258 GiB，能整除 12 MiB，也能整除 2 GiB。Linux 7.0 裸机通常选 2 GiB 热插拔块，但架构代码还看物理地址、固件建议或覆盖值；以 sysfs 为准。namespace 长度对齐只有在起点也对齐时才保证下一个边界对齐，devdax 自身数据偏移还可能改变实际映射。看每个 region 的对齐要求和 `available_size`，以实机返回为准。已有 namespace 时先核用途，切勿重复创建。 [ndctl 参数与对齐](https://docs.pmem.io/ndctl-user-guide/ndctl-man-pages/ndctl-create-namespace)

```bash
# 这两项替换为上面实际看到的 region ID，例如 region0。
R0=regionREPLACE_SOCKET0
R1=regionREPLACE_SOCKET1
sudo ndctl create-namespace -r "$R0" -m fsdax -s 258G --align=2M --map=dev --name=z8-model0
sudo ndctl create-namespace -r "$R1" -m fsdax -s 258G --align=2M --map=dev --name=z8-model1
sudo ndctl create-namespace -r "$R0" -m devdax --align=2M --name=z8-tier0
sudo ndctl create-namespace -r "$R1" -m devdax --align=2M --name=z8-tier1
sudo ndctl list -RNXu
```

预期两个 fsdax 块设备（`/dev/pmemX[.Y]`）给模型卷，两个 devdax 字符设备（`/dev/daxX.Y`）先跑 fio，之后才转 kmem。以输出为准记录四个 namespace UUID、容量、所属 socket。全部验证后恢复原 NVDIMM Freeze 策略。正式系统使用相同 UUID 恢复挂载和 kmem，已有 goal、namespace 和文件系统可直接复用。

两路按同样的方式划分。每路 258 GiB 给 fsdax，剩余约 500 GiB 给 devdax，再转 kmem。

| 物理插槽 | 每路 DDR4 | 每路的 fsdax namespace | 每路的 devdax namespace |
|---|---:|---|---|
| CPU0 | 96 GiB | 258 GiB，模型卷条带成员 | 剩余约 500 GiB，上线为 CPU0 附近的慢内存节点 |
| CPU1 | 96 GiB | 258 GiB，模型卷条带成员 | 剩余约 500 GiB，上线为 CPU1 附近的慢内存节点 |

T3 把两个 `fsdax` 直接组成正式模型卷。两个 `devdax` 各自按固件给的目标节点上线，供 Linux 迁移可回收的页。

**用实机地址核一次容量。** 12 MiB 和 2 GiB 的最小公倍数是 6 GiB。若实机的 region 对齐与热插拔块确为这两个粒度，258 GiB 同时满足两个长度网格。用下面的命令核 devdax 真正暴露的地址。内核把每段起点向上、末端向下取整到热插拔块边界，因而整个段的损失取决于绝对地址和 namespace 内部偏移。已有 255 GiB 的分区可按同一方法量损失，确认需要额外容量后才重切。 [Linux 7.0 x86 热插拔粒度](https://github.com/torvalds/linux/blob/v7.0/arch/x86/mm/init_64.c) · [Linux 7.0 DAX kmem 取整](https://raw.githubusercontent.com/torvalds/linux/v7.0/drivers/dax/kmem.c)

```bash
python3 - 3< <(sudo daxctl list --devices --mappings) <<'PY'
import json
import os
from pathlib import Path

block = int(Path("/sys/devices/system/memory/block_size_bytes").read_text().strip(), 16)
print(f"Hotplug block: {block >> 20} MiB")
with os.fdopen(3) as inventory:
    devices = json.load(inventory)
for device in devices if isinstance(devices, list) else [devices]:
    for region in device.get("mappings", []):
        start, end = (int(str(region[field]), 0) for field in ("start", "end"))
        online = max(0, (end + 1) // block * block - (start + block - 1) // block * block)
        print(f"{device['chardev']} {start:#x}-{end:#x}: "
              f"{online >> 20} MiB in whole blocks, {end + 1 - start - online} bytes excluded")
PY
```

上线后用 `lsmem` 核对，另外记下 memmap 占去的空间。`--map=dev` 给 fsdax 的页描述符约每路预留 4 GiB。块设备实际容量用 `blockdev --getsize64` 核对，挂载后以运行账户执行 `df -h /srv/pmem-model`。按一套约 232 GiB 的 GGUF 和 Engram 规划。 [ndctl 页描述符存放方式](https://docs.pmem.io/ndctl-user-guide/ndctl-man-pages/ndctl-create-namespace)

### App Direct、fsdax 与 devdax

`App Direct` 是 `ipmctl` 给固件提交的容量用途，重启后得到每路的 region。`fsdax` 与 `devdax` 是 Linux 在 region 内按 namespace 选择的访问方式。一套 App Direct 配置可以同时用两种 namespace。 [Linux NVDIMM namespace 模式](https://nvdimm.docs.kernel.org/index.html) · [daxctl system-ram](https://docs.pmem.io/ndctl-user-guide/daxctl-man-pages/daxctl-reconfigure-device)

| 方式 | 出现在 Linux 的形式 | 在本机的用途 |
|---|---|---|
| `fsdax` | `/dev/pmemN` 块设备。XFS 提供普通文件名、权限和 DAX `mmap` | GGUF、Engram、DSpark 和引擎显式保存的文件型快照。读取映射页直接访问 PMem，文件仍可用普通工具管理 |
| `devdax` | `/dev/daxX.Y` 字符设备。程序需要显式映射和管理偏移 | 上线前可逐路测设备。随后交给 `daxctl` 转 `system-ram`，由 `dax_kmem` 把该范围加进 Linux 的系统内存 |

转为 `system-ram` 后由 Linux 管理可移动页，按慢层测试冷页下沉。两路分别上线，不做条带。`fsdax` 文件仍固定在模型卷的物理地址上，内核慢层对可迁移页的处理与模型文件布局独立。CUDA 已长期 pin 的页留在原驻留内存中，也要从 DDR4 预算扣除。

## 模型卷

**T3 一次建成正式卷**。两路各 258 GiB fsdax，合成 2 MiB `dm-stripe`，格式为 XFS DAX。名义 516 GiB，块设备约 508 GiB，挂 `/srv/pmem-model`。使用 4 KiB 文件系统块，`su=2m,sw=2` 匹配条带，关闭模型卷的 reflink。在大文件目录设继承的 2 MiB extent 分配提示。条带以统一容量存放 GGUF、Engram 和 tokenizer，省去按引擎重排分片。同一路的 PMem 仍由固件做六通道交错。两路条带的任一成员失效都要从模型清单恢复整卷。 [dm-stripe DAX 路径](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-stripe.c) · [Linux 2 MiB DAX 对齐](https://nvdimm.docs.kernel.org/2mib_fs_dax.html)

用 `sudo ndctl list -RNv` 核两个已记录的 fsdax namespace UUID，按 CPU0、CPU1 填变量。以下 `mkfs` 只用于 T3 的空 mapper。到了 I4 直接依 UUID 恢复挂载。

```bash
# 用 ndctl 返回的 fsdax namespace UUID，按固定 socket 顺序。
FS0_UUID=REPLACE_NAMESPACE_UUID_SOCKET0
FS1_UUID=REPLACE_NAMESPACE_UUID_SOCKET1
sudo apt install jq
sudo bash host/pmem-dax-stripe.sh show "$FS0_UUID" "$FS1_UUID"
sudo bash host/pmem-dax-stripe.sh create "$FS0_UUID" "$FS1_UUID"
# 仅对首次创建的空 mapper 建文件系统。
sudo mkfs.xfs -b size=4096 -d su=2m,sw=2 -m reflink=0 /dev/mapper/z8-pmem-model
sudo install -d /srv/pmem-model
sudo bash host/pmem-dax-stripe.sh mount "$FS0_UUID" "$FS1_UUID"
sudo xfs_info /srv/pmem-model
# 提示仅给权重目录，tokenizer 仍可放在其他目录。
sudo install -d -o "$(id -u)" -g "$(id -g)" /srv/pmem-model/ds41-llamacpp
sudo xfs_io -c 'extsize 2m' /srv/pmem-model/ds41-llamacpp
```

这里用 `noatime` 免去权重、Engram 热读触发的访问时间更新，保留 XFS 日志和正常的写入同步语义。App Direct DAX 模型卷以读为主，使用 `nodiscard`。在该路径实际创建测试文件，执行 `xfs_io -r -c 'statx -r' /srv/pmem-model/burnin.bin`。核 `stx_attributes_mask` 和 `stx_attributes` 的 `STATX_ATTR_DAX` 位 `0x200000` 都为 1。此卷保存模型权重、Engram、DSpark 和支持持久化的 KV checkpoint，模型 revision、SHA-256 和下载清单留在 P4618。 [全机挂载表](MOUNTS.md) · [Linux 文件级 DAX 状态](https://docs.kernel.org/filesystems/dax.html) · [两个引擎的 KV 配置](../inference/README.md)

`xfs_info` 应显示 `sunit=512 swidth=1024 blks` 和 `reflink=0`。2 MiB PMD 还要求物理范围、文件偏移和 mmap 地址相容，收紧分配对齐后仍可能回退。在 T5 模型下载后用 `xfs_io -r -c 'fiemap -v' "$DS41_GGUF"` 记录分片 extent；需要确认实际 PMD 命中时，用 `trace-cmd record -e fs_dax:dax_pmd_fault_done` 跟踪 `mmap` 负载。事件 `NOPAGE` 表示成功，`FALLBACK` 表示落入小页路径。Xolotl 的 Engram 走 `pread`，直接查它的 I/O 时延。 [Linux 2 MiB DAX 验证](https://nvdimm.docs.kernel.org/2mib_fs_dax.html)

### 交给启动服务

首次测试后卸载并删除 mapper，再让服务接管。复制 `host/pmem-model.env.example` 为 `pmem-model.env`，填写两个 fsdax namespace UUID。

```bash
sudo bash host/pmem-dax-stripe.sh unmount "$FS0_UUID" "$FS1_UUID"
sudo install -d -m 0755 /etc/z8-storage
sudo install -m 0600 pmem-model.env /etc/z8-storage/
sudo install -m 0755 host/pmem-dax-stripe.sh host/pmem-device-wait.sh /usr/local/sbin/
sudo install -m 0644 host/systemd/z8-pmem-model.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now z8-pmem-model.service
findmnt -M /srv/pmem-model
```

依赖该卷的推理 systemd 服务加 `BindsTo=z8-pmem-model.service` 与 `After=z8-pmem-model.service`，启动脚本查 `findmnt -M /srv/pmem-model` 后再读模型。

若首次启动在 mount 步骤失败，核 kernel 日志和 `blkid /dev/mapper/z8-pmem-model`。修复挂载问题后，服务可复用底层设备、顺序和长度全部匹配的现有 mapper，以及来源和 DAX 选项均匹配的现有挂载。表结构不同或路径被其他文件系统占用时，先查清现有映射与用途。已有 ext4 模型卷时，先保存可重下的文件清单或备份权重，再停服务卸载。转为 XFS 须重建文件系统，仅在确认允许清空后按 T3 步骤执行并恢复权重。

## 剩余 PMem 转 kmem

先完成两块 devdax 的专用 fio 测试。用 `sudo daxctl list` 找到真实的两个 `daxX.Y`。把 `struct page` 等热插拔页描述符放在 PMem 内部，Linux 7.0 需要两个开关。T3 在 GRUB 临时给当前内核的 `linux` 行追加 `memory_hotplug.memmap_on_memory=on`，启动后在每个 DAX 设备上写 `1`，然后才绑定 kmem。Ubuntu `7.0.0-43-generic` 的配置包含 `CONFIG_MHP_MEMMAP_ON_MEMORY=y`。两个设备合计约 1 TiB，按 4 KiB 页和 64 B 页描述符估算约 16 GiB 元数据，实际在线容量和 DDR4 节约量按热插拔粒度、对齐和实机节点统计核算。 [Linux 7.0 全局热插拔参数](https://github.com/torvalds/linux/blob/v7.0/mm/memory_hotplug.c#L95) · [DAX 设备开关](https://github.com/torvalds/linux/blob/v7.0/drivers/dax/bus.c#L1244) · [kmem 绑定时应用](https://github.com/torvalds/linux/blob/v7.0/drivers/dax/kmem.c#L158)

```bash
grep -E '^CONFIG_(MHP_MEMMAP_ON_MEMORY|LRU_GEN|LRU_GEN_ENABLED)=' "/boot/config-$(uname -r)"
cat /sys/module/memory_hotplug/parameters/memmap_on_memory
sudo daxctl list
# 把 DAX0、DAX1 设成两路实测的 daxX.Y 名称。全局开关应显示 Y 或 force。
(
    set -euo pipefail
    [[ $(cat /sys/module/memory_hotplug/parameters/memmap_on_memory) =~ ^(Y|force)$ ]]
    [[ "$DAX0" != "$DAX1" ]]
    for device in "$DAX0" "$DAX1"; do
        [[ "$device" =~ ^dax[0-9]+\.[0-9]+$ ]]
        printf '1\n' | sudo tee "/sys/bus/dax/devices/$device/memmap_on_memory"
    done
    time sudo daxctl reconfigure-device --mode=system-ram "$DAX0"
    time sudo daxctl reconfigure-device --mode=system-ram "$DAX1"
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

用 `lsmem` 检查两路新内存都为 `online`、`Movable`，并记录 `target_node` 和慢层列表。设备级开关返回 `Operation not supported` 时先核对启动参数、物理区间和内存块大小。若设备仍无法把页描述符放在 PMem，才用 `Z8_MEMMAP_ON_MEMORY=0`，并从 DDR4 可用空间扣掉实际元数据开销。

MGLRU 管页回收顺序。`demotion_enabled` 控制回收时能否尝试把冷的可迁移页移往慢内存。启用 kmem 时把 `kernel.numa_balancing` 设为 `2`，让热点页从慢层提升。Linux 7.0 在此模式为顶层 DDR4 页跳过本次 NUMA hinting PTE 扫描。T3 在两路 kmem 上线后运行 `sudo sysctl -w kernel.numa_balancing=2`，再做下沉验证。用 `host/pmem-numa-report.sh <PID>` 对比 `pgdemote_*`、`pgpromote_*`、NUMA 页位置、memory PSI 和 swap 计数。Pinned 页不能下沉。T3 确认去向后，正式服务采用样例的 `Z8_ENABLE_DEMOTION=1`。需要退回 devdax 时先停止负载并检查内存能否 offline。 [daxctl system-ram](https://docs.pmem.io/ndctl-user-guide/daxctl-man-pages/daxctl-reconfigure-device) · [Linux 7.0 顶层 NUMA 扫描条件](https://github.com/torvalds/linux/blob/v7.0/mm/mempolicy.c#L864)

### T3 记录 kmem 冷启动时间

手动检查通过后，在临时系统用 I4 的安装命令安装脚本、单元和实际 UUID 配置，只启用 `z8-pmem-kmem.service`。按实测的 memmap 设置持久化启动参数，再做三次冷启动。每次记录枚举耗时、每路 online 耗时和整个服务用时。保留两路 `daxctl list --devices` 的 `online_memblocks`、`total_memblocks` 与 `movable`。

```bash
sudo journalctl -b -u z8-pmem-kmem.service -o short-monotonic --no-pager
systemctl show z8-pmem-kmem.service -p Result -p ExecMainStartTimestampMonotonic -p ExecMainExitTimestampMonotonic
sudo daxctl list --devices
```

两个服务按 UUID 各等最多 90 秒。fsdax 还等两个块设备节点出现，devdax 等两个设备都绑定 DAX 驱动。模型单元给枚举、创建 mapper 与挂载共 150 秒。kmem 单元给枚举与两路上线共 600 秒。默认使用上述超时。只有正常上线因实际耗时触及 600 秒时才延长；需要改时用 `sudo systemctl edit z8-pmem-kmem.service`，按最慢日志留出余量。调 `Z8_PMEM_DEVICE_WAIT` 时，同步确保对应单元的 `TimeoutStartSec` 还覆盖余下操作。

```ini
[Service]
TimeoutStartSec=900s
```

若 kmem 在中途超时，保留日志并先查两块设备的实际 online 状态，再用 `sudo systemctl restart z8-pmem-kmem.service` 补上线。脚本跳过已完全在线的可移动内存，补上线部分完成的设备，并在两路验过后才启用配置要求的页下沉。若遇到已上线但 zone 错误，核系统的 auto-online 策略后冷启重测。 [systemd 启动超时](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html#TimeoutStartSec=) · [daxctl v81 区段状态字段](https://github.com/pmem/ndctl/blob/v81/daxctl/json.c)

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

对照 `anon` 在源 DDR4 减少、在预期 PMem 节点增长，源节点的 `pgdemote_proactive` 增长，swap 保持 0。`memory.reclaim` 若返回 `EAGAIN`，表示回收量未达到请求值，先看计数和节点分布，再决定是否重试。源节点计数给出下沉量，目的节点的 `anon` 变化给出去向。两路各通过一次。 [cgroup v2 主动回收与节点统计](https://docs.kernel.org/admin-guide/cgroup-v2.html#memory-interface-files) · [Linux 7.0 回收计数](https://github.com/torvalds/linux/blob/v7.0/mm/vmscan.c#L4448)

## 核对双路 NUMA 拓扑

T3 两个 kmem 设备上线后，从 `z8-kit` 根目录保存报告。正式系统第一次启动 PMem 服务后复跑，与 T3 对照。用 `lscpu` 的 `SOCKET` 列对照 `numactl`，每颗 CPU 对应一个约 96 GiB 的 DDR4 节点。用 `ipmctl`、`ndctl` 与 `daxctl` 把每路 App Direct region、两个 namespace 的 UUID 和 kmem 目标节点对应起来。用 `lsmem` 和报告中的 `memory_tiering` 核两个 kmem 设备均已作为 `Movable` 内存进入慢层，并记录逐路冷页测试的源和目标。两个 **DDR4** 节点号用于推理启动器的 `Z8_DRAM_INTERLEAVE`。 [Linux 7.0 DAX kmem](https://github.com/torvalds/linux/blob/v7.0/drivers/dax/kmem.c) · [推理启动器](CPU-PLACEMENT.md#启停本地模型)

```bash
mkdir -p "$HOME/z8-burnin"
sudo bash host/pmem-numa-report.sh | tee "$HOME/z8-burnin/numa-topology-$(date +%F-%H%M%S).log"
lsmem -o RANGE,SIZE,STATE,NODE,ZONES
```

## I4 在正式系统复用 PMem

在 T3 把四个 namespace UUID 与两份填好的 env 文件存到独立介质。正式 Xubuntu 26.04.1 启动后用 `ndctl` 对照。BIOS 已应用的 goal、namespace 和已格式化的 DAX 模型卷跨系统保留。

按保存的 UUID 启用正式条带和 kmem 服务。

```bash
sudo apt install ndctl daxctl jq dmsetup xfsprogs
sudo ndctl list -RNXu
sudo install -d -m 0755 /etc/z8-storage /srv/pmem-model
# 把 T3 保存并已核对 UUID 的两个 env 文件放在 z8-kit 根。
sudo install -m 0600 pmem-model.env pmem-kmem.env /etc/z8-storage/
sudo install -m 0755 host/pmem-dax-stripe.sh host/pmem-kmem.sh host/pmem-device-wait.sh /usr/local/sbin/
sudo install -m 0644 host/systemd/z8-pmem-{model,kmem}.service /etc/systemd/system/
# 仅在 env 中 Z8_MEMMAP_ON_MEMORY=1 时添加，与 T3 验证过的设置一致。
sudo install -d /etc/default/grub.d
sudo tee /etc/default/grub.d/60-z8-pmem.cfg >/dev/null <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} memory_hotplug.memmap_on_memory=on"
EOF
sudo update-grub
sudo systemctl daemon-reload
sudo install -m 0644 host/90-z8-tiering.conf.example /etc/sysctl.d/90-z8-tiering.conf
sudo systemctl enable z8-pmem-kmem.service
sudo systemctl enable z8-pmem-model.service
```

在 `pmem-kmem.env` 中填两路 devdax namespace UUID，照抄 T3 验证过的 `Z8_MEMMAP_ON_MEMORY` 和 `Z8_ENABLE_DEMOTION`。重启后用 `sudo daxctl list`、`numactl -H` 和 `journalctl -b -u z8-pmem-kmem` 核对 kmem，`sysctl kernel.numa_balancing` 应为 `2`。条带按 `findmnt -M /srv/pmem-model` 和 `journalctl -b -u z8-pmem-model` 核对。仓库已有的推理服务依赖 `/srv/pmem-model`。

## 四卡 pinned DMA 验收

两条 UPI 由 Z8 G4 主板布线决定，最高 10.4 GT/s/条。DDR4 交错是推理服务的固定策略，两个 DDR4 节点各有标称 96 GiB。PCIe Gen3 x8 每卡理论约 7.88 GB/s。按均匀交错和四卡同时传输估算，GPU 的净 H→D payload 在每个 UPI 方向约 7.88 GB/s 上限。DAX 文件的 CPU 跨路读取是另一项流量。当前方案在 CPU 侧从 PMem 取权重，按引擎需要用 DDR4 作 DMA staging。Linux 7.0 的 GUP 会拒绝对 fsdax 映射的长时间页 pin。 [HP 白皮书，第 3 页](https://www.workstation4u.de/hp-z8-g4-technichalwhitepaper.pdf#page=3) · [Linux 7.0 GUP](https://github.com/torvalds/linux/blob/v7.0/mm/gup.c#L1200)

T5 只测正式使用的交错策略。先按 `numactl -H` 设置实际两个 DDR4 节点，按验机记录填四张 GPU UUID。

```bash
nvcc -O3 -std=c++17 -arch=sm_70 -Xcompiler=-pthread host/pinned-copy.cu -o pinned-copy
export CUDA_VISIBLE_DEVICES=GPU-REPLACE0,GPU-REPLACE1,GPU-REPLACE2,GPU-REPLACE3
DRAM_NODES=0,1
numactl --interleave="$DRAM_NODES" ./pinned-copy 512 300 h2d
```

确认四张卡的传输都完成，记录四卡合计 H→D 和 Xid/AER。传输报错或合计带宽异常时，再逐卡核链路并定位线材。只有真实推理同时出现跨路流量接近链路上限、H→D 或 TTFT 失速时，才加 Intel PCM 做归因。引擎已有独立 per-rank 缓冲时可把 staging 分配给各自的 DDR4 节点。Xolotl 单进程多 stage 要在缓冲分配处处理。 [Intel PCM](https://github.com/intel/pcm) · [Xolotl stage 初始化](https://github.com/Indras-Mirror/Xolotl/blob/db25febda3e2869333d72eca6b17296142916a9b/tools/v41/engine/ds41_pipeline.cpp#L382)
