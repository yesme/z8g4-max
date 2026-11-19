# Z8 G4 上机操作顺序

适用 v2.22，主机 `jackywang-xubuntu-max`，登录 `jackywang`。按 **T1–T4 验主机 → T5 验算力坞 → I1–I7 安装与上线** 执行。每一步链接到实际操作命令。

## 0. 上电前

- **三星 Portable SSD T3 250 GB（Ventoy）**。现有多系统安装与救援盘。Ventoy 至少为 1.1.18，保留原分区和镜像。用原装的 USB 3.1 Gen2 线直接接主板背面的 USB 口；本机实测换用其他线时出现过 `Boot Device Not Found` 和 Live 启动卡在动画的情况，换回原装线后正常。F9 启动它后，T1 选 Xubuntu 26.04.1 Desktop ISO，T2/T3 选里面的 Memtest86+。I1 复用同一份 ISO，从 Ventoy 大数据分区读取 `z8/autoinstall.yaml`，之后还用它做救援。提前把仓库副本也存到该分区。 [准备安装配置](INSTALL.md#i12-生成安装配置并核身份)
- **SanDisk Ultra Fit CZ430 128 GB，可清空**。T1 把原来的安装介质改为可启动的临时 Xubuntu 系统，T1–T5 从它启动并保留工具、驱动和日志。I1 前拔下，保留验机系统和记录。
- **128 GB Samsung FIT**。T4 插入一次，抄 `ID_SERIAL`。I1 才分区。FIT 存 EFI、`/boot`、救援工具和元信息备份，根 `/` 在 P4618 RAID0。 [FIT 分区及救援](FIT-RECOVERY.md)
- **BC711**。留作备用。
- **现场准备**。键盘接主机，显示器接 P1000，优先备好网线；用 AX210 过渡时接两根天线并备好 Wi-Fi 凭据。给容量相同的两只 U 盘贴上「SanDisk 验机」和「Samsung 引导」，给 HC620 数据线标 SATA0–6，给四根算力坞链路标槽号和分支。换盘、DIMM 或 PCIe 线前，先结束当前测试并正常关机，再切断相关设备的交流电。
- **记录位置**。采集到 SanDisk 临时系统的 `~/z8-burnin`，包括 PMem UUID、两份 PMem env、磁盘序列号和测试日志。T5 结束后将 SanDisk 拔下留存。命令中的 `host/…`、`storage/…` 都相对于仓库的 `z8-kit`。记下每轮实际的启动介质、`uname -r` 和 BIOS 版本。

## 在终端运行与取日志

从仓库的 `z8-kit` 目录运行 `bash host/run-step.sh --help` 查看可执行步骤。Live、SanDisk 和正式系统都用同一个入口。`GPU-REPLACE…`、磁盘 by-id 和节点号用上一步实测值填。脚本把执行过程、退出码和日志绝对路径同时显示在终端。

默认写到 `~/z8-burnin/steps/`，每次运行生成新文件。Live 退出前按[挂载 Ventoy 与保存日志](INSTALL.md#挂载-ventoy-与保存-live-日志)把文件复制到三星 T3。后续排查时直接附上 `Log:` 后那份日志。压测或温度采样可在对应终端按 Ctrl+C 停止。

## 1. T1–T4 验主机

### T1 · CPU、F10 和联网

1. 每路装一颗 8269CY、散热器和内存风道。CPU0、CPU1 各在 **DIMM 1/3/5/8/10/12** 装六条 16 GiB DDR4。插槽 4 装 P1000 并接显示器。板载网口优先接网线；需无线过渡时在槽 7 装 AX210 并接天线。槽 1/2/3/5/6 留空，SATA 盘和算力坞等到后续阶段。本机到货时 PMem、P4618、D4800X 和 AX210 已装好：PMem、P4618 和 D4800X 现已拆下，分别在 T3、T4 装回；槽 2/3 的两块直通板留在机内，不接坞。 [到货状态](BIOS.md#到货状态与首次-f10-实拍)
2. 首次 POST 后进 **F10**，记录 BIOS 与 ME，按手册判断是否需要更新。应用首装值：纯 UEFI、Secure Boot 关闭、AHCI、NUMA 开、SNC 关、HT/Turbo/VT-x/VT-d 开、槽 4 主显示。`1TB Memory Cap = Auto`，PCI Express 和 SATA 电源管理均设为 `Disable`，沿用到正式系统。到货值里要改四项：关 Fast Boot、关 PXE、关 SATA 的 RAID Mode、停用整个 sSATA Controller。保存后重新确认 POST 和 DDR4 容量。装系统前可先按 F2 用 HP 自带诊断跑 Processor、System Board 和 Memory Quick Check。 [HP 自带诊断](BURN-IN.md#hp-自带诊断) [F10 首装值](BIOS.md#f10-首装值) · [T1 固件](FIRMWARE.md#t1-hp-biosme-与-cpu-微码)
3. 按 **F9 → Ventoy UEFI → Xubuntu 26.04.1 Desktop → Try Xubuntu**。用板载有线或 AX210 过渡联网，核 DHCP、DNS 和 APT，按[挂载步骤](INSTALL.md#挂载-ventoy-与保存-live-日志)试读同一块 Ventoy 数据分区，再把 **SanDisk CZ430** 选作整盘安装目标。此时 FIT 先不接。按安装器提示拔下 Ventoy，从 SanDisk 冷启临时 Xubuntu，再确认能联网。 [Live 联网与 SanDisk 安装](BURN-IN.md#首次-live-联网与临时验机系统)
4. 在临时系统安装微码和诊断工具，并装好 R580 显卡驱动，重启后确认两颗 CPU、两个 DDR4 NUMA 节点。满载前先跑 60 秒看两路温度。先跑 30 分钟通用 CPU 压测，再跑 30 分钟 AVX-512 VNNI，保存 RAS、温度和满载频率。 [CPU 拷机命令](BURN-IN.md#cpu-拷机)

### T2 · 只测 DDR4

1. 保持 T1 的硬件。F9 进 Ventoy，选 Memtest86+，完整地址范围、默认测试集、Rowhammer 关闭。第 1 pass 是快筛，累计 **4 个完整 pass**，保存零错误结果。
2. F9 换回 SanDisk 上的临时系统，先看 DDR4 容量、ECC/EDAC 计数，再做 **144 GiB、4 小时**交错压测。比较前后 CE/UE 和 MCE。发现新增错误或掉条，留在 T2 定位。两轮通过后才加 PMem。 [容量、温度监控及停测](BURN-IN.md#t2-只测-ddr4)

### T3 · 加 PMem，建并验证正式模型卷

1. 仍从 SanDisk 上的临时系统启动时，先装好 `ipmctl`、`ndctl`、`daxctl` 和 PMem 版 fio 所需工具。关机断电，DDR4 留在原位，每路在 **DIMM 2/4/6/7/9/11** 插六条 PMem 100。首次混插进 F10，看 12 条是否识别，并按手册临时解冻。这批模块带着原来的 Memory Mode 配置，首次开机时内存总量可能是 PMem 容量，属预期，先提交 goal 再做内存测试。 [PMem 的到货状态](BIOS.md#pmem-的到货状态) [T3 工具](PMEM.md#t3-准备工具) · [App Direct 第 1 步](PMEM.md#1-在-f10-查条并临时解冻)
2. 回 SanDisk，保存 `ipmctl` 盘点和固件状态。需要初始化时在 **Linux** 提交 App Direct goal，再重启回 SanDisk，确认两路健康 region 和无待应用 goal。随后从 Ventoy 选 Memtest86+ 跑 **1 个完整 pass** 检查混插后的 DDR4，再回 SanDisk 做 PMem 测试。 [App Direct 第 2、3 步](PMEM.md#2-在-xubuntu-26041-记录现状并提交-goal) · [混插与专用压测](BURN-IN.md#t3-pmem-100app-direct-的专用检查)
3. 按 socket 划两个 **258 GiB fsdax** 和两个剩余 **devdax**。两个 fsdax 条带化，首次格式化为正式 XFS DAX 模型卷。先做 fsdax 文件与两个裸 devdax 的专用写读校验，再将 fsdax 测试文件的 SHA-256 存到 SanDisk 上的日志目录，正常关机、切 AC、回 SanDisk 挂载复核。删掉测试文件，再按 [T3 模型挂载服务](PMEM.md#交给启动服务)交给 systemd，供之后 T5 使用。 [模型卷命令](PMEM.md#模型卷) · [PMem 测试命令](BURN-IN.md#t3-pmem-100app-direct-的专用检查)
4. 两个 devdax 的裸设备测试结束后才转 kmem。确认两路均为 online/Movable，逐路施压并核冷页下沉，按手册记录服务冷启动用时。保存两个按 socket 填好的 `pmem-model.env`、`pmem-kmem.env`，另记原始四个 namespace UUID、DDR4 节点编号和两路慢节点。I4 会复用这四个 namespace 以及模型卷。 [kmem 上线](PMEM.md#剩余-pmem-转-kmem) · [冷启计时](PMEM.md#t3-记录-kmem-冷启动时间) · [逐路下沉](PMEM.md#核实每路-ddr4-的冷页去向)

### T4 · 加存储，先验裸设备

1. 断电装槽 1 的 P4618，从 SanDisk 上的临时系统启动。验 Gen3 x8 上行、两个 Gen3 x4 下行，且两个独立的约 3.2 TB NVMe 端点都在。过关后再装槽 5 的 D4800X，槽 6 留空。逐端点做固件盘点、SMART 和只读负载。 [P4618 链路](BURN-IN.md#p4618-链路与双控制器) · [NVMe 与 SATA 检查](BURN-IN.md#nvme-健康与-sata-枚举)
2. 按 **1 → 4 → 7** 块 HC620 分批冷启。SATA0–3（冷库）接原生位，SATA4–6（ZFS）接双光驱位三盘笼，SATA7 接薄光驱。每种配置按 BIOS 手册冷启，核盘和链路。保存 SATA0–6 对应的序列号及 ATA 整盘 by-id，逐盘确认 SATA、4Kn、`host-managed` 和 zone 类型。 [SATA 接线与起转](BIOS.md#先确认系统认盘)
3. 七盘全部稳定后，各发一次 SMART Extended。七块盘各自扫描，保持供电、通风和禁止自动休眠，等最后完成的盘。核每盘最新自检均为 `Completed without error`。此时仍在验裸盘。D4800X 分区、dm-zoned 初始化、建池和 scrub 全在 I4。 [七盘慢扫命令](BURN-IN.md#七块-hc620-并行慢扫)
4. 保存无坞主机清单和日志。先关机插入 FIT，再从 F9 启动 SanDisk 上的临时系统，抄 **FIT、两个 P4618 端点**的三个唯一 `ID_SERIAL`，抄 D4800X 的整盘 NVMe by-id。按 I1.2 填好 `autoinstall.yaml`，放到 Ventoy 大数据分区的 `z8/`。关机拔下 FIT，后续验机仍从 SanDisk 启动。主机和七盘完成验收后才接坞。 [主机基线](BURN-IN.md#主机基线) · [读取 ID_SERIAL](INSTALL.md#i12-生成安装配置并核身份)

## 2. T5 验算力坞

1. 保持坞断开，复核 T1 已在临时 Xubuntu 装好的 R580 和 P1000 枚举，并在 SanDisk 上[准备 CUDA 验机工具](INSTALL.md#算力坞验收)。按 [R580 包与安装模拟](INSTALL.md#安装并锁定-nvidia-显卡驱动) 操作。关机断电，按 [槽位表](BIOS.md#板上槽位) 接槽 2/3 的 x8/x8 直通板。按底板供电方式确认坞的端点、电源和冷却能在主机 POST 时就绪，核四套水路和泵。若坞为独立手动供电，第一轮上机前核供应商启停顺序并记录。
2. 按 **单卡 → 每槽各验两卡 → 四卡** 冷启。单卡、同槽双卡各跑 15 分钟 GPU Burn。每轮保存 GPU UUID、BDF、NUMA 归属和负载下 PCIe 速率/宽度。四卡再测六对 NVLink P2P、NCCL、四卡 1 小时 GPU Burn 和交错 DDR4 的 pinned H→D。检查新增 Xid、AER、ECC，并与 T4 比对存储枚举。 [T5 拷机](BURN-IN.md#t5-算力坞-v100-与-pcie-拷机) · [CUDA/NCCL](INSTALL.md#算力坞验收) · [pinned DMA](PMEM.md#四卡-pinned-dma-验收)
3. 可从 T5 开始安排约 **232 GiB** 的权重下载，直接写已核实挂载的 PMem 模型卷。四卡硬件过关后做 1017 冒烟。按 T5 手册的速度档判断是否进 I1，从单槽 128K 起步，记录实际使用档、引擎、权重 revision、四卡 UUID、显存与工具来回结果。T5 的源码与编译产物在 SanDisk 上的临时系统。权重留在 PMem 给 I6 复用。 [T5 推理冒烟](BURN-IN.md#t5-末的-1017-推理冒烟)
4. 停模型和测试服务。把保存在其他目录的验机记录一起收进 SanDisk 的 `~/z8-burnin`，确认日志、磁盘清单及两份 PMem env 都可读。正常关机，拔下并留存 SanDisk，I1 安装期间用不到它。

## 3. I1–I7 正式安装与上线

### I1 · 正式系统

1. T5 已关机并拔下 SanDisk，此时切断交流电。**断开四张 V100、七块 HC620 和 D4800X**。保留 P4618、P1000、DDR4 与 PMem；仅无线过渡时保留 AX210。USB 只接三星 T3（Ventoy）和三星 FIT。
2. **F9 → Ventoy UEFI → Xubuntu Desktop → Try Xubuntu**。接板载有线，或用 AX210 过渡联网，在 Live 安装 `mdadm`，打开桌面安装器并导入 `z8/autoinstall.yaml` 的本地副本。核本次识别到的三个 `ID_SERIAL`，放行等待点，再在 GUI 确认写盘。安装器在 FIT 上创建 EFI 和 `/boot`，并在 P4618 上建 RAID0/XFS 根。
3. 安装器完成并关机后拔掉 **Ventoy**，从 FIT 启动正式 Xubuntu Desktop。核 `/`、`/boot`、`/boot/efi` 的来源，定稿 fstab、Dracut 和 GRUB。再做 FIT 冷启和只读救援演练。准备 [FIT 救援入口](FIT-RECOVERY.md#i1-备好本机救援入口)并运行首份 `sudo z8-recovery-backup --refresh-boot`，然后[取一份机器外备份](FIT-RECOVERY.md#每个阶段留一份到另一台机器)。 [I1 详细命令](INSTALL.md#i1-安装-xubuntu-26041)

### I2 · 远程登录

优先设板载有线开机联网，用对应 MAC 做 DHCP 保留；没有网线时暂用 AX210，验 SSH 公钥与 tmux。重启停在本机登录画面，从另一台机器确认可以 SSH。再验通过 SSH 隧道访问 xrdp 的独立 Xfce 会话。完成后记录实际主机地址与客户端 Host 项。 [SSH 与 xrdp](../remote/README.md)

### I3 · 驱动、串流与复接 V100

仅 P1000 时装正式系统的 R580，重启核 ABI、驱动与 SSH。先用 P1000 的本机 X11 桌面验 Sunshine/Moonlight 和编码会话，再关机断电接回 V100。固件启动后用 T5 的 UUID 对照四卡，从 SanDisk 复制 [T5 的 CUDA 验机工具](INSTALL.md#算力坞验收)，快速复测 CUDA/NCCL 和 NVLink，确认串流仍由 P1000 编码。HC620 与 D4800X 到 I4 再接。 [R580 和 I3 复接](INSTALL.md#安装并锁定-nvidia-显卡驱动) · [Sunshine](../remote/README.md#sunshine)

### I4 · PMem 复用、建数据池与冷启演练

1. 在正式系统安装 PMem 两份 env 和两个单元，设置 T3 用过的启动参数，重启，确认 `/srv/pmem-model` 仍挂为 XFS DAX、两个 kmem 节点上线。PMem 已有的 goal、namespace、XFS 和权重直接沿用。 [正式系统恢复 PMem](PMEM.md#i4-在正式系统复用-pmem)
2. 先装存储工具并运行[介质错误演练](../storage/README.md#i4-介质错误演练)。关机断电接回 D4800X 和七块 HC620，光驱留 SATA7。启动后按 T4 序列号核盘，从 D4800X 整盘 by-id 新建九分区。按 `hybrid.tsv` 逐组初始化映射；SATA0–3 用 24 GiB 缓存，SATA4–6 用 80 GiB。仅后三个 mapper 加 p9 建 RAIDZ1，保存池 GUID。p5 留作 848 GiB 裸索引。 [I4 磁盘配置与建池](../storage/README.md#1-列出实体设备)
3. 启用 `data-other.mount` 和 `z8-cold.service`。先跑 `bash host/run-step.sh i4-cold-aging "$HOME/z8-burnin"` 和 `bash host/run-step.sh i4-cold-interleaved "$HOME/z8-burnin"`，再清零 32 个索引并启用分片。另对三盘 ZFS 做同步写和 scrub。分别冷启验证少一块冷盘、少一块 ZFS 盘、整卡 D4800X 缺席，每轮用 `bash host/run-step.sh i4-status` 收日志，恢复后确认 32 个分片和三盘池 ONLINE。冷库持续写不达门槛可用全 XFS 回退。I4 配好后运行 `sudo z8-recovery-backup` 并[取一份机器外备份](FIT-RECOVERY.md#每个阶段留一份到另一台机器)。 [I4 单元和演练](../storage/README.md#4-i4-安装存储依赖链) · [全 XFS 回退](../buildbarn/README.md#全-xfs-回退)

### I5 · Buildbarn 与 Buck2

先确认两路 kmem 和 I4 确定的存储路径。装 Docker、复制配置与单元、建目录（含模型卷上的热 CS 索引目录），然后安装默认每路 6 核的 CPU slice 和 runner drop-in，最后启用存储、调度器、Linux worker。按 [I5.3](../storage/README.md#i53-损坏对象24-分片降级和定时扫描) 演练坏对象与 24 分片、启用冷盘自检与取证定时器、记录首次全量构建的四盘水位。先在 max 验缓存读写和按需物化，再接 mini、Mac，验证 Linux 与 Darwin 各有一个实际构建。使用全 XFS 回退时，从其独立目录和 Compose 项目启动。I5 验完运行 `sudo z8-recovery-backup` 并[取一份机器外备份](FIT-RECOVERY.md#每个阶段留一份到另一台机器)。 [I5 部署顺序](../storage/README.md#5-i5-交给-buildbarn) · [CPU 分核](CPU-PLACEMENT.md#生成并安装) · [Buck2 客户端](../buildbarn/README.md#buck2-客户端) · [mini 与 Mac](../buildbarn/EDGE.md)

### I6 · 正式推理和 CLI

先验证模型卷来源与 DAX，再以 `jackywang` 复用 T5 权重，核实际 UID/GID 权限。在正式系统工作目录准备 llama.cpp 与 CUDA 用户态库，手动起服务跑探针和真实 harness 的 20 回合工具闭环。默认单槽 128K，显存不足按手册降档。只有明确需要并发才另验双槽。通过后写正式服务环境，使用 `z8-infer.service`，检查 API 真正就绪。各 harness 分别开工作树和 tmux；OMP/Pi/DSH 的官网 API 配置可独立验证。 [推理放行](../inference/README.md#i6-推理放行) · [启动服务](CPU-PLACEMENT.md#启停本地模型) · [CLI 与 DeepSeek API](../harness/README.md)

### I7 · 冷启、混合负载与交付

冷启后从另一台机器确认 SSH、存储和远程显示恢复。采用全 XFS 回退时，按 [I5 回退命令](../buildbarn/README.md#全-xfs-回退)启动相应 Compose 项目。手动启动 `z8-infer.service`，检查 API 就绪，再验证推理启停时普通任务的 CPU 集合变化，再用 I5 的 Buck2 与 I6 的推理档跑 **8 小时**混合负载。留存构建时间、首字延迟、decode、各盘和硬件错误增量、NUMA/PMem 计数及 `i5-cold-watermark` 记录的四盘最低空闲 cache 区数。完成后运行 `sudo z8-recovery-backup`，并[取一份机器外备份](FIT-RECOVERY.md#每个阶段留一份到另一台机器)，解除正式安装时的临时包 hold。 [I7 命令](BURN-IN.md#i7-正式安装后的整机混合负载) · [内核与驱动维护](INSTALL.md#固定-ga-轨道并试启新内核)
