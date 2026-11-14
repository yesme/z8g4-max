# HP Z8 G4 双路工作站装机与部署计划

2026 年 11 月 15 日 · v2.16 实施版

主机名 `jackywang-xubuntu-max`，登录用户 `jackywang`。按双 8269CY、192 GiB DDR4、12×128 GiB PMem、4×V100 16 GB 和给定的槽位、SATA 接法部署。P4618 的 RAID0/XFS 承担系统、工作树和 Buildbarn 热层。HC620 + P4800X 八分区组成可重建的冷 CAS。模型从首装开始直接放在 App Direct。PMem 从 T3 起使用正式条带。

将本仓库克隆或解压到目标 Linux 的普通用户目录。所有相对路径的操作默认从 `z8-kit` 根目录执行。先阅读本节和第 2–3 节，再打开相应的命令页。

- [F10 菜单、DIMM 位置、SATA 接线和起转](z8-kit/host/BIOS.md) · [安装器和系统盘配置](z8-kit/host/INSTALL.md)
- [拷机命令、时长和错误判读](z8-kit/host/BURN-IN.md) · [App Direct、DAX、kmem 和 pinned DMA](z8-kit/host/PMEM.md)
- [BIOS、PMem、SSD 和各板卡的固件更新步骤](z8-kit/host/FIRMWARE.md)
- [八分区建池、启动单元、缺盘和换盘](z8-kit/storage/README.md) · [Buildbarn 服务和两台 Buck2 客户端](z8-kit/buildbarn/README.md)
- [1017 构建、模型版本和启动参数](z8-kit/inference/README.md) · [CLI 工作树](z8-kit/harness/README.md) · [远程图形和 SSH](z8-kit/remote/README.md)

## 已定的部署配置

| 部分 | 配置 |
|---|---|
| 操作系统 | Ubuntu Server 26.04.1 安装 md RAID0，再装同版 `xubuntu-desktop`。FIT 1 GiB ESP + 8 GiB `/boot`，P4618 512 KiB md chunk + XFS reflink，Dracut 生成 initramfs |
| 主板与驱动 | 纯 UEFI，Secure Boot、ASPM、SATA 电源管理关，NUMA 和 HT 开，SNC 关，VT-x／VT-d 开。Ubuntu GA 7.0 + R580 专有驱动。P620 显示，四张 V100 计算 |
| 内存 | 每路 258 GiB fsdax 合并成 2 MiB 条带、ext4 DAX。每路剩余 devdax 分别转 kmem，启用冷页下沉。推理在两路 DDR4 交错，每路 6 核，HT 伙伴留空 |
| 冷库 | P4800X 7×160 GiB + 余量全给 p8。七组 dm-zoned → ZFS RAIDZ1。归档和 Buildbarn 冷 CAS 都用 `zstd-3`。冷 CAS 设 1 MiB recordsize，只缓存元数据。池启用 autotrim |
| 构建 | Z8 本机 Buildbarn 512 GiB 冷 CS + 64 GiB XFS 热 CS。Mac 独立 64 GiB 本地 CAS。Buck2 本机编译，远程 worker 仅在有实际 RE 任务时启用 |
| 推理 | llama.cpp v1.0.0，ISTA 1017 IQ2_XXS + IQ4_NL Engram，四卡、2×8K、8 GiB GPU 专家缓存；显存限制时减缓存或留单槽，单槽无法使用时切 Xolotl Buster |
| 远程 | AX210 Wi-Fi、DHCP 保留、SSH/tmux，独立图形用 xrdp/Xfce，控制本机桌面用 P620 的 X11/NVENC + Sunshine/Moonlight |

实机时间用于确认五个结果。T1–T5 确认二手硬件、实际枚举、起转和四卡 peer，I1 确认 FIT 冷启动可找到 RAID0，I4 确认 ZFS 老化写入和缺盘行为，I5 确认 Buck2 缓存与物化，I6–I7 确认推理显存、工具闭环和实际混合负载。只有未通过的项目进入对应排查或回退。

## 1. 测试 → 正式安装

### 第一阶段 · BIOS 设置和硬件测试

顺序是 **CPU → DDR4 → PMem → 存储 → 算力坞**。准备 Memtest86+ U 盘和一套装在独立 USB SSD 的 Xubuntu 26.04.1 临时系统。T3 在同一系统用 Canonical 官方归档的三份 `.deb` 安装 `ipmctl`，用 26.04 软件源安装 `ndctl` 和 `daxctl`。测试日志和盘序列号留在独立介质。换件前关机并断交流电。 [PMem 工具准备](z8-kit/host/PMEM.md)

固件随验机阶段处理。T1 最小配置稳定 POST 后核 HP BIOS 与 ME，T3 在提交 App Direct goal 前逐条核 PMem，T4 在 SSD 裸盘压测前核固件，T5 记录每张 V100 的 VBIOS。三星 DDR4 和无源直通板直接做硬件测试。 [固件更新条件与命令](z8-kit/host/FIRMWARE.md)

