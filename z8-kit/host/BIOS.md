# Z8 G4 槽位与 F10 配置

首轮装双 8269CY、散热和内存风道、12 条 DDR4、槽 4 的 P1000，网络优先接板载 RJ-45。没有网线时安装槽 7 的 AX210 并接两根天线。接显示器后按 Esc → F10。T1/T2 从独立介质启动，P4618 到 T4 才装。本机到货时多数部件已装好，先看下一节。拍下 `Main → System Information` 的板号和初始设置。按 [固件更新](FIRMWARE.md) 核 BIOS 与 ME，再按本页配置。AX210 过渡期间槽 7 保持 `Enable`。需要蓝牙时接内部 USB 线。

## 到货状态与首次 F10 实拍

2026-11 首次开机进 F10 拍到的状态。这台机到货时已装好双 CPU、DDR4、12 条 PMem、槽 1 的 P4618、槽 5 的 D4800X 和槽 7 的 AX210。拍完首批 F10 照片并改好设置后，12 条 PMem、P4618 和 D4800X 都已拆下，回到按阶段加装的顺序：T1、T2 只有 DDR4、槽 4 的 P1000、槽 7 的 AX210 和槽 2/3 的两块 x8/x8 直通板，PMem 在 T3 插回，P4618 和 D4800X 在 T4 装回。照片里有盘序列号，仓库公开，照片和序列号留在本机记录。

**四项与首装值不同，T1 先改。**

| 路径 | 到货值 | 首装值 |
|---|---|---|
| Advanced → Boot Options | Fast Boot 已勾选 | 取消 |
| Advanced → Boot Options | Network (PXE) Boot 已勾选 | 取消 |
| Advanced → System Options | SATA Controller RAID Mode 已勾选 | 取消，走 AHCI |
| Advanced → System Options | sSATA Controller 及其 RAID Mode 已勾选 | 取消 sSATA Controller，两个 sSATA 口都未使用 |

**拍到的其余项已符合首装值。**

- Boot Options：USB Storage Boot 开，After Power Loss 为 `Power Off`，Prompt on Memory Size Change 开，Legacy 未启用。
- System Options：`1TB Memory Cap = Auto`，PCIE MMIO Assignment Mode Auto，PCIe ACS Enable，PCIe Training Reset Disable。
- Performance Options：Turbo 与 HT 开，核心 All，NUMA 已勾选且灰显，SNC 关。
- Power Management Options：PCI Express Power Management 和 SATA Power Management 均未勾选。
- Port Options：SATA0–7、sSATA0–1、前后及内部 USB 全部 Enable。
- Built-In Device Options：Embedded LAN Controller (AMT) 和 Intel X722 Embedded LAN Port 都开，对应板载 I219-LM 与 X722 两个网口。

| 槽 | 到货实拍 |
|---|---|
| 1 | Enable，Gen3 (8Gbps)，Bifurcation Auto。启动项列表里有两个型号为 `7361454_ICRPC5ED2ORA6.4T` 的端点 |
| 2、3 | Enable，Bifurcation 已是 `x8x8`。未接坞，显示 Gen1 |
| 4 | Enable，Bifurcation Auto，显示 Gen1。T1 进 Linux 后用 `sudo lspci -vv` 看 P1000 的 `LnkCap` 与 `LnkSta` 再判断 |
| 5 | Enable，Gen3 (8Gbps)。启动项列表里的型号以 `INTEL SSDPD21K015TA` 开头，与 D4800X 1.5 TB 相符 |
| 6 | Disable，与空槽一致 |
| 7 | Enable，Gen2 (5Gbps)，AX210 |
| Personality Slot CPU0、CPU1 | Disable |

每个启用的槽都是 `Option ROM Download = Enable`、`Limit PCIe Speed = Auto`、`Resizable BARs = Disable`，并各有一项 `Intel VROC NVMe Raid (VMD n) = Disable`。启动项列表里 P4618 的两个端点显示同一段序列号，末尾的后缀被截断；T4 以 Linux 的 `ID_SERIAL` 为准，确认两个端点的值不同。

`Main → System Information` 显示两颗 Xeon Platinum 8269CY、192 GB ECC RDDR4 和 System BIOS `P60 v03.00 04/15/2026`。PMem 拔出后内存总量正是 12 条 DDR4。Advanced System Information 另记：Memory Speed 2666 MHz，Processor Stepping 7，MicroCode Revision `5003901`，ME Firmware Version 到货为 `11.22.94.2495`、T1 已更新到 `11.22.97.2675`，模式 AMT Disabled，System Board ID `81C7`。序列号、UUID、MAC 地址等留在本机记录。

