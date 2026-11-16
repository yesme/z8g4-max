# 首装固件更新

先用到货版本确认硬件能稳定枚举，记录板卡标签、料号、序列号和当前版本。确认某项需要升级时，选覆盖该料号与平台的厂商包，保存链接和校验值，一次处理一个部件，再冷启核实。把正式拷机放在计划使用的固件上。以下是截至 2026 年 11 月核对到的公开版本，实际是否适用以到货标签与工具输出为准。

## T1. HP BIOS、ME 与 CPU 微码

1. 只装 T1 清单的硬件。首次稳定 POST 后，在 `F10 → Main → System Information → Advanced System Information` 记录 System Board ID、产品 SKU、BIOS、ME Firmware Version 和 MicroCode revision。用 `Main → Replicated Setup → Backup current settings to USB device` 导出原设置。两颗 8269CY 若在现有 BIOS 下无法 POST，先用准系统原来可启动的 HP 支持 CPU 进入 F10 更新，再装回这对 CPU。
2. HP 2026 年 3 月公告为 Z8 G4 列出 **BIOS 2.96**，Linux 包 **SP161781**，Windows 包 **SP161769**。如果版本更旧且包确认对应板号，在 T1 更新。用另一台电脑下载。按包内说明准备单独 FAT32 U 盘，或用 HP 的 `HpBiosUpdRec64.exe` 创建 Recovery USB。F10 选择 `Main → Update System BIOS → Update BIOS Using Local Media`，核对目标版本后更新。等待完成重启，进 F10 核实版本并重新逐项应用本机配置。已有同版或更高的 HP 正式版本就保留。 [HP BIOS 公告](https://support.hp.com/ee-en/document/ish_14446333-14446355-16/hpsbhf04100) · [Z8 G4 服务手册](https://kaas.hpcloud.hp.com/pdf-public/pdf_6792418_en-US-1.pdf) · [HP 本地刷写和恢复](https://h30434.www3.hp.com/psg/attachments/psg/Business-PC-Workstation-POS/34410/1/BIOS%20Flash%20Update.pdf)
3. ME 单独看 F10 的版本，或在临时 Xubuntu 查 `cat /sys/class/mei/mei*/fw_ver`。HP 可公开核对的 Z8 G4 ME 包是 **11.22.94.2495**，Linux **SP148857**，Windows **SP148855**。BIOS 更新后若仍低于该版本，并且产品号和 ME 分支匹配，可在 T1 按该 SoftPaq 的说明单独更新、重启再查。ME 保持 Enabled，AMT 按现有方案关闭。 [HP ME 公告](https://support.hp.com/us-en/document/ish_9022560-9022595-16) · [Linux ME 版本接口](https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-class-mei)
4. 8269CY 的 Linux 微码随 Ubuntu `intel-microcode` 包早期加载。临时和正式 Xubuntu 都安装，重启后用 `awk '/^microcode/ {print $3}' /proc/cpuinfo | sort -u` 记录。三星 DDR4 ECC RDIMM 直接验条和拷机，保留原厂 SPD。AX210 的 Wi-Fi 和蓝牙固件来自 `linux-firmware-intel-wireless`，由驱动加载。 [Ubuntu 微码](https://packages.ubuntu.com/resolute/intel-microcode) · [Ubuntu Intel 无线固件](https://packages.ubuntu.com/resolute/linux-firmware-intel-wireless)

## T3. PMem 100

先读 12 条的 Active 和 Staged 版本、模块标签及健康状态。HP 对 Z8 G4 给出 **BIOS 2.35 与 PMem 01.02.00.5417 或更新**的最低组合。若 12 条同版、达到最低版本、可管理且诊断正常，直接进入 App Direct 测试。若低于最低版、同批混版，或厂商公告明确修复当前故障，再按标签上的 OEM 和料号找适用包。Intel 建议同机版本一致。查到 Dell PowerEdge、HPE Gen10、Lenovo ThinkSystem 均发布过 `01.02.00.5446`，这些公告各自限定支持系统或模块，手头 Z8 与 DIMM 标签仍需核对。未找到匹配包时，低于 HP 最低版的模块优先换成达到基线的同批料号，已达到基线的混版模块先跑 FW 诊断并记录结果。 [HP Optane 白皮书，第 6 页](https://h10032.www1.hp.com/ctg/Manual/c06527302.pdf#page=6) · [Intel PMem 启动指南](https://cdrdv2-public.intel.com/841964/Intel_Optane_Persistent_Memory_Start_Up_Guide.pdf) · [Intel 固件获取与更新](https://www.intel.com/content/www/us/en/support/articles/000032996/technologies/memory-and-storage.html) · [HPE 固件适用范围](https://support.hpe.com/connect/s/softwaredetails?collectionId=MTX-5618354fdcd14e80&language=en_CA)

**本机到货实拍。** 9 条 `01.02.00.5310`，2 条 `01.02.00.5355`，1 条 `01.02.00.5386`。三个版本都低于 5417，且同机混版，按上面的规则属于要处理的情形。先抄 12 条标签上的厂商和料号，再找覆盖该料号的包，统一到同一版本。十二条全部低于基线，换条不现实；找不到匹配包就保留到货版本，把 FW 诊断结果和 T3 的全部写读校验记入基线，出现与固件相关的故障再处理。这批模块在到货版本下已能以 Memory Mode 启动。

```bash
sudo ipmctl show -dimm
sudo ipmctl show -d PartNumber,SerialNumber,DeviceLocator -dimm
sudo ipmctl show -dimm -firmware
sudo ipmctl start -diagnostic FW
```

确需更新时，在 [PMem 配置](PMEM.md) 的 F10 临时解冻后、提交 App Direct goal 前操作。先选一条与镜像匹配的 DIMM，将占位符换成实际 ID 和文件路径。`-examine` 验镜像并显示版本。通过后执行第二条 `load` 写入待生效区，核 `StagedFWVersion`。完全关机再开机，核 `ActiveFWVersion` 和该模块健康。首条通过后再对其余匹配模块逐一应用同样步骤。旧模块若 `Locked`，按原厂解锁流程处理。 [ipmctl 固件命令](https://docs.pmem.io/ipmctl-user-guide/support-and-maintenance/version-and-firmware)

```bash
fw=/absolute/path/to/REPLACE_VENDOR_IMAGE.bin
dimm=0xREPLACE
sudo ipmctl load -source "$fw" -examine -dimm "$dimm"
sudo ipmctl load -source "$fw" -dimm "$dimm"
sudo ipmctl show -dimm -firmware
# 关机再开机后重新确认。
sudo ipmctl show -dimm -firmware
sudo ipmctl start -diagnostic FW
```

## T4. P4618、D4800X 与 HC620

先从 SanDisk 上的验机系统启动，用 `sudo nvme list -v`、`sudo nvme id-ctrl /dev/nvmeX`、`sudo nvme fw-log /dev/nvmeX` 及 `smartctl -x` 核型号、固件、序列号和健康。P4618 两个控制器各记录一行。使用实际序列号定位，重启后重新枚举。更新在 I1/I4 创建 RAID、GPT、dm-zoned 和 ZFS 前完成。

- **P4618 6.4 TB**。Solidigm 11 月 2 日列表的通用版是 **VDV10194**。在临时 Xubuntu 装官方 SST 3.2 Linux `.deb`，其指南列明支持 Ubuntu 26.04。运行 `sudo sst show --ssd`，确认两个控制器和 `FirmwareUpdateAvailable`。对于工具明确接受的通用端点，逐个用 `sudo sst load --ssd "$ref"`，`ref` 填已核序列号或工具返回的索引。完成后按工具要求冷启，再确认两个端点和版本。若是 OEM 版，沿该 OEM 的版本分支核公告和包。本机 F10 启动项列表里两个端点的型号是 `7361454_ICRPC5ED2ORA6.4T`，带 Oracle 料号前缀和 `ORA` 标记，按 OEM 版处理：`sst show` 只用于盘点，保留到货固件，T4 记录 `nvme id-ctrl` 的 `fr`。 [Solidigm 固件列表](https://www.solidigm.com/support-page/drivers-downloads/ka-00099.html) · [SST 3.2 下载](https://www.solidigm.com/support-page/drivers-downloads/ka-00085.html) · [SST 更新操作](https://www.solidigm.com/support-page/maintenance-tools/ka-00052.html)
- **D4800X 1.5 TB U.2**。实物是双口盘，经硬改用单口 Gen3 x4，通过 PCIe 转接卡并加风扇。T4 读取 `nvme id-ctrl` 的完整型号、序列号、固件、`cmic`，以及 `nvme list-subsys` 的路径。F10 启动项列表里的型号以 `INTEL SSDPD21K015TA` 开头，槽 5 当前为 Gen3。对应的固件分支与更新工具支持尚未核实，保留到货固件。该盘不能套用 P4800X AIC 的 E2010650 升级步骤。 [D4800X 规格](https://www.intel.com/content/www/us/en/products/sku/129970/intel-optane-ssd-dc-d4800x-series-1-5tb-2-5in-pcie-2x2-3d-xpoint/specifications.html)
- **七块 HC620 SATA 4Kn HM-SMR**。用 `smartctl -i` 逐盘记录完整型号、固件和序列号，同时抄标签 OEM P/N。按原固件验 ZAC 与慢扫。只有对应 OEM 明确覆盖完整料号和当前版本、且公告涉及实际故障或兼容性时才更新；更新后先验一块，重查 4Kn、zone 类型和完整长自检。不同 OEM 的版本字符串可以不同。 [WD HC620 SATA OEM 规范](https://documents.westerndigital.com/content/dam/doc-library/en_us/assets/public/western-digital/product/data-center-drives/ultrastar-dc-hc600-series/product-manual-ultrastar-dc-hc620-sata-spec.pdf)
- **Samsung FIT 和 SATA7 光驱**。T4 确认光驱枚举，临时插入 FIT 记录型号和 `ID_SERIAL` 后拔下。FIT 的 UEFI 引导及冷启在 [I1.4 装完系统后](INSTALL.md#i14-核验-fit-引导并做救援验证)检查。若厂商工具对实物完整型号列出相关更新，再单独处理。 [Samsung FIT 支持](https://semiconductor.samsung.com/consumer-storage/magician/)

## T5. P620 与四块 V100

用 `nvidia-smi --query-gpu=uuid,name,pci.bus_id,vbios_version --format=csv` 和 `nvidia-smi -q` 记录 VBIOS、板卡标识和可读的 InfoROM。P620 先核 UEFI 显示和 NVENC，V100 逐卡核板型、PCIe、NVLink、ECC 和负载。保留到货 VBIOS，只有板卡或算力坞供应商的公告明确覆盖实际板号、PCI 子系统 ID、卡型及相应故障时再考虑刷写。四卡版本不同先核板号和实际拓扑。被动 x8/x8 直通板、线缆和纯水冷部件通过链路及温控测试。若算力坞有独立可编程控制器，按供应商的具体型号查。 [NVIDIA SMI 字段说明](https://docs.nvidia.com/deploy/nvidia-smi/index.html)
