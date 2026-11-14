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

两路按同样的方式划分，每路 258 GiB 给 fsdax，剩余约 500 GiB 给 devdax，再转 kmem。实际容量按 namespace 和上线后的 NUMA 节点记录。优先验证对称布局。把 CPU1 改成约 500 GiB 本地 fsdax 加约 256 GiB kmem，要在确实需要单路容纳实测模型文件、且本地 DAX 读取显著受益后再考虑。重切前先迁走模型、卸载并备份 namespace 记录。Engram 是静态查表，DSpark 是投机解码组件，KV 随请求变化；容量分别从所选引擎的实际文件与运行时统计获取。

| 物理插槽 | 每路 DDR4 | 每路的 fsdax namespace | 每路的 devdax namespace |
|---|---:|---|---|
| CPU0 | 96 GiB | 258 GiB，本地模型卷或条带成员 | 剩余约 500 GiB，上线为 CPU0 附近的慢内存节点 |
| CPU1 | 96 GiB | 258 GiB，本地模型卷或条带成员 | 剩余约 500 GiB，上线为 CPU1 附近的慢内存节点 |

两个 `fsdax` 在 T3 先各自挂载，可在之后组成名义 516 GiB、块设备约 508 GiB 的模型卷。两个 `devdax` 各自按固件给的目标节点上线，供 Linux 迁移可回收的页。四个 namespace 的数量和 Linux NUMA 节点的数量分别核对。

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