| 顺序 | 这一步接什么 | 做到什么再继续 |
|---|---|---|
| **T1 · CPU、BIOS 与联网** | 双 8269CY、散热器和风道、12 条 DDR4、槽 4 P620、槽 7 AX210 和天线、显示器、Live U 盘与临时 USB SSD | F10 设纯 UEFI、NUMA、AHCI、虚拟化等。Live 用 AX210 先连 Wi-Fi，核 DHCP、DNS 和 APT，再准备临时系统。双路 CPU 依次跑通用压力和 AVX-512 VNNI，记录满载频率、温度与降频事件。 [首次 Live 联网](z8-kit/host/BURN-IN.md#首次-live-wi-fi-与临时验机系统) · [CPU 拷机](z8-kit/host/BURN-IN.md#cpu-拷机) |
| **T2 · DDR4** | 沿用 T1 硬件，换用 Memtest86+ U 盘，再换回临时 Linux | 每路 96 GiB、共 192 GiB。Memtest86+ 默认测试集四个完整 pass，跳过 Rowhammer。再跑 Linux 144 GiB、4 小时，比较前后的 ECC 与 CPU 硬件事件。 [怎么读硬件错误](z8-kit/host/BURN-IN.md#怎么读硬件错误) |
| **T3 · PMem** | DDR4 原位，CPU0/CPU1 各往六个空槽加 PMem | F10 查条和临时解冻。由 Xubuntu 的 `ipmctl` 提交 App Direct goal，BIOS 在重启时应用。验混插 DDR4、DAX 持久性，测两路 kmem 的冷启动上线时间，再逐路确认 DDR4 到 PMem 慢节点的下沉。 [PMem 配置](z8-kit/host/PMEM.md#t3-配置-app-direct) · [kmem 冷启计时](z8-kit/host/PMEM.md#t3-记录-kmem-冷启动时间) |
| **T4 · 存储** | 槽 1 加 P4618，确认 Gen3 x8 上行、两个 x4 下行和两个各约 3.2 TB 的 NVMe 端点，再加槽 5 的 P4800X。HC620 分 1 → 4 → 7 块接 SATA0–6，光驱接 SATA7 | 查 NVMe 健康、SATA 冷启、每盘 `host-managed` 与 zone 类型。七盘并行 SMART 长自检，复验 AX210 与七盘同跑。 [P4618 链路检查](z8-kit/host/BURN-IN.md#p4618-链路与双控制器) · [七盘慢扫](z8-kit/host/BURN-IN.md#七块-hc620-并行慢扫) |
| **T5 · 算力坞** | 临时 Linux 先装 NVIDIA 显卡驱动。主机硬件通过后断电，槽 2/3 装直通卡，接 V100 | 逐卡 → 每槽两卡 → 四卡，验 Gen3 x8、六对 NVLink P2P、NCCL、单卡/四卡拷机、pinned H→D。测试完关机、断开 V100，转正式安装。 [拷机手册](z8-kit/host/BURN-IN.md) |

### 第二阶段 · 正式安装和上线

| 顺序 | 装什么与验证方式 |
|---|---|
| **I1 · 操作系统** | 断开 V100 与数据盘，直接用 Ubuntu Server 26.04.1 按 CIDATA 配置建 FIT 和 P4618 RAID0/XFS，再安装 `xubuntu-desktop`。核首启、Dracut 和救援。 [系统盘安装](z8-kit/host/INSTALL.md) |
| **I2 · 远程入口** | AX210 连 Wi-Fi，设开机自动连接和 DHCP 地址保留，再验 SSH 公钥、tmux 与 xrdp/Xfce。Sunshine 的 P620 硬件编码放 I3。 [远程入口](z8-kit/remote/README.md) |
| **I3 · NVIDIA 显卡驱动与复接 V100** | V100 仍断开，在 Xubuntu 装 `nvidia-driver-580`。这是本方案为 P620 和 V100 选用的 NVIDIA Linux 显卡驱动。重启后用 P620 验桌面、Sunshine/NVENC 和 SSH，再关机接回 V100，核四卡枚举、NVLink 与快速 CUDA/NCCL。 [驱动安装和锁分支](z8-kit/host/INSTALL.md#安装并锁定-nvidia-显卡驱动) |
| **I4 · 存储与 PMem** | 接回已慢扫的盘，首次划 P4800X 八分区，建七个 dm-zoned target 与 RAIDZ1，按 GUID 导入和挂载。跑持续写、ZFS scrub、两种缺盘冷启和恢复。按 T3 留下的 namespace UUID 恢复 DAX 模型卷和 kmem。 [存储](z8-kit/storage/README.md) · [PMem](z8-kit/host/PMEM.md) |
| **I5 · Buildbarn 与 Buck2** | Z8 和 Mac 各启本机缓存。验证各自 AC/CAS、按需物化与断网构建。Z8 上按需启用 Linux worker。 [Buildbarn](z8-kit/buildbarn/README.md) |
| **I6 · 推理与 harness** | 用 llama.cpp v1.0.0、四张 V100 和一套 PMem 上的 1017 权重，验证双槽、工具闭环和实际 harness。OMP、Pi、DSH 可用已有密钥直连 DeepSeek 官方 API。各 CLI 验证账号、模型和工作树。 [推理](z8-kit/inference/README.md) · [CLI](z8-kit/harness/README.md) |
| **I7 · 正式联调与恢复** | 冷启动检查 SSH、存储链和远程显示。采用每路 6 核分配，验证本地 DeepSeek 启停时让出和归还核心，然后做一次 8 小时的编译、推理和 I/O 混合负载。保存引导、盘表、GUID、驱动/内核版本、服务配置及项目数据的独立副本。 [CPU 分核与启停](z8-kit/host/CPU-PLACEMENT.md) · [整机拷机](z8-kit/host/BURN-IN.md) |

DIMM 上的 **PMem100** 在 T3 验，测试时提交的 goal 和 namespace 供正式系统沿用。槽 5 的 **P4800X** 是 NVMe SSD，在 T4 随 HC620 一起做裸盘检查，正式安装 I4 再用于建池。

[镜像和校验文件](https://www.cdimage.ubuntu.com/xubuntu/releases/26.04/release/) · [Xubuntu 26.04 支持周期](https://xubuntu.org/release/26.04/)

## 2. 槽位、BIOS 与供电

| HP 槽号 | 设备 |
|---|---|
| 1 | P4618，`Bifurcation = Auto`，双 CPU 且不装 Thunderbolt 3 卡时为 Gen3 x8 |
| 2 | x16→x8/x8 直通卡，接两张 V100 |
| 3 | x16→x8/x8 直通卡，接两张 V100 |
| 4 | P620，主显示 |
| 5 | P4800X，Gen3 x4 |
| 6 | 空，被 P4800X 挡住 |
| 7 | AX210，蓝牙经内部 USB |
| SATA0–6 / SATA7 | 7×HC620 SATA / 原装光驱 |

F10 首装使用 **纯 UEFI，Legacy/CSM 和 Secure Boot 都关闭**。Fast Boot 关、SATA Controller Enable / RAID Mode Disable、SATA0–7 打开、Primary Graphics Slot 4、Slot 2/3 Bifurcation x8/x8、NUMA 和 HT 开、SNC 关。DDR4-only 先在 CPU0 和 CPU1 **各**插 DIMM 1/3/5/8/10/12。混插时 DDR4 留原位，CPU0 和 CPU1 各往 DIMM 2/4/6/7/9/11 加 PMem，再配置 App Direct。槽号以 CPU0/CPU1 各自的主板丝印为准。 [F10 配置手册](z8-kit/host/BIOS.md) · [HP QuickSpecs，双路 192 GB 配置](https://h30434.www3.hp.com/psg/attachments/psg/Business-PC-Workstation-POS/44704/1/Z8%20G4%20Quickspecs%20v67.pdf#page=22) · [HP Optane 白皮书，24 条混插](https://h10032.www1.hp.com/ctg/Manual/c06527302.pdf#page=22)

**内网首装保留 VT-x、VT-d、默认 PCIe ACS、Intel ME 和 HP Sure Start 的固件恢复。** VT-x 给 KVM 等虚拟机提供 CPU 硬件加速，裸机 Buck2 和 1017 的性能继续按实测记录。关闭不用的 AMT、PXE、TXT 和 HP Sure Recover，保持设备级 DriveLock 未启用。新装 XFS 根若没有使用 TPM 解锁或密钥，可关闭 TPM State。接坞后先记录真实 NVLink 和 PCIe 拓扑，需使用裸机 PCIe P2P 时，按 NVIDIA 要求用 GRUB 单次关闭 Intel IOMMU 做该路径测试。 [F10 各项取值](z8-kit/host/BIOS.md#内网主机的安全与虚拟化设置) · [HP 服务手册](https://kaas.hpcloud.hp.com/pdf-public/pdf_6792418_en-US-1.pdf) · [NVIDIA 多 GPU 指南](https://docs.nvidia.com/cuda/cuda-programming-guide/03-advanced/multi-gpu-systems.html#host-iommu-hardware-pci-access-control-services-and-vms)

按 Esc → F10 后，在 `Advanced → Secure Boot Configuration → Configure Legacy Support and Secure Boot` 选择 **Legacy Support Disable and Secure Boot Disable**。保存后如出现 Boot Mode Change，输入屏幕确认码。保留 `UEFI Boot Order`，用 F9 选 Memtest86+、安装盘或 FIT 的 UEFI 启动项。在 `Boot Options` 把 `After Power Loss` 设为 Off，按算力坞接线记录手动上电。在 `Slot Settings` 保持槽 1 的 Bifurcation 为 Auto，槽 2/3 改为 x8/x8（若固件提供该项），槽 5/7 保持 Enable。保存后先从 P620 看一次 POST，再进入 Linux 核验。 [HP F10 设置](https://support.hp.com/ee-en/document/ish_9642671-9641393-16)

```bash
test -d /sys/firmware/efi && echo 'UEFI boot'
LC_ALL=C mokutil --sb-state  # SecureBoot disabled
sudo dmidecode -t bios -t memory
lscpu -e=CPU,SOCKET,NODE,CORE
numactl --hardware
lspci -Dnn -tv
sudo nvme list -v
```

机箱原生有 **4 个 3.5 英寸位、2 个深度上限 175 mm 的 5.25 英寸位，以及独立的 9.5 mm 薄光驱位**。四块 HC620 用原装托架，另外三块需要双 5.25 英寸的三盘架或独立固定风冷盘架。买盘架前量机箱可用深度，算上盘架本体、SATA 数据插头和供电弯折；如果使用带背板的盘架，要求三条独立 SATA 直通，实测可透传 ZAC。原装光驱若占用 5.25 位，先确认能否放进薄光驱位，否则给后三块用外置固定盘架。SATA 数据口仍是主板 0–7。HP 的 1700 W 规格取决于输入电压和 PSU 料号，按高压档接线并查铭牌。 [HP QuickSpecs，第 6、8 页](https://h30434.www3.hp.com/psg/attachments/psg/Business-PC-Workstation-POS/44704/1/Z8%20G4%20Quickspecs%20v67.pdf)

HP 的公开 F10 手册未确认 Z8 G4 能让硬盘分批起转，供电按七盘可能同时起转估算。按 WD 表 16 较高的采样峰值相加，12 V 约 **13.93 A**，5 V 约 **3.57 A**，光驱另计。先做 1/4/7 盘断电冷启，确认每次都能认盘。若单盘完全不起转，按 BIOS 手册查 SATA 供电和 P3。若七盘都能稳定冷启，P11 和 PUIS 可以跳过。 [SATA 冷启与名词解释](z8-kit/host/BIOS.md) · [WD HC620 SATA 手册](https://documents.westerndigital.com/content/dam/doc-library/en_us/assets/public/western-digital/product/data-center-drives/ultrastar-dc-hc600-series/product-manual-ultrastar-dc-hc620-sata-spec.pdf)

四卡以算力坞独立供电为基线，记录底板、电源及线束规格、接地与开关顺序。按 GPU 300 W 上限估算，四卡峰值预算约 1.2 kW，泵、风扇和底板另计。每卡 360 冷排仍要确认 HBM、VRM 的接触与风道。 `nvidia-smi topo -m`、`nvidia-smi nvlink -s`、CUDA P2P 与 NCCL all-reduce 要在最终走线下通过。 [NVIDIA Tesla V100 数据表](https://images.nvidia.com/content/technologies/volta/pdf/tesla-volta-v100-datasheet-letter-fnl-web.pdf) · [NVIDIA NCCL 排查](https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/troubleshooting/gpu_troubleshooting.html)

## 3. Xubuntu 与存储

### 引导与 P4618

- I1 用 [Server 安装配置](z8-kit/host/root-storage.yaml.example) 一次创建 FIT 和 P4618 的布局。用硬件 `ID_SERIAL` 固定三块设备，写入前在安装器控制台确认。FIT 上的 GRUB 读入内核与 Dracut 初始化镜像，后者组装 P4618 根阵列。 [安装命令](z8-kit/host/INSTALL.md)

- `/srv` 是标准的本机服务数据目录，默认由根 XFS 承载。手动创建 `/srv/work/jackywang` 和 `/srv/buildbarn/tiered`。项目、`buck-out`、Buildbarn AC、CMS、CAS 索引和热读缓存落 P4618。单独在 `/srv/pmem-model` 挂 PMem ext4 DAX，先用 `findmnt -M` 查该挂载点再写入模型。P4618 的 XFS 在安装配置里显式设 `crc=1,reflink=1`，首启用 `xfs_info /` 验证。 [安装命令与目录](z8-kit/host/INSTALL.md) · [文件系统目录标准](https://specifications.freedesktop.org/fhs/latest/srv.html)
- 首启为根 XFS 写 `noatime,nodiscard`，md 实测透出 discard 时用周期 TRIM。FIT 的 `/boot`、ESP 用 `noatime`，从周期 TRIM 排除。PMem 模型 ext4 用 `dax=always,noatime,data=ordered,nodiscard`。两个 ZFS 单元按依赖链以 `rw` 挂载，压缩、atime 和同步写策略保存在 dataset 属性。 [全机挂载参数及核对命令](z8-kit/host/MOUNTS.md) · [fstab 样例](z8-kit/host/fstab-boot.example)

### HC620 与 P4800X

Xubuntu 26.04.1 的 Linux 7.0 块层用 zone write plugging 保持同一顺序区的写入次序。七块 HC620 保留系统默认 I/O 调度器。按 SATA0–6 记录 `host-managed`、两类区和实际调度器，命令见存储手册。 [Zoned Storage 写顺序](https://zonedstorage.io/docs/linux/sched)

P4800X 的 `p1–p7` 各 160 GiB，分别作为七个 dm-zoned 常规设备。七个 mapper 做 RAIDZ1，理想数据容量约 84 TB / 76.4 TiB。`p8` 用尽剩余约 **277 GiB**，作为 special vdev，承载元数据、符合阈值的小块和 ZIL。OpenZFS 2.4.1 在没有独立 SLOG 时，优先从 special 的内嵌日志区分配 ZIL，空间不足时可用 special 的普通空间，再回退到 RAIDZ1。按默认 metaslab 算法，p8 预计自动划 **一个 2 GiB 的内嵌日志区**。这个容量随 vdev 几何计算，建池命令只声明 `special`，无需增加第九个分区。 [OpenZFS 2.4.1 日志分配](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/zfs/zio.c#L4249) · [metaslab 大小算法](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/zfs/vdev.c#L2766)

HC620 七盘按 SATA 4Kn、256 MiB 区验机。I4 在确认可清空的 P4800X 上清掉旧分区表，直接新建 GPT 八分区。脚本读取逻辑扇区大小来做 1 MiB 对齐。p1–p7 各 160 GiB，给七组 dm-zoned；p8 使用剩余空间，给 ZFS special vdev。dm-zoned 向 ZFS 提供 4 KiB 块设备。 [P4800X 八分区命令](z8-kit/storage/README.md#新建-gpt-八分区)

每块 HC620 盘头有 **524 个可随机读写的 `CONVENTIONAL` 区，共 131 GiB**。双设备 mapper 的前台缓冲走 P4800X。HC620 第 0 区存成员超级块，其余健康普通区纳入数据容量。后台回收分配不到顺序目的区时才尝试使用盘头普通区，所以这部分可以长期基本闲着。后段的 16 个顺序预留区另由 `dmzadm` 默认管理。 [盘头区用途与实机核对](z8-kit/storage/README.md#hc620-盘头随机写区在混合方案里的用途) · [WD HC620 区布局](https://documents.westerndigital.com/content/dam/doc-library/en_us/assets/public/western-digital/product/data-center-drives/ultrastar-dc-hc600-series/product-manual-ultrastar-dc-hc620-sata-spec.pdf#page=23)

**`dmzadm --format` 仅在 I4 首次配对时运行一次。** 它重置 HC620 的顺序区写指针，并在配对的 P4800X 分区和 HC620 上写 dm-zoned 元数据，原有数据按不可保留处理。T4 裸盘验机与日常启动均跳过该命令。`hybrid.tsv` 只保存配对，开机用 `dmzadm --start` 读取已有元数据，再按依赖导入和挂载 ZFS。 [单组初始化命令](z8-kit/storage/README.md#首次初始化每组-dm-zoned)

存储设备沿用 Linux 7.0 默认 I/O 队列。池开启 `autotrim`，OpenZFS 2.4.1 保持 32 TXG、32 KiB/128 MiB 过滤及切分参数，mapper 的设备能力另记 4 KiB/256 MiB。ARC 按 DDR4 并行负载设 2–16 GiB，dirty data 和 TXG 周期沿用默认。 [OpenZFS TRIM 参数](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/zfs/vdev_trim.c#L94)

数据集采用 `ashift=12` 的池、`compression=zstd-3`、`sync=standard` 与 `logbias=latency`。父数据集保留 `special_small_blocks=24K`，`z8data/data/buildbarn` 用 `recordsize=1M` 和 `special_small_blocks=0`。CAS 的最终数据块落 RAIDZ1，元数据优先落 special，带同步语义的写入可先由 p8 上的 ZIL 确认。异步大文件持续吞吐继续按实际盘侧和 dm-zoned 回收测。special 的默认 25% 是元数据保留阈值，和日志区的大小独立。 [建池与同步写验证](z8-kit/storage/README.md) · [OpenZFS 2.4 数据集属性](https://openzfs.github.io/openzfs-docs/man/v2.4/7/zfsprops.7.html) · [OpenZFS 2.4 参数](https://openzfs.github.io/openzfs-docs/man/v2.4/4/zfs.4.html)

冷 CAS 从 `z8data/data` 继承 `compression=zstd-3`，本地设 `primarycache=metadata`。Buildbarn 对 CAS chunk 的 Zstd 编码发生在写块文件之前，ZFS 再按文件系统记录判断能否进一步压缩。重复 blob 读取由 P4618 热层承担。 [冷 CAS 配置与源码](z8-kit/storage/README.md#冷-cas-压缩)

Optane 的写缓冲吸收 SMR 随机写，special vdev 接手 ZFS 元数据。P4800X 同时保存七个映射的持久元数据与池 special，整卡掉线会让冷池失去共享底座。冷池用作可重建的构建缓存。根盘、源码与构建配置在 P4618，恢复源在另一物理设备。

**强制启动顺序**是 `z8-dmzoned.service → z8-zpool.service → data.mount → data-buildbarn.mount → z8-buildbarn.service`。`storage/README.md` 有分区、mapper 标签、建池命令及 systemd 安装步骤。按 SATA by-id 和 p1–p7 逐一匹配，等设备最多 90 秒；每个 mapper 校验实际背盘。p8 存在且至少六个 mapper 有效才尝试按 GUID 导入。挂载成功后才会启动 Buildbarn。正常停机逆序，池未导出时脚本拒绝拆 mapper。单 HC620 缺席可按 RAIDZ1 降级，P4800X 整卡缺席则只停存储链，主机可 SSH。

### 首次部署与以后每次启动

首次部署先复制样例 `hybrid.tsv.example` 和 `storage.env.example`，把 SATA 口对应的七个 ATA 整盘 by-id 填到七行。例如 SATA3 对应 `hc620-3` 和 P4800X p4。所有 NVMe 分区统一使用同一根 by-id。先对确认可清空的 `hc620-0` 对应设备做一次初始化和启动，核 mapper 下只有对应的一块 HDD 和 p1 后，再处理另外六对。建池前用 `zpool create -n` 核对预览，建成后把 `zpool list -H -o guid z8data` 的结果写进 `Z8_POOL_GUID` 并导出。 [建池命令](z8-kit/storage/README.md#建池命令)

I4 安装挂载单元后运行 `sudo systemctl start data-buildbarn.mount`，自动拉起父挂载、GUID 导入和 dm-zoned。确认 `findmnt -M /data/buildbarn` 显示 `z8data/data/buildbarn`，完成持续写、scrub 和两种缺盘演练。I5 装好 Buildbarn 后执行 `sudo systemctl enable --now z8-buildbarn.service`，从此由它随开机沿链拉起存储。worker 是下一层。使用 `After=` 保证等待上一级完成，配合 `BindsTo=` 把上一级失效传下去。数据集用 legacy mount，池用 `cachefile=none`，避免同一池被两条引导路径同时接管。Buildbarn 启动前再次核数据集和 P4618 的 XFS 热层。

```bash
sudo journalctl -b -o short-monotonic -u z8-dmzoned -u z8-zpool \
    -u data.mount -u data-buildbarn.mount -u z8-buildbarn --no-pager
sudo zpool status -P z8data
findmnt -M /data/buildbarn -o SOURCE,TARGET,FSTYPE
ss -ltn 'sport = :8980'
```

停机换盘从 service 链发起停止，等 Docker 退出、两个 mount 卸载和 zpool export 完成才拆 mapper。断电演练时先模拟单 HC620 缺席，重启看六个 mapper 和池的 DEGRADED 状态，再接回原盘原分区配对并等 resilver。整张 P4800X 缺席的冷启，预期启动链止于 dm-zoned，`/data/buildbarn` 无挂载且 8980 无监听，从 SSH 查看日志。永久换单盘按旧 vdev GUID 替换并更新对应 by-id。P4800X 永久故障后重建冷 CAS 时，同时换一套 P4618 的 Buildbarn 状态目录。 [停止与恢复命令](z8-kit/storage/README.md)

## 4. DeepSeek-V4.1-Flash-1017

### 内存与模型放置

| 层 | 放置 |
|---|---|
| 四卡 HBM（64 GiB 标称） | dense、attention、活跃 KV 和 8 GiB 合计热专家缓存 |
| 两路 DDR4（192 GiB） | 各 96 GiB。推理从两个 DDR4 节点交错分配；按引擎所需分配 pinned DMA 缓冲。系统、Buck2 保留本地优先 |
| App Direct fsdax（2×258 GiB） | 2 MiB dm-stripe，约 508 GiB 块设备容量，ext4 DAX，挂 `/srv/pmem-model`。存一套 GGUF、Engram 与 tokenizer |
| 两路剩余 App Direct | 各自以可迁移 kmem 上线，启用 memmap on memory 和冷页下沉。活跃推理 KV 由引擎分配 |

**NUMA 固定开、SNC 关。** Z8 G4 主板有两条 UPI，最高 10.4 GT/s/条。共享 arena 交错避免单侧 96 GiB 先耗尽。DAX 文件通过 CPU 访问，普通 DDR4 做 CUDA staging。每路留最后 6 个物理核的主线程给推理。推理运行时普通任务用 80 个逻辑 CPU，停止后回到 92 个；推理核的 HT 伙伴始终留空。 [HP 白皮书，第 3 页](https://www.workstation4u.de/hp-z8-g4-technichalwhitepaper.pdf#page=3) · [PMem 配置](z8-kit/host/PMEM.md) · [CPU 分核](z8-kit/host/CPU-PLACEMENT.md)

### 推理上线顺序

1. **部署 llama.cpp v1.0.0。** CUDA 12.9.1 编译 SM70，固定 ISTA IQ2_XXS + IQ4_NL Engram。四卡 layer split、两槽各 8K、专家缓存 8192 MiB、ubatch 32，CPU miss share 0。两路同时做一次真实工具回合。首次验前缀走固定答案、项目标记与实际命中 token；通过后由受信任的客户端开启复用。活跃 KV 使用引擎默认布局。 [固定版本与命令](z8-kit/inference/README.md#llamacpp-v100-主服务)
2. **显存压力才降级。** 先将专家缓存减到 4096 MiB；第二槽仍挤不下时保留一个 8K 槽。单槽若仍无法跑通，或实际工单速度无法使用，切 Xolotl Buster 四卡单用户，复用同一份 GGUF。 [Xolotl 回退](z8-kit/inference/README.md#xolotl-buster-单用户回退)
3. **1Cat 只用于有明确需求的长上下文。** #1277 的 512K 成绩用 4×32 GiB，和本机 4×16 GiB 的预算不同。原版 Strata 的 1017 包未列 SM70，Xolotl 提供 Buster 构建路径。upstream vLLM 1017 公版配方需至少 8×80 GB。 [1Cat 上游实测](https://github.com/1CatAI/1Cat-vLLM/blob/main/benchmarks/deepseek_v41/HANDOFF.md) · [Strata 1017 支持](https://github.com/Niko1221/Strata/blob/main/docs/DEEPSEEK41.md) · [vLLM 1017 配方](https://github.com/vllm-project/vllm/blob/main/recipes/models/deepseek-ai/DeepSeek-V4.1-Flash.yaml)

I6 放行看 8K 槽下的 20 次连续工具往返、SSE、项目标记和零 OOM/Xid。两路都能流式推进就保留并发。I7 跑一次正式配置的 8 小时混合负载并记录 p95 TTFT、decode 和构建完成时间。 [推理放行](z8-kit/inference/README.md#i6-推理放行)

## 5. 多 CLI 工作环境

用 `jackywang` 登录，仓库放 `/srv/work/jackywang/<project>`。各项目或分支用自己的工作树和 tmux 会话；有不同人的凭证或项目访问边界时用不同 Unix 账户。各 CLI 先验证模型列表和原生沙箱，再放进 tmux。项目级权限走各工具的原生审批模式。`harness/agent-session.sh` 启动指定 CLI，已有会话就接回。

| CLI | 账号 / 模型验收 | 安装与模型依据 |
|---|---|---|
| Codex | ChatGPT 登录或独立 API key。查 `/model`，API 文档的四个 ID 为 `gpt-6-astra`、`gpt-6.1-sol`、`gpt-6.1-terra`、`gpt-6-luna`，账户可用性以 CLI 为准；无头登录查官方设备授权流程 | [模型](https://learn.chatgpt.com/docs/models) · [认证](https://learn.chatgpt.com/docs/auth) · [四个 ID](https://developers.openai.com/api/docs/guides/latest-model) |
| Claude Code | Fable、Opus、Sonnet、Haiku 用 `/model`，记录实际 alias 解析和套餐权限 | [Claude Code 模型配置](https://support.claude.com/en/articles/11940350-claude-code-model-configuration) |
| Antigravity | `agy models` 列出账号可用 ID。官方列 Gemini 4 Carbon、Argon、Hydrogen。Carbon 取决于 Ultra 或企业权限，Argon 可用符合条件的付费 Pro、Ultra 和企业账号，Hydrogen 覆盖免费档。选独立模型运行各项目 | [CLI](https://antigravity.google/docs/cli/overview/) · [模型与套餐](https://antigravity.google/docs/models?hl=en) |
| Grok Build | `grok`，官方 Build 产品页明确提供 Grok 4.7，安装后核对该账号的实际模型与额度 | [Grok Build](https://x.ai/build) · [CLI 文档](https://docs.x.ai/build/overview) |
| Muse Code | 官方 Linux CLI；Muse Wonder Full、Wonder、Spark 按地区和套餐分别验证 | [Meta 安装及模型](https://dev.meta.ai/docs/overview) |
| Kimi Code | 用官方 CLI 登录，验证 K3.1 Pro、K3、K2.8 Preview。K2.8 Preview 的 API 别名在官方页列为 `kimi-for-coding` | [Kimi Code 文档](https://www.kimi.com/code/docs/en/) |
| ZCode / OpenCode | 首测官方 ZCode 3.18.0，统一 `zcode` 带 TUI，官方仓库有 Linux CLI 构建和分发路径。若登录或模型不通，用 OpenCode + Z.ai Coding Plan provider；分别确认 GLM-5.3 和 GLM-5.3-Flash 对该账号可用 | [ZCode 官方仓库](https://github.com/zai-org/ZCode) · [OpenCode providers](https://opencode.ai/docs/providers/) |
| Qoder | 国内 CLI `qodercn`；官方 CN CLI 文档列 Qwen3.8-Max，另在账号 `/model` 查 Qwen4-Max-Preview 和 Qwen3.8-Flash-Next。IDE 选项不能作为 CLI 已开通的证据 | [安装](https://docs.qoder.cn/cli/installation) · [CLI 模型](https://docs.qoder.cn/en/cli/models) |
| OMP / Pi / DSH | 直连 DeepSeek 官方 API。OMP/Pi 用 `deepseek/deepseek-flash`，DSH headless 用默认的 `deepseek-official/deepseek-flash`。三个 CLI 从环境读取已有的 `DEEPSEEK_API_KEY`。本地 OMP profile 仅在验机时显式选择 | [接入命令](z8-kit/harness/README.md) · [DeepSeek API](https://api-docs.deepseek.com/quick_start/pricing/) |
| CodeBuddy | `codebuddy` 用官方 CLI 登录，核 HY4/实际模型 ID 和额度 | [CodeBuddy CLI](https://www.codebuddy.ai/docs/cli/quickstart) |
| MiniMax Code | `mcode`，选择 M3.1 Flash，分别核 CN/国际账号 | [CLI](https://github.com/MiniMax-AI/minimax-code) · [M3.1 Flash](https://code.minimax.cn/tools/m3.1-flash) |
| TRAE CLI | 国内 `traecli` 2.0 官方文档明确只对 TRAE 企业版旗舰套餐开放。个人订阅方案暂缓。已有旗舰账号时再验 Seed 2.1 Pro 0915 和 Turbo 的模型列表 | [TRAE CLI 2.0 权益](https://docs.trae.cn/cli_about-trae-code-cli-2) · [Linux 快速开始](https://docs.trae.cn/cli_get-started-with-trae-cli-2?lang=zh) |

## 6. Buck2 与 Buildbarn

| 位置 | 部署 |
|---|---|
| P4618 RAID0/XFS | `/srv/work` 和 `buck-out`；`/srv/buildbarn/tiered` 存 AC、CMS、CS 索引与状态、64 GiB 热 CS |
| HC620 RAIDZ1 | `/data/buildbarn` 仅挂在 Z8，存 512 GiB 起步的冷 CS 大块文件，随实际容量和淘汰频率扩容 |
| Linux | Z8 本机 harness 和 Z8 worker 使用同机 Buildbarn。新增的物理构建节点各自部署一套本机冷库 |
| Mac | Buck2 与编译器在 macOS 原生执行。Mac 的 Buildbarn 跑在本机 Docker Desktop，命名卷里各存 AC、CMS 和 CAS，CS 从 64 GiB 起步 |

Buildbarn `readCaching` 将首次冷读回填 P4618，重复读直接走热层。上传由 Buildbarn 写冷 CS，P4800X 先吸收下层写入。冷块轮转由 Buildbarn 管，ZFS 回收由 `autotrim` 通知 mapper。 [Buildbarn readCaching 实现](https://github.com/buildbarn/bb-storage/blob/main/pkg/blobstore/readcaching/read_caching_blob_access.go)

每台构建机只访问自己的 `127.0.0.1:8980`，各有 AC、CAS 和独立淘汰周期。Buck2 按各自主机的 OS、CPU、工具链和 SDK 执行。RE 结果用 Deferred Materialization 时，只有本机动作需要产物才读本机 CAS。打开 SQLite materializer state 后用干净 checkout 核下载量与命中，验证 CAS 淘汰后的重构。Z8 有实际 Linux RE 目标时再启 worker，采用 4 个并发 action、12 CPU 时间额度和 32 GiB 内存上限。 [Buck2 延迟物化](https://buck2.build/docs/users/advanced/deferred_materialization/) · [上游 Linux worker](https://github.com/buildbarn/bb-deployments/tree/main/docker-compose)

Git worktree 共享 `.git` 对象库，每棵树的 `buck-out` 和 materializer 状态独立。P4618 XFS 支持 reflink，本地已有的产物在同一文件系统内可以共享区段。需要共享区段时，对已物化的产物用 `cp --reflink=always` 显式导出，再用 `filefrag -sv` 确认。跨树复用构建结果走 Buildbarn，同一 blob 各次 RPC 下载分别写入各自工作树。 [Git 与 reflink 操作](z8-kit/buildbarn/README.md#git-worktree-与-xfs-reflink) · [Buck2 CAS 下载实现](https://github.com/facebook/buck2/blob/main/app/buck2_execute_impl/src/materializers/deferred/io_handler.rs#L199)

### 第一次构建如何验证

1. 先在 Linux 的项目目录合入样例 execution platform，保持实际工具链和目标标签。以 `buck2 build --config-file /opt/z8-kit/buildbarn/buck2-linux.buckconfig //app:target` 构建一个项目内真实目标，替换示例标签。在同机的第二个干净工作树构建同一提交，检查 `buck2 log show` 是否显示远端 AC 命中。用同一个工作树立刻重复容易命中本地 daemon 或已有产物，会掩盖远端行为。
2. 按 [Mac 本机冷库](z8-kit/buildbarn/README.md#mac-本机冷库) 启动 Mac 的独立 Buildbarn。先用工作树 A 上传，再断开 Mac Wi-Fi，从同一提交的干净树 B 核缓存命中，另选新目标验 cache miss 仍可本机编译。两组都先准备好项目外部依赖。关闭 Mac 的 Buildbarn 后，另验无缓存命令能完成。
3. 在 Linux 两个工作树对同一 commit 跑第一次回读和热回读，另选一批此前从未上传的目标测写。主机同时采 `iostat -xz 2`、`zpool iostat -v z8data 2` 和 Buildbarn 日志。冷读应看到后端读取，热读应主要由 P4618 承担。上传落冷 CS，首轮缓冲由 dm-zoned 吸收。有 RE 任务时，用一个产物验证延迟物化。参数、缓存目录、worker 命令见 [Buildbarn 配置手册](z8-kit/buildbarn/README.md)。

## 7. 远程入口

| 入口 | 用途 | 初始设置 |
|---|---|---|
| SSH + tmux | CLI、文件管理、维护 | 首装用 AX210 Wi-Fi。客户端合并 SSH 样例后，`ssh jackywang-xubuntu-max` 以 `jackywang` 登录。公钥先双会话验证，按需用 SSH 隧道访问 RDP 与推理 |
| Sunshine + Moonlight | 控制 P620 上的本机 XFCE/X11 显示会话 | 接真实或兼容虚拟屏，固定 1080p60 H.264、P620 NVENC 和 X11 捕获。验证登录用户权限、音频、鼠标键盘、重启后可连接；只在私有网络开放所需端口 |
| xrdp + xorgxrdp + XFCE | 独立图形登录 | 以 `jackywang` 登录 Xorg，`~/.xsession` 启动 `startxfce4`。第一次从已登出本机 Xfce 的状态验证。默认监听 loopback，通过 SSH tunnel 连接 |

[P620 图形规格](https://www.nvidia.com/content/dam/en-zz/Solutions/design-visualization/productspage/quadro/quadro-desktop/v2/NVIDIA%20Professional%20Graphics%20Line%20Card.pdf) · [Sunshine 配置](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html) · [xrdp 官方仓库](https://github.com/neutrinolabs/xrdp) · [Ubuntu xorgxrdp](https://packages.ubuntu.com/en/resolute/xorgxrdp)

## 8. 采购报价

用[报价登记模板](z8-kit/market-quote.csv)记录实际料号、成色、数量、含运费报价和退货条件。

## 9. 拷机与交付验证

1. **T1–T3 主机。** 两颗 CPU 都跑负载。DDR4-only 用 Memtest86+ 四个 pass 和 Linux 144 GiB、4 小时压力测试。随后插 PMem，应用 App Direct goal，重跑一轮混插内存测试。正式条带写一份 400 GiB 文件并在切 AC 后复核 SHA-256。devdax 每路先测 8 GiB，再测约 448 GiB 并验 CRC32C。留独立日志，再转 kmem。
2. **T4 裸盘。** 七块 HC620 冷启稳定后并行跑 SMART 长检。按每盘报告的 ETA 预留一晚到一天以上，每块都要有最新的成功结果。
3. **T5 算力坞。** GPU Burn 先单卡 15 分钟、再四卡 60 分钟。测每对 NVLink P2P、NCCL、PCIe Gen3 x8，查 Xid/ECC/AER。
4. **I4–I5 正式存储和服务。** 建池后用同一 512 GiB 文件跑三遍顺序覆盖，在测试文件仍在池中时 scrub。做单 HC620、整卡 P4800X 缺席演练及恢复。挂载通过后上线 Z8 Buildbarn，再验 Mac 本机冷库断网时的命中与未命中。验证 SSH、Sunshine 与 xrdp。
5. **I7 整机。** 8 小时内轮流发 Buck2 冷读、热读和新上传，同时运行指向本机 1017 的探针或 OMP 本地 profile，并使用 SSH 和 RDP。保存启动期和混合负载的 kernel、RAS、NVMe/SMART、ZFS、NUMA 与 TTFT 记录。 [逐条命令与结果判读](z8-kit/host/BURN-IN.md)

在仓库根目录安装 `jq`、`shellcheck` 和 `python3` 后运行 `bash tests/run.sh`，GitHub Actions 在 push 和 PR 上运行同一入口。模拟覆盖七盘齐全、缺一盘、缺两盘、p8 缺席、拒绝拆除已导入池的映射、PMem 异步枚举、kmem 部分上线恢复和双路 HT 分核。测试只用临时目录和替身命令。

此前部署包已在 Ubuntu 26.04 用户空间用占位可执行文件检查 systemd 依赖，也核过官方 Live 包清单、Ubuntu 7.0.0-43 amd64 相关内核配置、NVIDIA 驱动的 APT 优先级及 `ipmctl` 的依赖与启动。实际 Buck2 区段共享、DeepSeek API 登录、整机安装、BIOS、PMem 上线时间、数据池和推理吞吐均需在目标 Z8 上确认。