**T1 已改并确认。** Fast Boot 与 PXE 已关，SATA 为 AHCI，sSATA Controller 已停用，AMT 为 Disable；Secure Boot Configuration、VTx 与 VTd、Remote Management Options 已核对。`PCIE MMIO Assignment Mode` 的选项是 `32 Bit`、`64 Bit`、`Auto`，这一项就是本机的 4G 以上地址分配开关，保持到货时能正常工作的 Auto。四张 V100 各有一个 16 GiB 的固定 BAR，只能放在 4G 以上；T5 接坞后若有卡认不全或内核报 BAR 分配失败，再改成 `64 Bit`。改之前先用 Replicated Setup 导出当前设置：`64 Bit` 会把 P1000 的地址窗口也挪到 4G 以上，万一开机没有画面，清 CMOS 后可以从 U 盘恢复全部设置。System Options 末尾的 `HP Application Driver` 保持未勾选，它只给 HP 的 Windows 软件用。

**仍待确认。** `Main → BIOS Event Log` 有无历史硬件事件、主显示槽位的选项位置，以及 TPM 状态。

**`Reset Factory Defaults on Battery Loss` 到货为 `Apply Default Settings`。** 二手机的纽扣电池寿命未知。电池失效后 F10 回到出厂默认，上面四项和槽 2/3 的 `x8x8` 都会丢，sSATA 也会重新启用。T1 配好后先执行 `Main → Save Custom Defaults`，再用 `Main → Replicated Setup` 把设置导出到 U 盘。设置丢失后用 `Apply Custom Defaults and Exit` 一步恢复 Main 和 Advanced 两页，Security 页的项要另行核对。条件允许时换一颗新的 CR2032。

