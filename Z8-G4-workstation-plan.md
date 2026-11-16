# HP Z8 G4 双路工作站装机与部署计划

2026 年 11 月 16 日 · v2.22 实施版

主机名 `jackywang-xubuntu-max`，登录用户 `jackywang`。按双 8269CY、192 GiB DDR4、12×128 GiB PMem、4×V100 16 GB 和给定的槽位、SATA 接法部署。P4618 的 RAID0/XFS 承担系统、工作树和 Buildbarn 热层。槽 5 的实物为 Intel D4800X 1.5 TB U.2，已硬改为单口 Gen3 x4，装在 PCIe 转接卡上并加风扇。SATA0–3 与 D4800X p5 裸索引组成可重建的冷 CAS。SATA4–6 与 p9 special 组成归档池。模型从首装开始直接放在 App Direct。PMem 从 T3 起使用正式条带。

将本仓库克隆或解压到目标 Linux 的普通用户目录。所有相对路径的操作默认从 `z8-kit` 根目录执行。机旁操作从 [上机操作顺序](z8-kit/host/FIRST-BOOT.md) 开始。本页第 1 节供查看整条路线，第 2–3 节保存硬件与系统配置依据。

- [F10 菜单、DIMM 位置、SATA 接线和起转](z8-kit/host/BIOS.md) · [安装器和系统盘配置](z8-kit/host/INSTALL.md)
- [拷机命令、时长和错误判读](z8-kit/host/BURN-IN.md) · [App Direct、DAX、kmem 和 pinned DMA](z8-kit/host/PMEM.md)
- [BIOS、PMem、SSD 和各板卡的固件更新步骤](z8-kit/host/FIRMWARE.md)
- [九分区建池、启动单元、缺盘和换盘](z8-kit/storage/README.md) · [Buildbarn 服务和 Buck2 客户端](z8-kit/buildbarn/README.md)
- [各类数据的介质、通路和故障域](z8-kit/host/TIERING.md)
- [1017 构建、模型版本和启动参数](z8-kit/inference/README.md) · [CLI 工作树](z8-kit/harness/README.md) · [远程图形和 SSH](z8-kit/remote/README.md)

## 已定的部署配置

| 部分 | 配置 |
|---|---|
| 操作系统 | 从现有 Ventoy 的 Xubuntu 26.04.1 Desktop ISO 导入本地 YAML，直接安装桌面和 md RAID0。FIT 1 GiB ESP、8 GiB `/boot`、24 GiB `Z8TOOLS`、8 GiB `Z8RECOVERY`，其余约 78 GiB 留空。P4618 512 KiB md chunk + XFS reflink，Dracut 生成 initramfs |
| 主板与驱动 | 纯 UEFI，Secure Boot、SNC、ASPM 和 SATA 电源管理关，NUMA、HT、VT-x／VT-d 开。`1TB Memory Cap = Auto`。Ubuntu GA 7.0 + R580 专有驱动。P620 显示，四张 V100 计算 |
| 内存 | 每路 258 GiB fsdax 合并成 2 MiB 条带、XFS DAX。每路剩余 devdax 分别转 kmem，启用冷页下沉和热点提升。推理在两路 DDR4 交错，默认每路 2 核，运行时 HT 伙伴留空，停服后全部归还 |
| 存储 | SATA0–3 各用 24 GiB 写缓存，裸冷 CS 共 32 片、约 50.9 TiB；p5 是 848 GiB 裸索引。SATA4–6 各用 80 GiB 写缓存，组成约 25 TiB RAIDZ1；p9 约 213 GiB special，承载元数据、小块与 ZIL |
| 构建 | max 热 CS 1,638 GiB 在 P4618，其 26 GiB 索引在 PMem 模型卷；冷分片 checkpoint 在 P4618。mini 热/冷 256/640 GiB，Mac 为 256/512 GiB，四块 CMR 到货后 Mac 冷层为 12 TiB。max 提供权威 AC/CAS 和唯一调度器，Linux 与 Darwin 由平台属性分流 |
| 推理 | llama.cpp v1.0.0，ISTA 1017 IQ2_XXS + IQ4_NL Engram，四卡、单槽 128K f16 GPU KV、8 GiB GPU 专家缓存，按显存与工具闭环结果降档 |
| 远程 | 板载有线为主，AX210 Wi-Fi 过渡，DHCP 保留、SSH/tmux，独立图形用 xrdp/Xfce，控制本机桌面用 P620 的 X11/NVENC + Sunshine/Moonlight |