上线后用 `lsmem` 核对，另外记下 memmap 在慢内存中占去的空间。`--map=dev` 给 fsdax 的 4 KiB 页描述符约每路预留 4 GiB。用 `sudo blockdev --getsize64 "$FS0"` 等命令查实际块设备大小，挂载后用运行账户执行 `df -B1` 核可用量。两套各约 232 GiB 的模型和 Xolotl 的 20 GiB 空间检查要一起核算，还要给实际配置的 DSpark、KV 和临时文件留余量。若 258 GiB 档实测偏紧且确实要双套常驻，可在首次建卷前把每路调到 264 GiB，换取约 12 GiB 模型卷空间，同时每路少约 6 GiB kmem。分卷时还要确认每路都装得下各自的分片。 [ndctl 页描述符存放方式](https://docs.pmem.io/ndctl-user-guide/ndctl-man-pages/ndctl-create-namespace) · [Ubuntu 26.04 mke2fs 保留块](https://manpages.ubuntu.com/manpages/resolute/man8/mke2fs.8.html)

### App Direct、fsdax 与 devdax

`App Direct` 是 `ipmctl` 给固件提交的容量用途，重启后得到每路的 region。`fsdax` 与 `devdax` 是 Linux 在 region 内按 namespace 选择的访问方式。一套 App Direct 配置可以同时用两种 namespace。 [Linux NVDIMM namespace 模式](https://nvdimm.docs.kernel.org/index.html) · [daxctl system-ram](https://docs.pmem.io/ndctl-user-guide/daxctl-man-pages/daxctl-reconfigure-device)

| 方式 | 出现在 Linux 的形式 | 在本机的用途 |
|---|---|---|
| `fsdax` | `/dev/pmemN` 块设备。ext4 提供普通文件名、权限和 DAX `mmap` | GGUF、Engram、DSpark 和引擎显式保存的文件型快照。读取映射页直接访问 PMem，文件仍可用普通工具管理 |
| `devdax` | `/dev/daxX.Y` 字符设备。程序需要显式映射和管理偏移 | 上线前可逐路测设备。随后交给 `daxctl` 转 `system-ram`，由 `dax_kmem` 把该范围加进 Linux 的系统内存 |

转为 `system-ram` 后由 Linux 管理可移动页，按慢层测试冷页下沉。两路分别上线，不做条带。`fsdax` 文件仍固定在模型卷的物理地址上，内核慢层对可迁移页的处理与模型文件布局独立。CUDA 已长期 pin 的页留在原驻留内存中，也要从 DDR4 预算扣除。

## 模型卷

**现有启动配置用 2 MiB `dm-stripe`，性能验证先跑两卷。** T3 各自挂载两个本地文件系统。I6 首次跑固定的 1017 套装时，若要做引擎本地性优化，优先用两卷摆放分片。四卡推理只有在读文件的线程贴近相应 PMem 时才兑现本地性。引擎靠一组共享线程读两路文件，或服务要在多种模型与引擎间切换时，条带提供名义 516 GiB、块设备约 508 GiB 的统一容量和目录。连续访问的大文件可用上两路 PMem，不过单个进入同一 2 MiB chunk 的读取由一路服务。各 socket 固件配置的六通道交错在两种布局中都生效。条带损失任一成员会使整卷不可用。 [Linux dm-stripe 的 DAX 路径](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-stripe.c) · [PMem 的 dm-stripe 操作](https://pmem.io/blog/2018/05/using-persistent-memory-devices-with-the-linux-device-mapper/#creating-dm-striped-devices)

最接近本机的公开实测是双路 5220S，每路同样配 6×128 GiB 第一代 Optane 和 6×16 GiB DDR4。其 devdax 4 KiB 分段扫描在每路 18 核各自读本地时合计约 80 GB/s，双路分别读对端约 50 GB/s。另一项第一代 Optane 实验测到远端随机 load 延迟约为本地的 1.20 倍。这两项分别反映饱和吞吐和单次访存，本机六核/路和 Engram 随机行读取各自实测。Intel 社区处理跨路合卷的案例也建议按 socket 分配数据和 worker。Zhu 等用两条 DIMM 做 4 KiB dm-stripe，普通 Ext4 的峰值读取约翻倍，实验未启用 DAX。 [Daase 等，图 5–6](https://hpi.de/oldsite/fileadmin/user_upload/fachgebiete/rabl/publications/2021/pmem_olap_sigmod_21.pdf#page=5) · [Yang 等，§5.4](https://www.usenix.org/system/files/fast20-yang.pdf#page=12) · [Intel 社区合卷讨论](https://community.intel.com/t5/Intel-Optane-Persistent-Memory/how-to-integrate-two-DCPMM-regions-into-one/m-p/1260575) · [Zhu 等，§4.4](https://www.mdpi.com/2079-9292/10/16/1977#sec4dot4)

### 两个本地卷的 1017 文件布局

下表适用于 llama.cpp 与固定版 Xolotl 共用的 ISTA IQ2_XXS + IQ4_NL Engram。层号按固定 revision 的 GGUF 文件头核对，边界层可能分属两个文件。首轮按 PCIe 归属把每路的两张 V100 排在一起，给 Xolotl 传 `10,20,30`，核日志实际采用的 indexer-safe 切点。若中间切在 20，第 20～22 层及第 23 层一部分仍在 CPU0 的分片 3，CPU1 侧 stage 在需要时跨路读。分片 2 还包含 `output.weight`，输出头若留在 CPU1 侧 GPU，则至少冷启动时也可能跨路取它。只有在逐卡显存、专家命中率和 TTFT 都量过后才调整切层。 [固定 revision 的 ISTA 文件](https://huggingface.co/ISTA-DASLab/DeepSeek-V4.1-Flash-1017-GSQ-RCO-GGUF/tree/65d53bc8be65123e255ff02f3ded958b6dbf54fd) · [1017 官方 config](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017/raw/main/config.json#L130) · [Xolotl 切层规则](https://github.com/Indras-Mirror/Xolotl/blob/db25febda3e2869333d72eca6b17296142916a9b/tools/v41/engine/ds41_pipeline.cpp#L325)

| 实际存放位置 | 分片与模型文件 | 名义用量 |
|---|---|---:|
| CPU0，`/srv/pmem-local0/ds41` | `00001` 元数据、`00002` 层 0–12、`00003` 层 12–23，另加包含层 1、14 的完整 Engram GGUF | 约 177 GiB |
| CPU1，`/srv/pmem-local1/ds41` | `00004` 层 23–34、`00005` 层 34–39 | 约 55 GiB |

从 [推理安装](../inference/README.md#llamacpp-v100-首选多会话服务候选) 取相同仓库和 revision，按表把文件下载到两个卷。分片 `00001` 放在 CPU0 目录的实体路径，Xolotl 的配置生成器会解析输入路径，两个 loader 都要能从第一个分片找到后续文件。卷都已挂载、文件下完后，把 `00004`、`00005` 链接到 CPU0 目录，`00006` 链到 CPU0 的 Engram 文件。容器测试将两处路径都以原绝对路径只读挂载。当前正式服务依赖条带卷，两个本地卷的测试用前台启动，先将启动前置挂载检查改为核两处 ext4 DAX。 [llama.cpp 分片 loader](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/src/llama-model-loader.cpp) · [Xolotl Engram loader](https://github.com/Indras-Mirror/Xolotl/blob/db25febda3e2869333d72eca6b17296142916a9b/tools/v41/engine/ds41_engram.cpp#L262)

```bash
(
    set -euo pipefail
    for mount in /srv/pmem-local0 /srv/pmem-local1; do
        findmnt -rn -M "$mount" -t ext4 -O dax=always
    done
    repo=ISTA-DASLab/DeepSeek-V4.1-Flash-1017-GSQ-RCO-GGUF
    revision=65d53bc8be65123e255ff02f3ded958b6dbf54fd
    stem=DeepSeek-V4.1-Flash-1017-GSQ-RCO-IQ2_XXS
    engram=DeepSeek-V4.1-Flash-Engram-IQ4_NL.gguf
    # 以运行账户执行。首次下载前可加 --dry-run 核文件清单。
    hf download "$repo" --revision "$revision" --local-dir /srv/pmem-local0/ds41 \
        "$stem-00001-of-00006.gguf" "$stem-00002-of-00006.gguf" "$stem-00003-of-00006.gguf" "$engram"
    hf download "$repo" --revision "$revision" --local-dir /srv/pmem-local1/ds41 \
        "$stem-00004-of-00006.gguf" "$stem-00005-of-00006.gguf"
    cd /srv/pmem-local0/ds41
    for part in 00004 00005; do
        file="$stem-$part-of-00006.gguf"
        target="/srv/pmem-local1/ds41/$file"
        test -s "$target"
        ln -sT -- "$target" "$file"
    done
    test -s "$engram"
    ln -sT -- "$engram" "$stem-00006-of-00006.gguf"
)
```

Engram 两层都在 CPU0 的 GPU stages。Xolotl 为相关 stage 创建 Engram reader，小批读取也可能在调用线程执行。当前 launcher 的 `STRATA_POOL_CORES` 控制 CPU expert workers，两个卷加上全进程 DDR4 交错也只建立了文件的物理归属。测试时观察 Engram 工作线程与调用线程所在的 CPU；要兑现完整的分卷方案，相关 reader 应在 CPU0，专家文件 reader 与 staging 分配按 stage 就近。llama.cpp 的 `--split-mode layer` 可作相同的文件对照，先看真实切层与 CPU gather 调度。1Cat 的 TP4 每层跨四 rank，先量每 rank 的 staging 与集合通信，按层摆整个 GGUF 对它的收益需要另测。 [Xolotl Engram 读线程](https://github.com/Indras-Mirror/Xolotl/blob/db25febda3e2869333d72eca6b17296142916a9b/tools/v41/engine/ds41_engram.cpp#L741) · [1Cat V4.1 运行路径](https://github.com/1CatAI/1Cat-vLLM/blob/main/benchmarks/deepseek_v41/HANDOFF.md) · [llama.cpp 社区 NUMA 实验](https://github.com/ggml-org/llama.cpp/pull/27986)

用 `sudo ndctl list -RNv` 记录每个 region 下 fsdax 的 `uuid`、`blockdev` 和 NUMA 归属。以下两条 `mkfs.ext4` 各写一个空的 fsdax namespace，适合 T3 首次建本地卷。T3 两种布局的验证都用可清除的测试文件。若预定在 I6 先跑分卷，T3 测完条带后卸载并移除 mapper，再重建空的两个本地卷。若随后切换到条带，卸载前保存模型清单、校验值与需要恢复的文件。条带的 mkfs 会覆盖两侧原有文件系统。

```bash
FS0=/dev/pmemREPLACE_SOCKET0
FS1=/dev/pmemREPLACE_SOCKET1
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS "$FS0" "$FS1"
sudo install -d /srv/pmem-local0 /srv/pmem-local1
sudo mkfs.ext4 -b 4096 -m 1 -E stride=512 "$FS0"
sudo mkfs.ext4 -b 4096 -m 1 -E stride=512 "$FS1"
sudo mount -t ext4 -o dax=always,noatime,data=ordered,nodiscard "$FS0" /srv/pmem-local0
sudo mount -t ext4 -o dax=always,noatime,data=ordered,nodiscard "$FS1" /srv/pmem-local1
findmnt -M /srv/pmem-local0
findmnt -M /srv/pmem-local1
```

进 I6 后，确认两个本地卷已挂载，再用 `sudo install -d -m 0750 -o "$(id -un)" -g "$(id -gn)" /srv/pmem-local{0,1}/ds41` 给运行账户准备目录。

```bash
# 用 ndctl 返回的 fsdax namespace UUID，按固定 socket 顺序。
sudo apt install jq
sudo bash host/pmem-dax-stripe.sh show "$FS0_UUID" "$FS1_UUID"
sudo bash host/pmem-dax-stripe.sh create "$FS0_UUID" "$FS1_UUID"
# 仅对首次创建的空 mapper 建文件系统。2 MiB chunk / 4 KiB = 512。
sudo mkfs.ext4 -b 4096 -m 1 -E stride=512,stripe_width=1024 /dev/mapper/z8-pmem-model
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

在报告里按设备号和 inode 过滤。该事件的 `NOPAGE` 表示一次成功的 DAX PMD fault，`FALLBACK` 表示这次退回小页。没有事件时查引擎是否真的映射了该文件。一个成功映射的 2 MiB 叶条目覆盖 512 个 4 KiB 页，实际收益取决于访问稀疏程度与热区。约 232 GiB 的 GGUF 文件集合已经含 Engram 权重，容量按模型清单计一次。 [Linux DAX 大页与 tracepoint](https://nvdimm.docs.kernel.org/2mib_fs_dax.html)

**同布局比较 ext4 与 XFS。** 首装服务沿用上面的 ext4。两个文件系统都能产生 2 MiB DAX 映射。XFS 的目录 `extsize` 给新文件继承分配提示，实际 extent 和应用虚拟地址都要验。只在存大权重的目录上设 2 MiB，把 tokenizer、配置和其他小文件留在普通目录。以下是在 T3 留出的空条带上重建测试文件系统的命令，会覆盖 mapper 上的旧文件系统。若要比较单路卷，分别使用对应的整块 fsdax 设备和 `sw=1`。测完 XFS 若继续采用 ext4，按上文重建空 ext4 再安装启动服务。 [Ubuntu 26.04 xfs_io](https://manpages.ubuntu.com/manpages/resolute/man8/xfs_io.8.html) · [Linux 7.0 XFS DAX 挂载检查](https://github.com/torvalds/linux/blob/v7.0/fs/xfs/xfs_super.c#L342)

```bash
findmnt -S /dev/mapper/z8-pmem-model  # 若仍显示挂载，先卸载并确认已保存测试数据。
sudo mkfs.xfs -f -b size=4096 -d su=2m,sw=2 -m reflink=0 /dev/mapper/z8-pmem-model
sudo mount -t xfs -o dax=always,noatime,nodiscard /dev/mapper/z8-pmem-model /srv/pmem-model
sudo install -d -m 0750 -o "$(id -un)" -g "$(id -gn)" /srv/pmem-model/weights
sudo xfs_io -c 'extsize 2m' /srv/pmem-model/weights
# 写入同一份 burnin.bin 后查看逻辑和物理区段。
sudo xfs_io -r -c 'extsize' -c 'fiemap -v' /srv/pmem-model/weights/burnin.bin
```

先核对两个测试文件都具备 DAX 属性，再用相同的 NUMA 策略、模型文件和请求回放，比较 PMD fault 首次成功比例、冷加载与工具返回后的 TTFT。支持计数时同时记录 `perf stat` 的 dTLB 事件，先用 `perf list` 选本机确实支持的事件。对 Xolotl 的 Engram 用 `pread` 实测时延，进程内 Engram PMD fault 不是该路径的指标。

### 交给启动服务

首次测试后卸载并删除 mapper，再让服务接管。复制 `host/pmem-model.env.example` 为 `pmem-model.env`，填写两个 fsdax namespace UUID。

```bash
sudo umount /srv/pmem-model
sudo dmsetup remove z8-pmem-model
sudo install -d -m 0755 /etc/z8-storage
sudo install -m 0600 pmem-model.env /etc/z8-storage/
sudo install -m 0755 host/pmem-dax-stripe.sh host/pmem-device-wait.sh /usr/local/sbin/
sudo install -m 0644 host/systemd/z8-pmem-model.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now z8-pmem-model.service
findmnt -M /srv/pmem-model
```

依赖该卷的推理 systemd 服务加 `BindsTo=z8-pmem-model.service` 与 `After=z8-pmem-model.service`，启动脚本查 `findmnt -M /srv/pmem-model` 后再读模型。

若首次启动在 mount 步骤失败，核 kernel 日志和 `blkid /dev/mapper/z8-pmem-model`。修复挂载问题后，服务可复用底层设备、顺序和长度全部匹配的现有 mapper，以及来源和 DAX 选项均匹配的现有挂载。表结构不同或路径被其他文件系统占用时，先查清现有映射与用途。已有模型数据时保留文件系统。

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

用 `lsmem` 检查两路新内存均为 `online`、`Movable`，看 `daxctl list` 的 `target_node` 和慢层列表，节点编号按实测填写。如果设备开关返回 `Operation not supported`，保留内核日志，先查 `cat /sys/devices/system/memory/block_size_bytes` 与内存热插拔对齐。要验证节省量，可在两次干净启动中仅切换每设备 memmap 开关，比较同一范围在线后各节点 `MemTotal` 和 DDR4 启动空闲基线。若实机不支持，使用 `Z8_MEMMAP_ON_MEMORY=0` 的 kmem 对照，按实际 DRAM 余量重新评估 pinned arena。

MGLRU 管页回收顺序。`demotion_enabled` 控制回收时能否尝试把冷的可迁移页移往慢内存。`kernel.numa_balancing` 的标志 `2` 控制热点页向快层提升，首轮保留原 sysctl 值，先测下沉。用 `host/pmem-numa-report.sh <PID>` 对比 `pgdemote_*`、`pgpromote_*`、NUMA 页位置、memory PSI 和 swap 计数。Pinned 页不能下沉。通过后在 `pmem-kmem.env` 设 `Z8_ENABLE_DEMOTION=1`。在线退回 devdax 前先停止负载并检查内存能否 offline，对照实验优先重启。 [daxctl system-ram](https://docs.pmem.io/ndctl-user-guide/daxctl-man-pages/daxctl-reconfigure-device) · [Linux NUMA balancing 位定义](https://docs.kernel.org/admin-guide/sysctl/kernel.html#numa-balancing)

### T3 记录 kmem 冷启动时间

手动检查通过后，在临时系统用 I4 的安装命令安装脚本、单元和实际 UUID 配置，只启用 `z8-pmem-kmem.service`。按实测的 memmap 设置持久化启动参数，再做三次冷启动。每次记录枚举耗时、每路 online 耗时和整个服务用时。保留两路 `daxctl list --devices` 的 `online_memblocks`、`total_memblocks` 与 `movable`。

```bash
sudo journalctl -b -u z8-pmem-kmem.service -o short-monotonic --no-pager
systemctl show z8-pmem-kmem.service -p Result -p ExecMainStartTimestampMonotonic -p ExecMainExitTimestampMonotonic
sudo daxctl list --devices
```

两个服务按 UUID 各等最多 90 秒。fsdax 还等两个块设备节点出现，devdax 等两个设备都绑定 DAX 驱动。模型单元给枚举、创建 mapper 与挂载共 150 秒。kmem 单元给枚举与两路上线共 600 秒。以冷启耗时校准，给实测最慢的上线阶段留余量。若需要调，用 `sudo systemctl edit z8-pmem-kmem.service` 将下面的 `900s` 换成按实测采用的值。调 `Z8_PMEM_DEVICE_WAIT` 时，同步确保对应单元的 `TimeoutStartSec` 还覆盖余下操作。

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

对照 `anon` 在源 DDR4 减少、在预期 PMem 节点增长，源节点的 `pgdemote_proactive` 增长，swap 保持 0。`memory.reclaim` 若返回 `EAGAIN`，表示回收量未达到请求值，先看计数和节点分布，再决定是否重试。源节点计数给出下沉量，目的节点的 `anon` 变化给出去向。两路分别跑完，再用真实混合负载比较延迟。 [cgroup v2 主动回收与节点统计](https://docs.kernel.org/admin-guide/cgroup-v2.html#memory-interface-files) · [Linux 7.0 回收计数](https://github.com/torvalds/linux/blob/v7.0/mm/vmscan.c#L4448)

## 核对双路 NUMA 拓扑

T3 两个 kmem 设备上线后，从 `z8-kit` 根目录保存报告。正式系统第一次启动 PMem 服务后复跑，与 T3 对照。用 `lscpu` 的 `SOCKET` 列对照 `numactl`，每颗 CPU 对应一个约 96 GiB 的 DDR4 节点。用 `ipmctl`、`ndctl` 与 `daxctl` 把每路 App Direct region、两个 namespace 的 UUID 和 kmem 目标节点对应起来。用 `lsmem` 和报告中的 `memory_tiering` 核两个 kmem 设备均已作为 `Movable` 内存进入慢层，并记录逐路冷页测试的源和目标。两个 **DDR4** 节点号用于推理启动器的 `Z8_DRAM_INTERLEAVE`。 [Linux 7.0 DAX kmem](https://github.com/torvalds/linux/blob/v7.0/drivers/dax/kmem.c) · [推理启动器](CPU-PLACEMENT.md#启停本地模型)

```bash
mkdir -p "$HOME/z8-burnin"
sudo bash host/pmem-numa-report.sh | tee "$HOME/z8-burnin/numa-topology-$(date +%F-%H%M%S).log"
lsmem -o RANGE,SIZE,STATE,NODE,ZONES
```

## I4 在正式系统复用 PMem

在 T3 把四个 namespace UUID 与两份填好的 env 文件存到独立介质。正式 Xubuntu 26.04.1 启动后用 `ndctl` 对照。BIOS 已应用的 goal、namespace 和已格式化的 DAX 模型卷跨系统保留。

下方命令配置通用条带服务。若 I6 先用两个本地卷，I4 跳过 `z8-pmem-model.service` 的启用，用前面 T3 的两条 `mount` 命令复用两卷；重启后重新挂载。kmem 仍按下方步骤独立上线。完成两卷的前台实测后再选正式挂载方式和推理服务依赖。

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
sudo systemctl enable z8-pmem-kmem.service
# 采用条带卷时启用。
sudo systemctl enable z8-pmem-model.service
```

在 `pmem-kmem.env` 中填两路 devdax namespace UUID，照抄 T3 验证过的 `Z8_MEMMAP_ON_MEMORY` 和 `Z8_ENABLE_DEMOTION`。重启后用 `sudo daxctl list`、`numactl -H` 和 `journalctl -b -u z8-pmem-kmem` 核对 kmem。条带按 `findmnt -M /srv/pmem-model` 和 `journalctl -b -u z8-pmem-model` 核对，分卷测试按两个 `/srv/pmem-local*` 挂载点核对。仓库已有的推理服务依赖 `/srv/pmem-model`。

## 量 UPI 与 pinned memory

HP 白皮书记载 Z8 G4 在两颗 CPU 间布了两条 UPI，最高 10.4 GT/s/条。NASA 针对另一台双链路 Cascade Lake 的详细报告按每次传输 2 B，列出 41.6 GB/s 的单方向理论值。应用可用带宽会受协议与访问模式影响，本机拿 PCM 实测做预算。硬件负责在活跃 UPI 链路上路由，Linux 的 NUMA 策略选择 CPU 和内存节点。要同时用好两路 PMem，先做到 **每路的读取线程就近取 PMem、为该路的两张 GPU 准备本地 DDR4 staging**。两路可以同时搬大块数据，并给跨路 stage 交接、编译与内存分层留出链路。 [HP Z8 G4 白皮书，第 3 页](https://www.workstation4u.de/hp-z8-g4-technichalwhitepaper.pdf#page=3) · [NASA 双链路平台报告，§II.A](https://www.nas.nasa.gov/assets/nas/pdf/papers/NAS_Technical_Report_NAS-2022_01.pdf#page=3)

一次冷专家上传有两段。CPU 读 DAX 文件时，由 **reader 所在 CPU 与 PMem 归属** 决定读取是否跨 UPI。GPU 从 pinned 页取数据时，由 **DDR4 页与 GPU PCIe 根端口的归属** 决定 DMA 是否跨 UPI。DAX 读写 DDR4 staging 的过程中，reader 若在 staging 对侧，CPU 写入也会有跨路流量。冷专家全进 arena 后，文件布局对后续 decode 的影响主要来自文件 miss、Engram 或重载，继续上传则取决于 arena 和 bounce buffer 的位置。

| DDR4 staging 的物理位置 | 四张 V100 同时 H→D 时，跨 UPI 的 GPU 净数据估算 |
|---|---:|
| 每张卡都读其根端口这一侧的 DDR4 | 约 0 GB/s |
| 每张卡都均匀读两路 DDR4 | 约 7.88 GB/s/方向 |
| 两组显卡都只读对侧 DDR4 | 约 15.75 GB/s/方向 |
| 两组显卡都读同一侧 DDR4 | 约 15.75 GB/s，集中在一方向 |

这里用 PCIe 3.0 x8 每卡 `8 GT/s × 128/130 × 8 ÷ 8 ≈ 7.88 GB/s` 的编码后上限，两卡一组约 15.75 GB/s。某一方向的 GPU 净数据量是目标侧两张卡的实测 H→D 速率乘以它们从源侧读取的字节比例。协议、CPU 访问、缓存一致性、GPU peer 回退和 kmem 流量要通过计数器另看。用 `nvidia-smi topo -m` 和六对 peer 测试核四卡；Xolotl 按实测把同 socket 的两张卡排连续，日志看分段传输走 `peer` 还是 `pinned-host`。NVLink peer 可减少 GPU 交接占用的 host 链路。 [NVIDIA P2P 排查](https://github.com/NVIDIA/nccl/blob/master/docs/userguide/source/troubleshooting/gpu_troubleshooting.rst) · [Xolotl stage 传输](https://github.com/Indras-Mirror/Xolotl/blob/db25febda3e2869333d72eca6b17296142916a9b/tools/v41/engine/ds41_pipeline.cpp#L44)

`pinned-copy.cu` 在匿名映射上逐页写入，再调用 `cudaHostRegister`。按下面的 DDR4 节点运行，得到的是 **pinned DDR4 ↔ V100** 的链路基线。Linux 7.0 的 GUP 对 fsdax 文件映射的 `FOLL_LONGTERM` 请求返回 `EOPNOTSUPP`，快速 pin 路径也检查 fsdax folio。`devdax` 的页类型不同，CUDA 是否能注册还取决于映射和实际驱动，需单独验证。上线以 CPU `mmap` 或 `pread` 读 PMem、按引擎需要使用普通 DDR4 pinned staging 为基线。 [Linux 7.0 GUP 检查](https://github.com/torvalds/linux/blob/v7.0/mm/gup.c#L1200) · [Linux 7.0 folio 检查](https://github.com/torvalds/linux/blob/v7.0/include/linux/mm.h#L2411) · [CUDA 12.9 Host Register](https://docs.nvidia.com/cuda/archive/12.9.1/cuda-runtime-api/group__CUDART__MEMORY.html)

```bash
nvcc -O3 -std=c++17 -arch=sm_70 -Xcompiler=-pthread host/pinned-copy.cu -o pinned-copy
nvidia-smi topo -m
nvidia-smi -L
numactl -H

# 填实机 DDR4 节点号与每路的两张 V100 UUID。
d0=0
d1=1
pair0=GPU-REPLACE0,GPU-REPLACE1
pair1=GPU-REPLACE2,GPU-REPLACE3

# 保持 CPU 所在节点与 GPU 相同。每轮只改 pinned 页的放置。
measure_pair() {
    local label=$1 policy0=$2 policy1=$3 pid0 pid1 failed=0
    CUDA_VISIBLE_DEVICES="$pair0" numactl --cpunodebind="$d0" "$policy0" \
        ./pinned-copy 512 300 h2d > "${label}-socket0.log" & pid0=$!
    CUDA_VISIBLE_DEVICES="$pair1" numactl --cpunodebind="$d1" "$policy1" \
        ./pinned-copy 512 300 h2d > "${label}-socket1.log" & pid1=$!
    wait "$pid0" || failed=1
    wait "$pid1" || failed=1
    cat "${label}-socket0.log" "${label}-socket1.log"
    return "$failed"
}

# 另开终端。每次采样换文件名，先记录若干秒空闲，再执行其中一轮。
# sudo pcm 1 -csv=upi-local.csv
measure_pair local "--membind=$d0" "--membind=$d1"
measure_pair interleave "--interleave=$d0,$d1" "--interleave=$d0,$d1"
measure_pair cross "--membind=$d1" "--membind=$d0"
measure_pair socket0-only "--membind=$d0" "--membind=$d0"
```

**T3 先量 PMem 和 CPU 互访。** 在 kmem 上线前用 Intel MLC 的 `--bandwidth_matrix -R` 和 `--latency_matrix` 记录 DDR4 本地和跨路基线，同时用 PCM 观察两个方向的 UPI 峰值，避免受 T5 的 PCIe x8 吞吐上限限制。用 T3 已实际写过的 `burnin.bin` 做 `fio --readonly --ioengine=libpmem --allow_file_create=0` 读测，逐卷使用相同文件范围、线程数和读块，分别做顺序读与 4 KiB 随机读。比较一侧单独读、两侧各读本地、两侧各读对端，再对条带做两个 CPU 组读互不重叠的区段。先按推理的六颗物理核/路跑一轮，测最大带宽时再放开核心数。 [Intel MLC](https://www.intel.com/content/www/us/en/developer/articles/tool/intelr-memory-latency-checker.html) · [PMem fio 验机](BURN-IN.md#t3-pmem-100-app-direct-的专用检查)

**T5 量两条物理 UPI。** 保存 PCM 启动时的 `Max UPI link … speed`，结合 T3 的 CPU 远端读与 T5 的 `cross`、`socket0-only` 窗口检查两条链路各自有入站数据。按接收端把同一 socket 两条链路的入站字节相加、除以采样秒数，得到该方向的速率。另一端的入站是反方向。PCM 的出站利用率还含协议流量，可用于看饱和与两条链路是否明显不平衡。报告只取两个进程都在传输的稳态窗口，排除注册、预热与尾部退出。需要测 PMem 每路读写量时另跑一轮 `pcm-memory 1 -pmm -csv=pmem.csv`，避免监控程序竞争相同计数器。 [Intel PCM 入站与链路利用率讨论](https://github.com/intel/pcm/discussions/555) · [Cascade Lake UPI 计数事件](https://perfmon-events.intel.com/platforms/cascadelakex/uncore-events/uncore/)

**I6 固定引擎做两轮对照。** 第一轮只换文件布局，两个本地卷与跨路条带均用同一 GGUF、固定 GPU 顺序、CPU 集合和两路 DDR4 交错。两布局复用相同 namespace 时要串行做，切换前停服务和卸载，并从原始 revision 重新下载或还原已校验文件。第二轮在同一布局下改 staging。引擎有独立缓冲时，在每个 stage/rank 创建并首次触及 staging 之前设置对应 DDR4 节点的内存策略，再注册 CUDA pinned；共享 arena 继续交错。Xolotl 当前在单进程循环初始化各 stage，要有按 stage 的内存策略需要引擎内做到分配时定节点；全进程的 `numactl` 仅能给共同策略。记录 `numastat -p PID`、`/proc/PID/numa_maps` 和引擎的 staging 分配统计。101 GiB 均分约 50.5 GiB/路，各还有名义 45.5 GiB，再扣系统与构建。

两轮都测新进程的 load-to-ready、Engram 首读与暖读、工具返回后 TTFT、稳态 decode，再固定一项 Buck2 构建复测尾延迟，同时记录 H→D 字节、PMem 读量和每方向 UPI。TTFT 回放固定请求、上下文和前缀命中状态。采用两卷的依据是相同请求上延迟或吞吐的可复现改善，并确认分片、下次启动、容量和 CPU 分核配置都可复用。记录两路各自的 `df` 余量，另一套 1Cat 文件也要按分片大小逐卷核算。 [Linux NUMA policy](https://docs.kernel.org/admin-guide/mm/numa_memory_policy.html) · [1Cat cold expert staging](https://github.com/1CatAI/1Cat-vLLM/blob/main/benchmarks/deepseek_v41/HANDOFF.md#G2-cold-expert-staging-ring)

### I7 让推理与编译分用物理核

保留 HT，始终从普通任务中排除推理核的 HT 伙伴。推理服务启动时再划出主线程，停止后只归还主线程。推理按实测的两路 DDR4 节点分配，构建侧可以使用慢层。按 [CPU 分核手册](CPU-PLACEMENT.md) 配置、观察实际引擎 PID 和对照测试。