PMem 的料号、原配置和插回时的注意事项见 [PMem 的到货状态](#pmem-的到货状态)。

## 板上槽位

| HP 槽号 | 实际设备 | F10 目标与 Linux 验证 |
|---|---|---|
| 1 | P4618 | `Bifurcation = Auto`，双 CPU 且未装 Thunderbolt 3 卡时为 Gen3 x8。预期卡上交换芯片为一个 x8 上行口、两个 x4 下行口，连接两个各约 3.2 TB 的 Intel NVMe。按 [T4 的 PCIe 链路检查](BURN-IN.md#p4618-链路与双控制器) 验收 |
| 2 | x16→x8/x8 直通板 | Gen3 x16，Bifurcation 选 x8/x8，两张 V100，各 x8 |
| 3 | x16→x8/x8 直通板 | Gen3 x16，由第二颗 CPU 提供，Bifurcation 选 x8/x8，两张 V100，各 x8 |
| 4 | Quadro P1000 | 主显示设备，显示器/虚拟头接在这里 |
| 5 | D4800X 1.5 TB U.2 + PCIe 转接卡与风扇 | 硬改为单口 Gen3 x4，槽 5 直连 CPU0；核实际路径、序列号和散热 |
| 6 | 空，槽 5 转接卡和风扇占用相邻空间 | 保持空槽 |
| 7 | AX210 转接卡（无线过渡） | x4 槽，Wi-Fi 实际 x1；蓝牙需 USB 线/接头。有线验收后关机拔卡，槽位空出 |

主机验收阶段算力坞断电，四根 PCIe 线断开。主机通过后再逐卡接上、复核槽 2/3 各枚举两个 endpoint。记录 GPU UUID、BDF、`/sys/bus/pci/devices/<BDF>/numa_node` 和 `nvidia-smi topo -m`。用 CUDA H→D 传输时读当前宽度/速率。若此 BIOS 版本只显示 Auto 或其他分叉组合，记录选单原文和直通卡走线，按每槽两张都为 x8 验证。 [HP QuickSpecs](https://h30434.www3.hp.com/psg/attachments/psg/Business-PC-Workstation-POS/44704/1/Z8%20G4%20Quickspecs%20v67.pdf) · [Z8 G4 F10 实例，含 Slot Settings](https://medwrks.com/servicedocs/ge-ct/optima/5366638-8ENDiscoveryandOptimaRTServiceMethods/t_Z8G4-Host-PC-BIOS-Setup-and-CMOS-Battery-Replacement_BJ_210315_Y02.html)

## F10 首装值

| 路径 | 首装值 |
|---|---|
| Advanced → Boot Options | USB Storage Boot Enable，Fast Boot Disable，Network (PXE) Boot Disable，POST 消息打开（若有），Prompt on Memory Size Change Enable。After Power Loss 固定 `Power Off`，手动按算力坞的上电顺序启动。验机时用 F9 选 Ventoy 或已装好的 SanDisk。I1 装好正式系统后，UEFI Boot Order 再以 Samsung FIT 上的 Ubuntu 引导项为首选 |
| Advanced → Secure Boot Configuration | `Configure Legacy Support and Secure Boot` 选 `Legacy Support Disable and Secure Boot Disable`。保存后若出现 Boot Mode Change，输入屏幕显示的确认码 |
| Advanced → System Options | SATA Controller Enable，SATA Controller RAID Mode Disable（AHCI），sSATA Controller Disable，PCIE MMIO Assignment Mode Auto，PCIe Training Reset Disable，`1TB Memory Cap = Auto`（验机和正式运行固定值），PCIe ACS 保持当前默认 |
| Advanced → Port Options | SATA 0–7 全 Enable，前后 USB 打开，AX210 需要蓝牙时打开对应内部 USB；拔卡后可拔该内部 USB 线。本机另列 sSATA0、sSATA1 两个口，均未使用，随 sSATA Controller 一起停用。Thunderbolt 两项保持默认，整机不装 Thunderbolt 卡 |
| Advanced → Graphics Configuration | Primary Graphics Device 选择 Slot 4 P1000 |
| Advanced → Slot Settings | Slot 1 `Bifurcation = Auto`，Slot 2/3 `Bifurcation = x8x8`（本机选单原文）。`Limit PCIe Speed = Auto`，问题定位时仅对受影响槽试 Gen3 或 Gen2 作信号对照。各槽的 `Intel VROC NVMe Raid = Disable`，NVMe 阵列由 Linux mdadm 管理。各槽 `Resizable BARs` 保持 Disable：P1000、V100 和两块 NVMe 都不用可调整 BAR，V100 的 16 GiB 显存 BAR 是固定大小，由 `PCIE MMIO Assignment Mode` 决定能否放到 4G 以上；T5 的内核日志若报 BAR 分配失败再回来看这两项。各槽 `Option ROM Download` 保持 Enable：槽 4 的 P1000 靠卡上的固件在开机阶段出画面，关掉后 POST 和 F10 会黑屏；其余槽关掉没有收益。T5 接坞后若 POST 明显变慢或卡住，只把槽 2/3 改成 Disable 作对照，Linux 驱动不依赖固件执行这段 ROM。Slot 6 与两个 Personality Slot 保持 Disable |
| Advanced → Performance Options | 验机和正式部署固定 `Non-Uniform Memory Access = Enabled`、`Sub-NUMA Clustering = Disabled`。HT Enabled，所有 cores Enabled，Turbo Enabled。DDR4 走 JEDEC 自动，记录混插后的实际速率。本机 NUMA 项已勾选并灰显。Isoc Mode Disable、Workload Configuration Balanced、Performance Control Performance Mode 保持到货值 |
| Advanced → Power Management Options | `PCI Express Power Management = Disable`，`SATA Power Management = Disable`。T1 一次设好，验机和正式运行沿用。Intel Speed Select Disabled、Hardware P-States Enable、`OS Controls EPB`、Idle Power Savings Extended 保持到货值 |
| Advanced → Built-In Device Options | Embedded LAN Controller (AMT) 与 Intel X722 Embedded LAN Port 保持勾选。两项 Idle Fan Speed 增量到货为 0；T4 的 NVMe 温度偏高时调高 `Increase PCIe Idle Fan Speed(%)` 再测 |
| Security → Security Configuration → System Security | Virtualization Technology (VTx) = Enable，Virtualization Technology for Directed I/O (VTd) = Enable。部分版本将这两项列在 Advanced → System Options |
| Advanced → NVDIMM Management | 第一次混插只查 12 条模块、固件和当前状态。同一页的 `Update Firmware on NVDIMMs` 按 [固件手册](FIRMWARE.md#t3-pmem-100) 使用。保留 `NVDIMM Configuration`，跳过 `Apply NVDIMM Configuration`。App Direct goal 在 Xubuntu 提交 |
| Security → NVDIMM Security Freeze | 按 [T3 的 PMem 流程](PMEM.md#t3-配置-app-direct) 将 `Unfreeze NVDIMMs for this number of boot sequences` 暂设为 `5`，保存后从 F9 启动临时 Xubuntu |

具体项目显示取决于 BIOS 版本和已装设备。以上区分 HP F10 真实项目与要在实机选择的值。 [HP Service Guide，F10 与 POST](https://kaas.hpcloud.hp.com/pdf-public/pdf_6792418_en-US-1.pdf) · [HP Z8 G4 F10 实例](https://medwrks.com/servicedocs/ge-ct/optima/5366638-8ENDiscoveryandOptimaRTServiceMethods/t_Z8G4-Host-PC-BIOS-Setup-and-CMOS-Battery-Replacement_BJ_210315_Y02.html)

**从 T1 起固定 `1TB Memory Cap = Auto`。** 这是 HP 的平台兼容选项。HP QuickSpecs 分别列了基础档 CPU 的每路 1 TiB 容量上限，以及部分 AMD 显卡配置的整机 1 TiB 兼容限制。本机用 NVIDIA P1000，铭牌容量每路 `96 GiB DDR4 + 768 GiB PMem = 864 GiB`。HP 的公开资料未给出 Z8 G4 上 Auto 的完整触发规则。T3 用 `ipmctl show -socket` 和 `ipmctl show -region` 核对 8269CY 的实际每路上限与两路 App Direct 映射。如果容量异常，先按 PMem 手册查 12 条枚举、每路容量和 goal，再定位原因。只有两路模块枚举完整、goal 正确而实际映射疑似受整机 1 TiB 限制时，才用 F10 的 `Disable` 冷启对照，保存两次 socket 和 region 报告。 [HP Z8 G4 QuickSpecs，第 15 页](https://h30434.www3.hp.com/psg/attachments/psg/Business-PC-Workstation-POS/44704/1/Z8%20G4%20Quickspecs%20v67.pdf#page=15) · [Z8 G4 的 Auto 实例](https://medwrks.com/servicedocs/ge-ct/optima/5366638-8ENDiscoveryandOptimaRTServiceMethods/t_Z8G4-Host-PC-BIOS-Setup-and-CMOS-Battery-Replacement_BJ_210315_Y02.html) · [ipmctl 每路容量字段](https://docs.pmem.io/ipmctl-user-guide/module-discovery/show-socket)

**PCIe 和 SATA 电源管理均从 T1 设为 `Disable`。** 外接算力坞的 PCIe 线缆和七盘阵列优先保证链路稳定，验机和正式运行都用同一设置。`sudo lspci -s <BDF> -vv` 的 `LnkCtl` 记录实际 ASPM 状态；`cat /sys/class/scsi_host/host*/link_power_management_policy` 记录 Linux 实际 SATA 链路策略。若仍出现低功耗策略，定位对应控制器和 Linux 策略来源。七块 HC620 保持常驻旋转，交错起转按下文 P11／PUIS 处理。T4/T5 和 I7 原有的负载及错误检查照常执行。 [HP 服务手册，第 73 页](https://kaas.hpcloud.hp.com/pdf-public/pdf_6792418_en-US-1.pdf) · [Linux 7.0 ASPM](https://github.com/torvalds/linux/blob/v7.0/drivers/pci/pcie/aspm.c#L228-L280) · [Linux 7.0 SATA 链路策略](https://docs.kernel.org/7.0/scsi/link_power_management_policy.html) · [HC620 电源模式规范](https://documents.westerndigital.com/content/dam/doc-library/en_us/assets/public/western-digital/product/data-center-drives/ultrastar-dc-hc600-series/product-manual-ultrastar-dc-hc620-sata-spec.pdf)

Secure Boot 关闭作为日常配置。保留 UEFI Boot Order，F9 用 Ventoy 的 UEFI 项启动 Memtest86+ 或 Xubuntu Live，验机时选 SanDisk 的 UEFI 引导项，正式安装后选 FIT 的 UEFI 引导项。装完后以 `test -d /sys/firmware/efi` 和 `LC_ALL=C mokutil --sb-state` 分别确认 UEFI 和 `SecureBoot disabled`。如果之后更新 BIOS 或重置设置，在第一次开机时重新核对这两项。 [HP 固件设置路径](https://support.hp.com/ee-en/document/ish_9642671-9641393-16) · [Ubuntu Secure Boot 文档](https://documentation.ubuntu.com/security/security-features/platform-protections/secure-boot/)

槽 1 留给 P4618，整机不装 Thunderbolt 3 扩展卡。P4618 卡上的交换芯片负责把单条 x8 上行分给两个 x4 控制器。若主机把槽 1 拆成 x4/x4，交换芯片的单条上行最多只能按 x4 协商，即使两块 NVMe 仍能枚举，共享上行带宽也会减半。GE 维修手册的 BIOS 2.47、2.68 实例里，Slot 1 有 `Bifurcation`，Slot 5/7 没有，`Intel VROC NVMe RAID` 列在 `Personality Slot CPU0` 下。本机实拍 Slot 1–4 都有 `Bifurcation`，Slot 5/7 没有，VROC 按槽列出。 [HP 白皮书，第 7 页](https://www.workstation4u.de/hp-z8-g4-technichalwhitepaper.pdf#page=7) · [GE BIOS 实例](https://medwrks.com/servicedocs/ge-ct/optima/5366638-8ENDiscoveryandOptimaRTServiceMethods/t_Z8G4-Host-PC-BIOS-Setup-and-CMOS-Battery-Replacement_BJ_210315_Y02.html) · [Broadcom PEX 8718 拓扑](https://docs.broadcom.com/doc/12351848)

## NUMA 与 SNC

| F10 设置 | 这台双路机器的含义 |
|---|---|
| `Non-Uniform Memory Access = Enabled`，`Sub-NUMA Clustering = Disabled` | T1/T2 预期 Linux 看到两个带 CPU 的 DRAM 节点，每颗 8269CY 对应标称 96 GiB。CPU0 可以读写 CPU1 的 DRAM，跨路请求走 UPI。Linux 可优先本地分配，也可让一个进程同时使用两路。 |
| `Non-Uniform Memory Access = Disabled` | HP 另列 Memory Node Interleave 模式。对称 DDR4 下预期将双路交错呈现成一个 DRAM 节点，实际用 `numactl -H` 核对。两颗 CPU 和 UPI 仍在，跨路访问延迟也仍在，Linux 的 socket 级绑内存会失去原有边界。 |
| `Sub-NUMA Clustering = Enabled` | SNC 是 Sub-NUMA Clustering。启用两簇模式后，每颗 CPU 内部的两套内存控制器分别与附近的核心和 L3 切片组成一个 NUMA 域，每域三个 DDR4 通道。双路预期可见四个带 CPU 的 DRAM 域，适合将线程与数据一起绑到同一域做延迟优化。混插 PMem 后的 region 与 PCIe 归属需另验。 |

**从 T1 起固定开 NUMA、关 SNC。** T2 可逐路对 96 GiB DDR4 施压，T3 可按 socket 核 PMem 归属和慢层去向。正式运行时由推理启动器在两路 DDR4 之间交错分配，CPU/HT 分核按物理 socket 与同核线程生成。 [T3 拓扑验收](PMEM.md#核对双路-numa-拓扑) · [运行时内存策略](CPU-PLACEMENT.md#运行时的-numa-内存策略) · [Z8 G4 F10 菜单实例](https://medwrks.com/servicedocs/ge-ct/optima/5366638-8ENDiscoveryandOptimaRTServiceMethods/t_Z8G4-Host-PC-BIOS-Setup-and-CMOS-Battery-Replacement_BJ_210315_Y02.html) · [HP QuickSpecs，第 21 页](https://h30434.www3.hp.com/psg/attachments/psg/Business-PC-Workstation-POS/44704/1/Z8%20G4%20Quickspecs%20v67.pdf#page=21)

## 内网主机的安全与虚拟化设置

在无坞的主机阶段应用。F10 路径以该机 BIOS 的实际显示为准。HP 的 Z8 G4 F10 实例把 VTx/VTd 列在 Security，HP 服务手册也列出了 Advanced 下的路径。若改变 VTx 或 VTd，保存后关机再上电。 [Z8 G4 F10 菜单实例](https://medwrks.com/servicedocs/ge-ct/optima/5366638-8ENDiscoveryandOptimaRTServiceMethods/t_Z8G4-Host-PC-BIOS-Setup-and-CMOS-Battery-Replacement_BJ_210315_Y02.html) · [HP 服务手册，第 6 章](https://kaas.hpcloud.hp.com/pdf-public/pdf_6792418_en-US-1.pdf)

| F10 项目 | 设定 |
|---|---|
| Virtualization Technology (VTx) | **Enable**。保留 KVM 等虚拟机的 CPU 硬件加速。Xubuntu 裸机执行 Buck2、Docker Engine 和 CUDA，基线按这些进程的实际吞吐评估 |
| Virtualization Technology for Directed I/O (VTd) | **Enable**。保留设备 DMA remapping 和未来的 VFIO 能力。DMA Protection、Pre-boot DMA Protection 和 PCIe ACS 首轮保留固件默认，接坞后按下面的流程定位 PCIe P2P |
| Trusted Execution Technology (TXT)、Ready BIOS for Device Guard Use | 保持 Disabled 或未配置。TXT 可能约束 VTx、VTd 和 TPM 的可选状态 |
| TPM Embedded Security | 这套 XFS 根没有配置 TPM 解锁。确认没有现有 TPM 绑定密钥后，可设 `TPM State = Disable`。`Clear TPM` 保持 No |
| Advanced → Remote Management Options | `Intel Active Management Technology (AMT) = Disable`，`USB Key Provisioning Support = Disable`。保留 `Intel Management Engine (ME) = Enable`。板载 LAN 保持 Enable，首装和日常远程访问优先走有线；缺网线时用 AX210 |
| Advanced → Boot Options / HP Sure Recover | `Network (PXE) Boot = Disable`，`USB Storage Boot = Enable`。如有 `HP Sure Recover`，设 Disable，OS 恢复使用已验证的独立救援 U 盘 |
| Security → BIOS Sure Start / Utilities | 保留 Sure Start 的固件恢复及 `System Management Command` 的默认值。二者分别负责 BIOS 恢复和维修时重置安全设置 |
| Security → Utilities → Hard Drive Utilities | DriveLock 保持未启用，保证冷启无需逐盘输密码。PMem 的 NVDIMM Security Freeze 单独按 App Direct 初始化步骤临时解冻。同一页的 NVDIMM Transparent Unlock 和 NVDIMM Passphrase Reset 保持未配置，`ipmctl` 报某条模块 Locked 时再回到这里。Absolute Persistence Module 到货为 Inactive，保持 |

主机冷启动后记录 CPU 虚拟化标志与内核 IOMMU 状态。VT-x 可用时 `lscpu` 显示 `Virtualization: VT-x`，`vmx` 出现在 CPU flags。仅看到 `DMAR` 表存在时，结合内核日志判断翻译是否启用。

```bash
LC_ALL=C lscpu | grep '^Virtualization:'
grep -m 1 -ow vmx /proc/cpuinfo
cat /proc/cmdline
sudo journalctl -k -b --no-pager | grep -Ei 'DMAR|IOMMU|Default domain'
```

### 接坞后的 PCIe P2P

先按 [算力坞验收](INSTALL.md#算力坞验收)在正式默认的内核参数下确认六对 NVLink、NCCL 和数据正确性。只在定位 **裸机 GPU 间 PCIe P2P** 路径问题时，按 NVIDIA 指引额外做一次 Intel IOMMU 关闭的对照。可在机旁用 GRUB 编辑当次启动项，按 `e` 后在 `linux` 行末追加 `intel_iommu=off`，按 `Ctrl-x` 或 `F10` 启动。BIOS 的 VT-x 和 VT-d 可继续启用。这个内核参数会关闭该次启动的 Intel DMA remapping。用 `/proc/cmdline` 和内核日志确认，再单独跑有问题的两卡路径并记录结果。重启回默认参数，推理仍按默认参数的测试结果启用 peer。若 PCIe 路径仍异常，再按 GPU 所在桥检查 `ACSCtl`，一次只变一个设置。

```bash
nvidia-smi topo -m
nvidia-smi topo -p2p n
nvidia-smi topo -p2p p
sudo lspci -Dvv | grep -E '^[[:xdigit:]]{4}:|ACSCtl:'
```

用 NVLink P2P 矩阵、NCCL 日志和实测数据确认 NVLink，PCIe 能力矩阵用于定位 PCIe 路径。 [NVIDIA NCCL 排查](https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/troubleshooting/gpu_troubleshooting.html) · [NVIDIA SMI 拓扑命令](https://docs.nvidia.com/deploy/nvidia-smi/index.html) · [Linux 内核参数](https://docs.kernel.org/admin-guide/kernel-parameters.html)

## 内存分两轮装，DDR4 原位保留

CPU0、CPU1 各有一套编号 1–12 的 DIMM 槽。先在主板上找 `CPU0-DIMM1`、`CPU1-DIMM1` 等丝印，再按下表装。机盖图上的 1–24 若标作 **Load Order**，表示插入先后；下表按每颗 CPU 的 **DIMM 槽号**。

| 操作 | CPU0 | CPU1 |
|---|---|---|
| 第一轮只装 DDR4 | 1、3、5、8、10、12 各插一条 16 GiB，合计 96 GiB | 1、3、5、8、10、12 各插一条 16 GiB，合计 96 GiB |
| DDR4-only 两轮测试通过后加 PMem | 2、4、6、7、9、11 各加一条 128 GiB PMem | 2、4、6、7、9、11 各加一条 128 GiB PMem |

T1 用 SanDisk 上的临时 Xubuntu 26.04.1 短跑双路 CPU。T2 从 F9 进 Ventoy 菜单启动 Memtest86+，通过后换回临时系统完成 4 小时 DDR4 压测。随后关机断电，**DDR4 原位不动，直接把 PMem 插进空槽**。两边各六条 DDR4 加六条 PMem，共 24 条。第一次混插启动先看 F10 是否认全，再在 [Xubuntu 26.04.1 提交 App Direct goal](PMEM.md)。装每条时记位置和序列号，便于定位 DIMM 错误。 [HP QuickSpecs，第 22 页双路 192 GB](https://h30434.www3.hp.com/psg/attachments/psg/Business-PC-Workstation-POS/44704/1/Z8%20G4%20Quickspecs%20v67.pdf#page=22) · [HP Optane 白皮书，第 22 页 24 条混插](https://h10032.www1.hp.com/ctg/Manual/c06527302.pdf#page=22)

### PMem 的到货状态

到货时 12 条 PMem 已插在两路各 DIMM 2/4/6/7/9/11，F10 列表每条 Capacity 126 GB。现已全部拔出，T1、T2 按上表只装 DDR4，T3 再插回。

- **料号。** 11 条是 `NMA1XBD128GQS`，后补的一条是 `NMA1XXD128GQS`。两种都是 100 系列的 128 GB 模块，尾缀 `QS` 是样品标识，零售量产料号是 `NMA1XXD128GPS`。
- **原配置是 Memory Mode。** 原有 11 条的 Volatile Size 为 126 GB、Persistent Size 为 0，系统把 PMem 当主内存、DDR4 当缓存。后补的那条到货时在 CPU1-DIMM4，两项都是 0，尚未配置。
- **固件混版。** 9 条 `01.02.00.5310`，2 条 `5355`，后补的一条 `5386`。是否统一见 [固件手册](FIRMWARE.md#t3-pmem-100)。

T3 插回时每路仍用 DIMM 2/4/6/7/9/11，哪条插哪个槽不限，记下每个槽的序列号。模块带着原来的配置，首次混插开机有两种可能：固件照旧把它们映射成主内存，`free -h` 显示 PMem 容量，POST 按 `Prompt on Memory Size Change` 提示确认；或者因位置变化显示未配置。两种情况都直接进临时系统盘点并提交 App Direct goal。goal 生效、系统内存回到约 192 GiB 之后，再跑混插后的 Memtest86+。

## SATA0–7、硬盘识别和起转

SATA0–3（冷 CAS）用四个原装 3.5 英寸托架。SATA4–6（ZFS）用可直通的双 5.25 英寸三盘架或外部固定盘架。先量实际 175 mm 标称深度和连接器空间，确认原装光驱在独立的 9.5 mm 位时两个 5.25 位都可用。选择盘架时保留进风与拉线空间，必要时把后三盘分到外部独立供电且有明确启停顺序的盘架。数据口仍分别接主板 SATA0–6，光驱 SATA7。先给每根线两端贴 SATA 号，再装盘并记序列号。 [HP QuickSpecs，Expansion Bays](https://h30434.www3.hp.com/psg/attachments/psg/Business-PC-Workstation-POS/44704/1/Z8%20G4%20Quickspecs%20v67.pdf)

### 先确认系统认盘

先接一块 SATA 版 HC620 到主板 SATA0，断电冷启。成功后依次接 SATA0–3 的四块、SATA0–6 的七块，最后接 SATA7 的光驱。每个配置做至少三次冷启。每轮检查 Linux 是否列齐已接硬盘、序列号是否正确，留意 SATA 链路重置、反复协商和掉盘。SATA0 是主板数据接口编号，Linux 的 `ataN` 和 `/dev/sdX` 以当次枚举为准。按盘身序列号记录物理 SATA 口，建池时用稳定的 `/dev/disk/by-id/ata-…`。 [HP 服务手册，POST 904 SATA 规则](https://kaas.hpcloud.hp.com/pdf-public/pdf_6792418_en-US-1.pdf)

```bash
lsblk -d -o NAME,MODEL,SERIAL,TRAN,ZONED,LOG-SEC,PHY-SEC
sudo journalctl -kb -o short-monotonic | grep -Ei 'ahci|ata[0-9]+:.*(link up|SATA|reset|failed)'
```

### 认盘以后，检查能否用于 dm-zoned

HC620 把盘面划成许多区，大部分区要求从写入指针起顺序写。**ZAC** 是 SATA 盘报告这些区、执行相关操作的一套命令。这里要确认 Linux 经过实际的 AHCI 端口、数据线和盘架，能识别这条写入限制并读到盘区表。确认后每对 HC620 + D4800X 交给 dm-zoned。SATA0–3 切成裸冷库分片，SATA4–6 交给 ZFS。下列查询只读。 [Linux dm-zoned 说明](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-zoned.html)

1. 在上面的 `lsblk` 找到 HC620 的序列号和设备名。按本批 SATA 4Kn 14 TB 配置，七盘都应报告 `TRAN=sata`、`ZONED=host-managed`、`LOG-SEC=4096` 和 `PHY-SEC=4096`。后两项分别是系统寻址扇区和物理扇区的字节数。WD 的 14 TB SATA 4Kn 料号为 `HSH721414ALN6M0` 和 `HSH721414ALN6M4`。看到 `512 / 4096` 时先核盘身料号和订单。 [WD HC620 规格表](https://documents.westerndigital.com/content/dam/doc-library/en_us/assets/public/western-digital/product/data-center-drives/ultrastar-dc-hc600-series/data-sheet-ultrastar-dc-hc620.pdf)
2. 把下面的 `/dev/sdX` 换成该序列号对应的**整盘**，例如 `/dev/sdb`。第一条从盘头查两个区。第二条从标准 14 TB HC620 的第 525 个区开始查两个区。WD 手册给出盘头 524 个普通区、每区 256 MiB，所以第二条的偏移是 `524 × 256 MiB ÷ 512 B = 274726912`。这里的偏移单位由 blkzone 固定为 512 B，即使盘是 4Kn 也用这个数。

   ```bash
   disk=/dev/sdX
   sudo blkzone report -c 2 "$disk"
   sudo blkzone report -o 274726912 -c 2 "$disk"
   ```

   典型结果是盘头 `CONVENTIONAL`（可随机读写）、后段 `SEQ_WRITE_REQUIRED`（按各区写指针写入）。单用 `-c 32` 只读前 32 个区，在 HC620 上会全是 conventional 区。若这批盘布局不同，用 `sudo blkzone report -c 1024 "$disk" | awk '/SEQ_WRITE_REQUIRED/ && !seen++'` 找前 1,024 个区里第一条顺序区记录。若 `ZONED` 是 `none`、无法查区，先试主板 AHCI 直连并核型号和链路，再继续建池。 [盘头区在混合方案里的用途](../storage/README.md#hc620-盘头随机写区在混合方案里的用途) · [WD HC620 §4.4.3](https://documents.westerndigital.com/content/dam/doc-library/en_us/assets/public/western-digital/product/data-center-drives/ultrastar-dc-hc600-series/product-manual-ultrastar-dc-hc620-sata-spec.pdf#page=23) · [blkzone 手册](https://man7.org/linux/man-pages/man8/blkzone.8.html)

3. `sudo smartctl -x "$disk"` 保存这块二手盘的健康、自检与错误记录。先看型号/序列号、总体健康、已有自检结果、待定或不可校正扇区，再看链路 CRC 错误是否增长。长自检另按 [拷机手册](BURN-IN.md) 运行。`sudo hdparm -I "$disk"` 是补查硬盘自己上报的型号、功能和设置。通常在型号、接口或是否启用上电待机有疑问时才用。`Power-Up In Standby feature set` 出现在支持列表里表示支持，前面的 `*` 才表示该功能启用。 [smartctl 手册](https://manpages.ubuntu.com/manpages/resolute/man8/smartctl.8.html) · [hdparm 手册](https://manpages.ubuntu.com/manpages/resolute/man8/hdparm.8.html)

### 盘完全不转时看 P3，多盘同时起转时再看 P11 与 PUIS

**P3 和 P11 都是硬盘宽的 15 针 SATA 供电插头上的针脚。** 主板 SATA0–7 用的是窄的 SATA 数据插头。

| 术语 | 实际意思 | 这台机何时用到 |
|---|---|---|
| **PWDIS / P3** | Power Disable。部分 HC620 的第 3 针是电源禁用信号。旧线束若在 P3 持续送 3.3 V，这些盘的控制电路会停用，马达也不转 | 某块盘完全不转、Linux 也没有盘时，关机后先用已知正常的供电和 SATA0 对照。若怀疑 PWDIS，用明确兼容这台电源、P3 不送 3.3 V 且额定电流足够的供电线或盘架，保持同一条数据线再试 |
| **P11 / 交错起转** | 供电插头第 11 针。它可参与 SATA 交错起转控制，也可能用于硬盘活动灯。整机是否分批起转还取决于供电接线、背板与控制器 | HP 公开 F10 手册未确认这台 Z8 G4 有交错起转选项。只有要确认启动电流或起转顺序时才测。日志里的 `stag` 只是控制器的能力位，`link up` 是数据链路时刻。实际起转看 12 V 启动电流随时间的变化 |
| **PUIS** | Power-Up In Standby，上电待机。硬盘电子部分上电，盘片等主机发 ATA 起转命令才转。设置跨断电保留 | 首装保持原状。七盘能稳定冷启就无需启用。盘已有该模式且出现识别问题时，先用一台确认能发起转命令的主机检查，别一次修改七盘 |

按七盘可能同时起转估算线束负担。WD 表 16 较高的测试峰值为每盘 12 V 1.99 A、5 V 0.51 A，七盘相加约 **13.93 A / 3.57 A**，光驱另计。4+3 分路时 12 V 分别约 7.96 A 和 5.97 A，共用上游连接器仍要承受两组之和。先查线束额定值并完成分批冷启。需要确认峰值时，用可捕获短时变化的 DC 电流探头记录。 [WD HC620 表 16、§10.10、§10.16.2](https://documents.westerndigital.com/content/dam/doc-library/en_us/assets/public/western-digital/product/data-center-drives/ultrastar-dc-hc600-series/product-manual-ultrastar-dc-hc620-sata-spec.pdf) · [WD PWDIS 说明](https://documents.westerndigital.com/content/dam/doc-library/en_us/assets/public/western-digital/collateral/tech-brief/tech-brief-western-digital-power-disable-pin.pdf)