T1–T5 确认二手硬件、实际枚举、起转和四卡 peer，T5 末再确认 1017 能在四卡加载并完成工具往返。I1 确认 FIT 冷启动可找到 RAID0，I4 确认裸冷库覆写、ZFS 同步写和两组缺盘行为，I5 确认 Buck2 缓存与物化，I6–I7 确认推理显存、工具闭环和实际混合负载。只有未通过的项目进入对应排查或回退。

## 1. 测试 → 正式安装

### 第一阶段 · BIOS 设置和硬件测试

顺序是 **CPU → DDR4 → PMem → 存储 → 算力坞**。从三星 Portable SSD T3 250 GB 上的 Ventoy 启动 Xubuntu 26.04.1 Desktop 和 Memtest86+。T1 先把 Xubuntu 装到可清空的 SanDisk Ultra Fit CZ430 128 GB，T1–T5 的 Linux 验机从该临时系统启动，Memtest86+ 从 Ventoy 启动。Samsung FIT 在 T4 临时接入读取序列号，I1 才分区和写入正式引导。T3 在同一系统用 Canonical 官方归档的三份 `.deb` 安装 `ipmctl`，用 26.04 软件源安装 `ndctl` 和 `daxctl`。测试日志和盘序列号保存在 SanDisk，I1 前拔下留存。换件前关机并断交流电。本机到货时 PMem、P4618、D4800X 和 AX210 已装好，PMem 处于 Memory Mode：部件留在原位，PMem 在 T1 末先转 App Direct 再做 T2。 [到货状态](z8-kit/host/BIOS.md#到货状态与首次-f10-实拍) · [PMem 工具准备](z8-kit/host/PMEM.md)

固件随验机阶段处理。T1 最小配置稳定 POST 后核 HP BIOS 与 ME，T3 在提交 App Direct goal 前逐条核 PMem，T4 在 SSD 裸盘压测前核固件，T5 记录每张 V100 的 VBIOS。三星 DDR4 和无源直通板直接做硬件测试。 [固件更新条件与命令](z8-kit/host/FIRMWARE.md)

| 顺序 | 这一步接什么 | 做到什么再继续 |
|---|---|---|
| **T1 · CPU、BIOS 与联网** | 双 8269CY、散热器和风道、12 条 DDR4、槽 4 P620、显示器、网线（无线过渡时加槽 7 AX210 和天线）、Ventoy 与可清空的 SanDisk | F10 设纯 UEFI、NUMA、AHCI、虚拟化等。Live 先接板载有线，缺网线时用 AX210，核 DHCP、DNS 和 APT，再准备临时系统。双路 CPU 依次跑通用压力和 AVX-512 VNNI，记录满载频率、温度与降频事件。 [首次 Live 联网](z8-kit/host/BURN-IN.md#首次-live-联网与临时验机系统) · [CPU 拷机](z8-kit/host/BURN-IN.md#cpu-拷机) |
| **T2 · DDR4** | 沿用 T1 硬件，从 Ventoy 启动 Memtest86+，再回 SanDisk 上的临时 Linux | 每路 96 GiB、共 192 GiB。Memtest86+ 默认测试集四个完整 pass，跳过 Rowhammer。再跑 Linux 144 GiB、4 小时，比较前后的 ECC 与 CPU 硬件事件。 [怎么读硬件错误](z8-kit/host/BURN-IN.md#怎么读硬件错误) |
| **T3 · PMem** | DDR4 原位，CPU0/CPU1 各往六个空槽加 PMem | F10 查条和临时解冻。由 Xubuntu 的 `ipmctl` 提交 App Direct goal，BIOS 在重启时应用。复测混插 DDR4，再验 DAX 与裸 devdax。两路 devdax 转 kmem 后，逐路确认 DDR4 到慢节点的下沉并记录 kmem 冷启上线时间。 [PMem 配置](z8-kit/host/PMEM.md#t3-配置-app-direct) · [kmem 冷启计时](z8-kit/host/PMEM.md#t3-记录-kmem-冷启动时间) |
| **T4 · 存储** | 槽 1 加 P4618，确认 Gen3 x8 上行、两个 x4 下行和两个各约 3.2 TB 的 NVMe 端点，再加槽 5 的 D4800X。HC620 分 1 → 4 → 7 块接 SATA0–6，光驱接 SATA7 | 查 NVMe 健康、SATA 冷启、每盘 `host-managed` 与 zone 类型。七盘并行 SMART 长自检，复验当前网络与七盘同跑。 [P4618 链路检查](z8-kit/host/BURN-IN.md#p4618-链路与双控制器) · [七盘慢扫](z8-kit/host/BURN-IN.md#七块-hc620-并行慢扫) |
| **T5 · 算力坞** | 临时 Linux 先装 NVIDIA 显卡驱动。主机硬件通过后断电，槽 2/3 装直通卡，接 V100 | 逐卡 → 每槽两卡 → 四卡，验 Gen3 x8、六对 NVLink P2P、NCCL、单卡/四卡拷机、pinned H→D。最后跑 1017 冒烟，再关机断开 V100，转正式安装。 [T5 推理冒烟](z8-kit/host/BURN-IN.md#t5-末的-1017-推理冒烟) |

### 第二阶段 · 正式安装和上线

| 顺序 | 装什么与验证方式 |
|---|---|
| **I1 · 操作系统** | 断开 V100 与数据盘，USB 只接三星 T3（Ventoy）和三星 FIT。从 Xubuntu Desktop Live 联网补 `mdadm`，导入 Ventoy 上的 `autoinstall.yaml`，复核序列号后重建 FIT 的 EFI、`/boot` 和 P4618 RAID0/XFS 根。核首启、Dracut、FIT 的 GRUB 救援菜单与元信息备份。 [FIT 救援方案](z8-kit/host/FIT-RECOVERY.md) [系统盘安装](z8-kit/host/INSTALL.md) |
| **I2 · 远程入口** | 板载有线优先，缺网线时用 AX210。设开机自动联网和 DHCP 地址保留，再验 SSH 公钥、tmux 与 xrdp/Xfce。Sunshine 的 P620 硬件编码放 I3。 [远程入口](z8-kit/remote/README.md) |
| **I3 · NVIDIA 显卡驱动与复接 V100** | V100 仍断开，在 Xubuntu 装 `nvidia-driver-580`。这是本方案为 P620 和 V100 选用的 NVIDIA Linux 显卡驱动。重启后用 P620 验桌面、Sunshine/NVENC 和 SSH，再关机接回 V100，核四卡枚举、NVLink 与快速 CUDA/NCCL。 [驱动安装和锁分支](z8-kit/host/INSTALL.md#安装并锁定-nvidia-显卡驱动) |
| **I4 · 存储与 PMem** | 接回已慢扫的盘，首次划 D4800X 九分区，建七个 dm-zoned target、32 个冷分片和三盘 RAIDZ1。跑冷库覆写、ZFS scrub、三种缺盘冷启和恢复。按 T3 留下的 namespace UUID 恢复 DAX 模型卷和 kmem。 [存储](z8-kit/storage/README.md) · [PMem](z8-kit/host/PMEM.md) |
| **I5 · Buildbarn 与 Buck2** | max 按每路预留 2 核安装 CPU slice 和 88 并发 runner 配置，依次启动 AC/CAS、调度器和 Linux worker。接入 mini 及 Mac 的边缘存储与 worker，验证一次 Linux/Darwin 跨平台构建、单测及按需物化。 [CPU 分核安装](z8-kit/host/CPU-PLACEMENT.md#生成并安装) · [Buildbarn](z8-kit/buildbarn/README.md) |
| **I6 · 推理与 harness** | 用 llama.cpp v1.0.0、四张 V100 和一套 PMem 上的 1017 权重，验 128K 单槽目标、工具闭环和实际 harness，再保存参数并启动推理服务。OMP、Pi、DSH 可用已有密钥直连 DeepSeek 官方 API。各 CLI 验证账号、模型和工作树。 [推理](z8-kit/inference/README.md) · [服务配置](z8-kit/host/CPU-PLACEMENT.md#启停本地模型) · [CLI](z8-kit/harness/README.md) |
| **I7 · 正式联调与恢复** | 冷启动检查 SSH、存储链和远程显示。验证本地 DeepSeek 启停时让出和归还 I5 已配置的核心，然后做一次 8 小时的编译、推理和 I/O 混合负载。保存引导、盘表、GUID、驱动/内核版本、服务配置及项目数据的独立副本。 [CPU 分核与启停](z8-kit/host/CPU-PLACEMENT.md) · [整机拷机](z8-kit/host/BURN-IN.md) |

DIMM 上的 **PMem100** 在 T3 验，测试时提交的 goal 和 namespace 供正式系统沿用。槽 5 的 **D4800X** 是 NVMe SSD，在 T4 随 HC620 一起做裸盘检查，正式安装 I4 再用于建池。

[镜像和校验文件](https://www.cdimage.ubuntu.com/xubuntu/releases/26.04/release/) · [Xubuntu 26.04 支持周期](https://xubuntu.org/release/26.04/)

## 2. 槽位、BIOS 与供电

| HP 槽号 | 设备 |
|---|---|
| 1 | P4618，`Bifurcation = Auto`，双 CPU 且不装 Thunderbolt 3 卡时为 Gen3 x8 |
| 2 | x16→x8/x8 直通卡，接两张 V100 |
| 3 | x16→x8/x8 直通卡，接两张 V100 |
| 4 | P620，主显示 |
| 5 | D4800X，Gen3 x4 |
| 6 | 空，被槽 5 的转接卡和风扇挡住 |
| 7 | AX210 过渡，蓝牙经内部 USB。有线确认后拔卡，槽位空出 |
| SATA0–6 / SATA7 | 7×HC620 SATA / 原装光驱 |

F10 首装使用 **纯 UEFI，Legacy/CSM 和 Secure Boot 都关闭**。Fast Boot 关、SATA Controller Enable、SATA 与 sSATA 的 RAID Mode Disable、SATA0–7 打开、Primary Graphics Slot 4、Slot 2/3 Bifurcation x8/x8、NUMA 和 HT 开、SNC 关。DDR4-only 先在 CPU0 和 CPU1 **各**插 DIMM 1/3/5/8/10/12。混插时 DDR4 留原位，CPU0 和 CPU1 各往 DIMM 2/4/6/7/9/11 加 PMem，再配置 App Direct。槽号以 CPU0/CPU1 各自的主板丝印为准。 [F10 配置手册](z8-kit/host/BIOS.md) · [HP QuickSpecs，双路 192 GB 配置](https://h30434.www3.hp.com/psg/attachments/psg/Business-PC-Workstation-POS/44704/1/Z8%20G4%20Quickspecs%20v67.pdf#page=22) · [HP Optane 白皮书，24 条混插](https://h10032.www1.hp.com/ctg/Manual/c06527302.pdf#page=22)

**内网首装保留 VT-x、VT-d、默认 PCIe ACS、Intel ME 和 HP Sure Start 的固件恢复。** VT-x 给 KVM 等虚拟机提供 CPU 硬件加速，裸机 Buck2 和 1017 的性能继续按实测记录。关闭不用的 AMT、PXE、TXT 和 HP Sure Recover，保持设备级 DriveLock 未启用。新装 XFS 根若没有使用 TPM 解锁或密钥，可关闭 TPM State。接坞后先记录真实 NVLink 和 PCIe 拓扑，需使用裸机 PCIe P2P 时，按 NVIDIA 要求用 GRUB 单次关闭 Intel IOMMU 做该路径测试。 [F10 各项取值](z8-kit/host/BIOS.md#内网主机的安全与虚拟化设置) · [HP 服务手册](https://kaas.hpcloud.hp.com/pdf-public/pdf_6792418_en-US-1.pdf) · [NVIDIA 多 GPU 指南](https://docs.nvidia.com/cuda/cuda-programming-guide/03-advanced/multi-gpu-systems.html#host-iommu-hardware-pci-access-control-services-and-vms)

按 Esc → F10 后，在 `Advanced → Secure Boot Configuration → Configure Legacy Support and Secure Boot` 选择 **Legacy Support Disable and Secure Boot Disable**。保存后如出现 Boot Mode Change，输入屏幕确认码。保留 `UEFI Boot Order`，用 F9 选 Ventoy UEFI 后在菜单选 Memtest86+ 或 Xubuntu Desktop，验机从 SanDisk 启动，I1 装好正式系统后才选 FIT 的 UEFI 引导项。在 `Boot Options` 把 `After Power Loss` 设为 `Power Off`，按算力坞接线记录手动上电。在 `Slot Settings` 保持槽 1 的 Bifurcation 为 Auto，槽 2/3 改为 x8/x8（若固件提供该项），槽 5/7 保持 Enable。保存后先从 P620 看一次 POST，再进入 Linux 核验。 [HP F10 设置](https://support.hp.com/ee-en/document/ish_9642671-9641393-16)

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

- I1 从三星 T3 的 Ventoy 启动 Xubuntu Desktop，在图形安装器导入填好的 `autoinstall.yaml`。回 Live 终端核对 FIT 和两个 P4618 端点的 `ID_SERIAL`，执行 `sudo touch /run/z8-storage-confirmed` 放行，再回图形界面确认安装。FIT 上的 GRUB 读入内核与 Dracut 初始化镜像，后者组装 P4618 根阵列。 [安装命令](z8-kit/host/INSTALL.md)

- `/srv` 是标准的本机服务数据目录，默认由根 XFS 承载。手动创建 `/srv/work/jackywang` 和 `/srv/buildbarn/tiered`。项目、`buck-out`、Buildbarn AC、CMS 和热 CS 块文件落 P4618，热 CS 索引放 `/srv/pmem-model/bb-hot-index`。冷 CS 裸索引在 D4800X p5，冷分片状态在 P4618。单独在 `/srv/pmem-model` 挂 PMem XFS DAX，先用 `findmnt -M` 查该挂载点再写入模型。P4618 的 XFS 在安装配置里显式设 `crc=1,reflink=1`，首启用 `xfs_info /` 验证。 [安装命令与目录](z8-kit/host/INSTALL.md) · [文件系统目录标准](https://specifications.freedesktop.org/fhs/latest/srv.html)
- 首启为根 XFS 写 `noatime,nodiscard`，md 实测透出 discard 时用周期 TRIM。FIT 的 `/boot`、ESP 用 `noatime`，从周期 TRIM 排除。PMem 模型 XFS 用 `dax=always,noatime,nodiscard`。`data-other.mount` 按依赖链以 `rw` 挂载，压缩、atime 和同步写策略保存在 dataset 属性。 [全机挂载参数及核对命令](z8-kit/host/MOUNTS.md) · [fstab 样例](z8-kit/host/fstab-boot.example)

### HC620 与 D4800X

七块 HC620 保留 Linux 7.0 默认 I/O 调度器。每盘盘头的 524 个 conventional 区照常由 dm-zoned 管理。槽 5 的 D4800X 承接随机写缓冲，普通区有条件可作后台回收目的地。T4 确认 SATA 4Kn、`host-managed` 和 256 MiB 区。I4 通过 SATA by-id 和同卡 GPT 标签识别配对。`dmzadm --format` 只用于首次或明确重建，冷盘 `--seq=96`，ZFS 盘 `--seq=320`，两组 mapper 接受 52,080–52,156 个完整 chunk，冷盘上固定切 52,080 个。 [分区和首次初始化](z8-kit/storage/README.md#2-建-gpt-与初始化-dm-zoned)

- **冷 CAS**。SATA0–3 位于机箱原生盘位，单盘八片，每片约 1.59 TiB。D4800X p1–p4 各 24 GiB，p5 的 848 GiB 裸索引也切 32 个。分片使用稳定的 dm-linear 名称。冷盘临时缺席时按 24 个分片运行，其余冷盘和 ZFS 可继续服务。更换盘只重建该盘的八份索引及 checkpoint。每月 SMART 扩展自检加每日取证，有介质错误证据的盘才做逻辑扫描。
- **普通数据**。SATA4–6 位于三盘笼，分别配 D4800X p6–p8 的 80 GiB 缓存，组成三盘 RAIDZ1。p9 取尾部约 213.26 GiB 作 special，预计有 2 GiB 内嵌 ZIL。`z8data/other` 使用 `recordsize=1M,special_small_blocks=16K,compression=zstd-3`，`z8data/reserve` 预留初始可用量的 10%。保留 `autotrim=on`、每月 scrub、ARC 1–4 GiB。单 special 所在整卡损坏时从独立备份恢复。 [建池与属性](z8-kit/storage/README.md#3-建-zfs-池与-legacy-mount-数据集)

### 首次部署与以后每次启动

`z8-dmzoned.service` 启动后，两条独立链分别构造 `z8-cold.service → z8-buildbarn.service` 和 `z8-zpool.service → data-other.mount`。冷库需要有效 p5 与已初始化可用分片，ZFS 需要 p9 和至少两个 SATA4–6 mapper。I4 启用冷库设备与一般数据挂载，完成受控覆写、初始化索引、同步写和缺盘演练。I5 启用 Buildbarn 和 worker，固定镜像只获准访问有效分片。 [I4 命令、验证和恢复](z8-kit/storage/README.md#4-i4-安装存储依赖链)

```bash
bash host/run-step.sh i4-status
```

主机断电再改接线，存储按依赖逆序停止。分别验证冷盘缺席、ZFS 盘缺席和 D4800X 整卡缺席，恢复后保留日志。D4800X 整卡缺席时主机仍可 SSH。冷库重建后处理 max、mini、Mac 的 CMS，保留仍有效的热 CS 和 AC。 [冷分片恢复](z8-kit/storage/README.md#缺盘停机恢复)

## 4. DeepSeek-V4.1-Flash-1017

### 内存与模型放置

| 层 | 放置 |
|---|---|
| 四卡 HBM（64 GiB 标称） | dense、attention、活跃 KV 和 8 GiB 合计热专家缓存 |
| 两路 DDR4（192 GiB） | 各 96 GiB。推理从两个 DDR4 节点交错分配；按引擎所需分配 pinned DMA 缓冲。系统、Buck2 保留本地优先 |
| App Direct fsdax（2×258 GiB） | 2 MiB dm-stripe，约 508 GiB 块设备容量，XFS DAX，挂 `/srv/pmem-model`。存一套 GGUF、Engram 与 tokenizer，另放 26 GiB 的 Buildbarn 热 CS 索引 |
| 两路剩余 App Direct | 各自以可迁移 kmem 上线，启用 memmap on memory 和冷页下沉。活跃推理 KV 由引擎分配 |

**NUMA 固定开、SNC 关。** Z8 G4 主板有两条 UPI，最高 10.4 GT/s/条。共享 arena 交错避免单侧 96 GiB 先耗尽。DAX 文件通过 CPU 访问，普通 DDR4 做 CUDA staging。默认每路留最后 2 个物理核的主线程给推理，运行时同核 HT 留空。普通任务可用 96 个逻辑 CPU，推理停止后恢复全部 104 个。 [HP 白皮书，第 3 页](https://www.workstation4u.de/hp-z8-g4-technichalwhitepaper.pdf#page=3) · [PMem 配置](z8-kit/host/PMEM.md) · [CPU 分核](z8-kit/host/CPU-PLACEMENT.md)

### 推理上线顺序

1. **部署 llama.cpp v1.0.0。** CUDA 12.9.1 编译 SM70，固定 ISTA IQ2_XXS + IQ4_NL Engram。四卡 layer split、单槽 128K f16 GPU KV、专家缓存 8192 MiB、ubatch 32，CPU miss share 0。默认启用槽内前缀复用，以真实工具往返、前缀命中 token 和输出验证。 [固定版本与命令](z8-kit/inference/README.md#llamacpp-v100-主服务)
2. **显存压力按阶梯降档。** 依次试 q8 KV、4 GiB 专家缓存、q4 KV、64K 和主机 KV。128K 目标仍达不到再评估 1Cat。Xolotl Buster 留作短上下文单用户回退，使用每路 6 核。 [上下文降档](z8-kit/inference/README.md#上下文降档与验收)
3. **1Cat 只用于有明确需求的长上下文。** #1277 的 512K 成绩用 4×32 GiB，和本机 4×16 GiB 的预算不同。原版 Strata 的 1017 包未列 SM70，Xolotl 提供 Buster 构建路径。upstream vLLM 1017 公版配方需至少 8×80 GB。 [1Cat 上游实测](https://github.com/1CatAI/1Cat-vLLM/blob/main/benchmarks/deepseek_v41/HANDOFF.md) · [Strata 1017 支持](https://github.com/Niko1221/Strata/blob/main/docs/DEEPSEEK41.md) · [vLLM 1017 配方](https://github.com/vllm-project/vllm/blob/main/recipes/models/deepseek-ai/DeepSeek-V4.1-Flash.yaml)

I6 放行看近满上下文时每卡至少余 2 GiB、20 次连续工具往返、完整 SSE 和零 OOM/Xid。记录首次填充时间和同前缀第二轮首字延迟。双槽是可选项，每槽默认 64K。I7 跑一次正式配置的 8 小时混合负载并记录 p95 TTFT、decode 和构建完成时间。 [推理放行](z8-kit/inference/README.md#i6-推理放行)

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
| P4618 RAID0/XFS | `/srv/work`、`buck-out`、AC、CMS 及其索引、1,638 GiB 热 CS 与冷分片 checkpoint |
| PMem 模型卷 | 26 GiB 热 CS 索引，DAX 直通 |
| HC620 SATA0–3 | 32 个 256 MiB 对齐的裸冷 CAS 分片，合计约 50.9 TiB |
| D4800X p5 | 848 GiB 裸索引，32 段各 26.5 GiB。持久设备清单在 `/etc/z8-storage/cold-layout.json` |
| HC620 SATA4–6 与 D4800X p9 | 三盘 RAIDZ1 加 special，挂载 `/data/other` |
| Linux | max 托管 AC/CAS、唯一调度器和 Linux worker。mini 用 PM9F1 热层、S3610 冷层，另提供 Linux worker |
| Mac | Mac mini M4 提供原生 Darwin worker 和边缘读缓存。系统与 Xcode 用内置盘，其余先用外接 PM9F1 |

Buildbarn `readCaching` 将首次冷读回填 P4618，重复读直接走热层。上传由 Buildbarn 写冷 CS，D4800X 先吸收下层写入。冷块轮转由 Buildbarn 管，ZFS 回收由 `autotrim` 通知 mapper。 [Buildbarn readCaching 实现](https://github.com/buildbarn/bb-storage/blob/main/pkg/blobstore/readcaching/read_caching_blob_access.go)

I5 默认启用 max 的 Linux worker，首装 88 并发、512 GiB runner 上限，CPU 由 cpuset 和 slice 权重约束，两路 kmem 上线后启动 worker。项目 execution platform 固定 runner 镜像和工具链。本机 worker 与 scheduler 经 UNIX socket 访问 cache，各客户端连本机 8980，边缘读缓存经 SSH 与 max 通信。共享 `hardlinking` 实例内，Linux 和 Darwin 用平台属性分流。RE 结果由 Deferred Materialization 按需拉取。 [Buck2 延迟物化](https://buck2.build/docs/users/advanced/deferred_materialization/) · [上游 Linux worker](https://github.com/buildbarn/bb-deployments/tree/main/docker-compose)

Git worktree 共享 `.git` 对象库，每棵树的 `buck-out` 和 materializer 状态独立。P4618 XFS 支持 reflink，本地已有的产物在同一文件系统内可以共享区段。需要共享区段时，对已物化的产物用 `cp --reflink=always` 显式导出，再用 `filefrag -sv` 确认。跨树复用构建结果走 Buildbarn，同一 blob 各次 RPC 下载分别写入各自工作树。 [Git 与 reflink 操作](z8-kit/buildbarn/README.md#git-worktree-与-xfs-reflink) · [Buck2 CAS 下载实现](https://github.com/facebook/buck2/blob/main/app/buck2_execute_impl/src/materializers/deferred/io_handler.rs#L199)

### 第一次构建如何验证

1. 先在 Linux 的项目目录合入样例 execution platform，保持实际工具链和目标标签。按 [Buck2 daemon 配置](z8-kit/buildbarn/README.md#装进-daemon-读取的配置)安装客户端参数，以 `buck2 build --remote-only //app:target` 构建一个项目内真实目标，替换示例标签。在同机的第二个干净工作树构建同一提交，检查 `buck2 log show` 是否显示远端 AC 命中。用同一个工作树立刻重复容易命中本地 daemon 或已有产物，会掩盖远端行为。
2. 按 [Linux 与 macOS 构建农场](z8-kit/buildbarn/EDGE.md) 接入 mini 和 Mac。一条命令请求项目既有的 Linux、Darwin 测试目标，核两种平台各由正确 worker 执行。断开到 max 的连接时，启用本机执行入口。
3. 在 Linux 两个工作树对同一 commit 跑第一次回读和热回读，另选一批此前从未上传的目标测写。主机同时采 `iostat -xz 2`、冷库水位日志（`i5-cold-watermark`）和 Buildbarn 日志。冷读应看到后端读取，热读应主要由 P4618 承担。上传落冷 CS，首轮缓冲由 dm-zoned 吸收。用一个远程执行产物验证延迟物化。参数、缓存目录、worker 命令见 [Buildbarn 配置手册](z8-kit/buildbarn/README.md)。

## 7. 远程入口

| 入口 | 用途 | 初始设置 |
|---|---|---|
| SSH + tmux | CLI、文件管理、维护 | 首装优先用板载有线，缺网线时用 AX210。客户端合并 SSH 样例后，`ssh jackywang-xubuntu-max` 以 `jackywang` 登录。公钥先双会话验证，按需用 SSH 隧道访问 RDP 与推理 |
| Sunshine + Moonlight | 控制 P620 上的本机 XFCE/X11 显示会话 | 接真实或兼容虚拟屏，固定 1080p60 H.264、P620 NVENC 和 X11 捕获。验证登录用户权限、音频、鼠标键盘、重启后可连接；只在私有网络开放所需端口 |
| xrdp + xorgxrdp + XFCE | 独立图形登录 | 以 `jackywang` 登录 Xorg，`~/.xsession` 通过 `dbus-run-session` 启动 Xfce。分别在本机控制台已登录和未登录时验证。默认监听 loopback，通过 SSH tunnel 连接 |

[P620 图形规格](https://www.nvidia.com/content/dam/en-zz/Solutions/design-visualization/productspage/quadro/quadro-desktop/v2/NVIDIA%20Professional%20Graphics%20Line%20Card.pdf) · [Sunshine 配置](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html) · [xrdp 官方仓库](https://github.com/neutrinolabs/xrdp) · [Ubuntu xorgxrdp](https://packages.ubuntu.com/en/resolute/xorgxrdp)

## 8. 采购报价

用[报价登记模板](z8-kit/market-quote.csv)记录实际料号、成色、数量、含运费报价和退货条件。

## 9. 拷机与交付验证

1. **T1–T3 主机。** 两颗 CPU 都跑负载。DDR4-only 用 Memtest86+ 四个 pass 和 Linux 144 GiB、4 小时压力测试。随后插 PMem，应用 App Direct goal，重跑一轮混插内存测试。正式条带写一份 400 GiB 文件并在切 AC 后复核 SHA-256。devdax 每路先测 8 GiB，再测约 448 GiB 并验 CRC32C。留独立日志，再转 kmem。
2. **T4 裸盘。** 七块 HC620 冷启稳定后并行跑 SMART 长检。按每盘报告的 ETA 预留一晚到一天以上，每块都要有最新的成功结果。
3. **T5 算力坞。** GPU Burn 先单卡 15 分钟、再四卡 60 分钟。测每对 NVLink P2P、NCCL、PCIe Gen3 x8，查 Xid/ECC/AER，最后跑 1017 冒烟。
4. **I4–I5 正式存储和服务。** 四盘各写 128 GiB 并原址覆盖三遍，采样回收水位；对三盘池单做同步写与 scrub。分别演练冷盘、ZFS 盘和整卡 D4800X 缺席。I5 再验边缘冷/热读、两平台远程执行以及 24 分片下的服务。
5. **I7 整机。** 8 小时内轮流发 Buck2 冷读、热读和新上传，同时运行指向本机 1017 的探针或 OMP 本地 profile，并使用 SSH 和 RDP。保存启动期和混合负载的 kernel、RAS、NVMe/SMART、ZFS、NUMA 与 TTFT 记录。 [逐条命令与结果判读](z8-kit/host/BURN-IN.md)

在有 `systemctl` 和 `apt-config` 的 Linux 环境准备 `bash`、`jq`、`shellcheck`、`jsonnet` 和 `python3`，从仓库根目录运行 `bash tests/run.sh`。GitHub Actions 在 push 和 PR 上运行同一入口。`tests/storage.sh` 用 `systemctl --root` 核对临时目录中的单元启用链接。模拟覆盖两条依赖链、分片缺席、索引和数据切片、错误注入扫描、PMem 异步枚举、kmem 部分上线恢复和双路 HT 分核。

此前部署包已在 Ubuntu 26.04 用户空间用占位可执行文件检查 systemd 依赖，也核过官方 Live 包清单、Ubuntu 7.0.0-43 amd64 相关内核配置、NVIDIA 驱动的 APT 优先级及 `ipmctl` 的依赖与启动。实际 Buck2 区段共享、DeepSeek API 登录、整机安装、BIOS、PMem 上线时间、裸冷库、dm-linear 切片、介质错误扫描、三盘池和推理吞吐均需在目标 Z8 上确认。
