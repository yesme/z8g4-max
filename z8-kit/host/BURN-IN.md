# Z8 G4 拷机与故障演练

按 [上机操作顺序](FIRST-BOOT.md) 确认每轮接线和启动介质，再回本页执行 T1–T5 命令。T1 把 Xubuntu 26.04.1 装到可清空的 SanDisk U 盘，以便重启后继续使用显卡驱动与诊断工具。测试日志保存在 SanDisk，I1 前拔下留存。T3 配 PMem 专用测试卷，T4 查裸盘，HC620 与 D4800X 的数据池在 I4 创建。

T1–T4 在主机独立运行时完成，槽 2/3 的直通卡未装、算力坞断电。T4 完成后关机接坞，T5 通过后关机断开 V100，再做正式安装。

## T1. CPU、BIOS 与联网

装两颗 8269CY、散热器、内存风道、12 条 DDR4 和槽 4 的 P1000。有网线就接板载 RJ-45。无线过渡时，断电装槽 7 的 AX210 和两根天线；用到蓝牙再接内部 USB。P4618、D4800X、HC620 和算力坞留到对应阶段。本机到货已装的 PMem、P4618 和 D4800X 都已拆下，见 [到货状态](BIOS.md#到货状态与首次-f10-实拍)。按 [BIOS 手册](BIOS.md) 设 F10，并按 [固件手册](FIRMWARE.md) 处理主板固件。

### HP 自带诊断

开机按 Esc 再按 F2，或在 F10 的 `Main → System Diagnostics` 进入 HP PC Hardware Diagnostics UEFI。它不依赖任何系统盘，BIOS 按 U 盘、硬盘、BIOS 内置的顺序找这个工具；本机没有另装时运行的是内置的 `2.3.8.0 - BIOS`，菜单为 Processor、Memory Test、Storage Tests、System Board Test 和 Keyboard Test。它用来做装系统前的快筛和日后开不了机时的排查，不替代下面的拷机。

| 阶段 | 用哪项 | 说明 |
|---|---|---|
| T1 | Processor、System Board Test | 各几分钟。通过时记下 PASS ID，失败时记下 24 位 Failure ID |
| T2 | Memory Test 的 Quick Check | 192 GiB 约一小时，放在 Memtest86+ 之前先筛一遍。四个完整 pass 的 Memtest86+ 和 144 GiB 的 Linux 压测照做 |
| T4 | Storage Tests 的快速项 | 先看它列出了哪些盘，只做 SMART 类的快速检查。七块 14 TB 盘的全盘读由并行的 SMART 长自检完成，不用它的完整测试 |

它不显示温度、频率和 ECC 可纠正错误计数，也没有 GPU 计算、PMem 和 dm-zoned 的测试，这些仍看 Linux 下的日志。需要完整版时，在 Windows 电脑上运行 HP 的 SoftPaq sp167305（版本 10.8.4.0），选择装到 U 盘；安装程序会把 U 盘分区改名为 `HP_TOOLS`，所以用一只单独的 U 盘，不要用 Ventoy、SanDisk 或 FIT。 [HP 维修手册的诊断章节](https://kaas.hpcloud.hp.com/pdf-public/pdf_6792418_en-US-1.pdf) · [sp167305 说明](https://ftp.hp.com/pub/softpaq/sp167001-167500/sp167305.html)

进了 Linux 以后，可以试 `sudo modprobe hp-wmi-sensors` 再运行 `sensors`。HP 商用机经 WMI 报告的风扇转速和板上温度由这个驱动接入 hwmon，本机是否有数据以实测为准。 [Linux 7.0 hp-wmi-sensors](https://docs.kernel.org/7.0/hwmon/hp-wmi-sensors.html)

### 首次 Live 联网与临时验机系统

用 **F9 → Ventoy UEFI → Xubuntu 26.04.1 Desktop → Try Xubuntu** 进入 Live。有线默认由 NetworkManager 通过 DHCP 联网，先用 `nmcli device status` 确认插线的接口。HP 规格列板载 I219-LM 与 X722 1GbE，Linux 分别识别为 `e1000e` 和 `i40e`。若配置了选配网络模块，按实际型号和协商速率记录。 [HP 板载网络规格](https://h30434.www3.hp.com/psg/attachments/psg/Business-PC-Workstation-POS/44704/1/Z8%20G4%20Quickspecs%20v67.pdf#page=77)

没有网线时用 AX210。已核 Live 的 `linux-modules-7.0.0-30-generic` 含 `iwlwifi`、`iwlmvm`、`btusb` 和 `btintel`，镜像也带 `linux-firmware-intel-wireless` 与 NetworkManager。AX210 插好后即可尝试联网。用 Xfce 面板的网络图标连接实际 LAN 的 Wi-Fi，或用终端 `nmcli --ask` 提示输入密码。无线过渡时确认 AX210、`iwlwifi`、接口、地址与路由，再验证 APT。普通 Live 的网络配置和临时安装的软件随重启清空。 [官方 Live 包清单](https://cdimage.ubuntu.com/xubuntu/releases/26.04/release/xubuntu-26.04.1-desktop-amd64.manifest) · [Linux AX210 驱动](https://wireless.docs.kernel.org/en/latest/en/users/drivers/iwlwifi.html) · [nmcli 手册](https://networkmanager.pages.freedesktop.org/NetworkManager/NetworkManager/nmcli.html)

`nmcli device wifi list` 可查看附近网络。连上有线或过渡 Wi-Fi 后，从 `z8-kit` 根运行。脚本打印实际网卡、驱动、已协商的有线速率、地址、默认路由和 DNS，最后更新 APT 索引。Live 退出前保存 `Log:` 路径显示的文件。

```bash
bash host/run-step.sh t1-network
```

如果扫不到 SSID，先核两根天线、F10 槽 7 和 `rfkill list`。软阻断时运行 `sudo rfkill unblock wifi`。PCIe 已识别但接口缺失时，看 `sudo journalctl -k -b --no-pager -g 'iwlwifi|firmware'`。如果日志确实报缺固件，用另一台联网机器从 26.04 官方源下载 `linux-firmware-intel-wireless` 的 `.deb`，经 USB 拷入，`sudo dpkg -i ./linux-firmware-intel-wireless_*.deb` 后在本机控制台运行 `sudo modprobe -r iwlmvm iwlwifi`，再运行 `sudo modprobe iwlwifi`。安装好的临时系统也可重启。能够连上 AP 但没有默认路由或 DNS 时，先处理 DHCP/DNS。`apt update` 若报告仓库访问失败，先解决该错误再安装工具。

Live 联网验证通过后，把临时系统装到 **可清空的 SanDisk Ultra Fit CZ430 128 GB**。此时 P4618 等存储还未安装，FIT 也先不接。先只插三星 Portable SSD T3 250 GB，从其 Ventoy 菜单启动，等进入 Live 再插 SanDisk。CZ430 的标称容量约为 119 GiB，供临时桌面系统、CUDA 构建工具和日志使用。 [SanDisk 型号规格](https://www.sandisk.com/products/usb-flash-drives/sandisk-ultra-fit-usb-3-1?sku=SDCZ430-128G-G46) · [Xubuntu 容量要求](https://xubuntu.org/download/#system-requirements)

1. 在 Live 中，插入 SanDisk 前后各运行一次 `lsblk -d -o NAME,PATH,MODEL,SERIAL,SIZE,TRAN`，用新增设备的型号和序列号认出 SanDisk，容量约 119 GiB。此时 Samsung FIT 留在机外，T4 才接入读序列号。再打开 **Install Xubuntu → Interactive installation → Erase disk and install Xubuntu**。只选 SanDisk，使用默认 ext4，保持加密和第三方驱动选项关闭。在最后确认页核对目标后继续。 [桌面安装流程](https://ubuntu.com/desktop/docs/en/latest/tutorial/install-ubuntu-desktop/#erase-disk-and-install-ubuntu)
2. 安装后按提示拔 Ventoy，SanDisk 留在原 USB 口。从 F9 启动指向 SanDisk 的 UEFI 引导项。运行 `findmnt /`、`findmnt /boot/efi`，用 `lsblk` 验证两者都在 SanDisk。保持网线连接，或在无线过渡时用 AX210 重连。再执行 `sudo apt update`。
3. 用 `mkdir -p "$HOME/z8-burnin"` 建日志目录。后续保存验机输出的命令从这个目录运行，或显式给出目录路径。T2/T3 内存测试时才从 Ventoy 选 Memtest86+，其余各轮从 SanDisk 上的临时 Xubuntu 启动。

### CPU 拷机

从 SanDisk 上的临时系统启动并确认联网后，准备 CPU 微码和压测工具。微码安装后先重启，再记录两个物理 socket、每路一个 DDR4 节点和当前微码版本。若 `numactl --hardware` 显示的拓扑不符，先回 F10 核对 NUMA 开、SNC 关，再确认两路 DDR4 枚举。

```bash
bash host/run-step.sh t1-cpu-prepare
```

**先装 R580 再压测。** 临时系统默认用开源的 nouveau 驱动 P1000。本机实测它在关闭图形界面的瞬间让整机锁死，键盘灯都不再响应。装完临时系统后就按 [NVIDIA 显卡驱动安装步骤](INSTALL.md#安装并锁定-nvidia-显卡驱动) 装 `nvidia-driver-580`，重启后 `lsmod | grep -E 'nvidia|nouveau'` 应只有 `nvidia` 一组；T5 只需复核。

**先跑 60 秒看两路温度。** 首次上机和每次重装散热器后都做。开两个终端，一个看温度，一个先跑半载、再跑满载。本机 8269CY 的 `sensors` 上限是 high 87 °C、crit 93 °C。

```bash
watch -n 2 "sensors | grep Package"
stress-ng --cpu "$(nproc)" --cpu-load 50 --cpu-method matrixprod --timeout 60s
stress-ng --cpu "$(nproc)" --cpu-method matrixprod --timeout 60s --metrics-brief
```

任何一路到 87 °C 就按 Ctrl+C。一分钟内顶到上限，或者两路相差超过 10 °C，都先停下来处理散热：查该路散热器的风扇和风扇线，再拆下散热器看硅脂是否涂匀、保护膜是否撕掉，按标签顺序重新拧紧四颗螺丝。本机首次满载时 CPU0 在一分钟内到 93 °C、CPU1 为 75 °C，原因是 CPU0 的硅脂没涂好；此前的 30 分钟压测也因此在几分钟内卡死。60 秒正常后把时间加到 5 分钟、15 分钟，再跑下面的完整一轮。

重启进 SanDisk 临时系统后运行下列检查。

```bash
bash host/run-step.sh t1-cpu
```

这一步记录双路 CPU、微码和 DDR4 NUMA 节点，先跑 5 分钟全核 50% 的半载，再跑 30 分钟 `matrixprod`，比较前后的 RAS。半载期间脚本每 2 秒读一次两路的 Package 温度并取各自的峰值；停载后芯片一秒内就降温，所以在负载中采样。任何一路的峰值离 crit 不到 15 °C，两路峰值相差超过 10 °C，或任一实际物理 socket 缺少半载期间有效的 Package 温度和 crit 读数，就不进满载，步骤记为失败并照常留下 RAS 记录。满载阶段脚本不再检查，头几分钟仍要看着温度。两个阈值是按热阻估的，第一次正常跑完后拿日志里的半载读数校对；缺读数时日志会点名缺少的 Package；先用 `lscpu --online --physical --parse=SOCKET` 和 `sensors` 核对两路。只有读数齐全、确认散热无误而被温度阈值拦下时，用 `Z8_THERMAL_GATE=off bash host/run-step.sh t1-cpu` 放行。

保留 `matrixprod` 作为通用负载，再单独跑 30 分钟 **AVX-512 VNNI**。Xubuntu 26.04 的 stress-ng 0.20.01 提供 `vpdpbusd512` intrinsic。8269CY 启动后应枚举 Linux 标志 `avx512f` 和 `avx512_vnni`。先跑 5 秒确认确有 bogo ops 且压力项通过，再跑双路全核。 [Ubuntu stress-ng VNNI 参数](https://manpages.ubuntu.com/manpages/resolute/man1/stress-ng.1.html) · [Cascade Lake AVX 频率实测](https://www.nas.nasa.gov/hecc/support/kb/cascade-lake-processors_579.html)

先安装当前内核匹配的 `turbostat`。

```bash
sudo apt install linux-tools-common "linux-tools-$(uname -r)"
```

温度终端先开始每 5 秒采样，留 30 秒空闲基线。

```bash
bash host/run-step.sh t1-avx-temperature
```

负载终端先确认 AVX-512 VNNI 标志和 5 秒预检，过一遍同样的半载和温度检查，再跑 30 分钟双路负载，完成后继续采硬件事件。

```bash
bash host/run-step.sh t1-avx
```

负载结束，留 30 秒恢复记录后用 Ctrl+C 停 turbostat。两路分别比较满载 `Bzy_MHz`、`PkgTmp` 和 `PkgWatt`。AVX 的正常频率档可以低于常规负载。温度持续上升、`CoreThr` 增加、两路温差异常或出现新增硬件错误时，排查风道、散热器和 BIOS 电源配置。`PKG_%` 结合温度及功耗看。运行时可用 `watch -n 5 sensors` 对照风扇与温度。两轮通过再进 T2。 [Ubuntu turbostat 指标](https://manpages.ubuntu.com/manpages/resolute/man8/turbostat.8.html)

### 怎么读硬件错误

| 日志里的词 | 含义与这次怎么看 |
|---|---|
| Linux EDAC | Linux 用来收集和报告硬件纠错信息的内核子系统。这台机器主要看内存控制器报告的 ECC 事件。`rasdaemon` 在 Linux 运行时记录事件，`ras-mc-ctl` 查询。 |
| CE，Correctable Error | 硬件检测到且已纠正的错误。应用可能依然显示通过，所以要对比拷机前后的计数。若同一通道或 DIMM 计数新增，保留位置和时间，重插或交换后复测。 |
| UE，Uncorrectable Error | 硬件检测到但无法纠正的错误。新增 UE 先停这轮，保存日志并排查内存条、通道与 CPU 插座，再跑压力。 |
| MCE，Machine Check Exception | CPU 的硬件错误报告路径，可能涉及缓存、内存控制器、UPI 等。Linux 日志也会记录已纠正的 machine-check 事件。看到 `mce` 字样先区分驱动启动提示和实际事件，再看错误 bank、严重性和时间。 |
| Rowhammer | 专测反复激活 DDR4 行是否让相邻行翻位。Memtest86+ 默认关闭这项，专项耗时随容量增长。常规拷机跳过，只有专门评估 DDR4 的行扰动时才单独打开。 |

用 `sudo ras-mc-ctl --status` 看驱动状态，`sudo ras-mc-ctl --errors` 和 `sudo ras-mc-ctl --error-count` 分别看事件和系统导出的 CE/UE 计数。若计数未导出，把 EDAC 覆盖记为待确认，同时看 `journalctl -k -b` 和 F10 的 `Main → BIOS Event Log`。Memtest86+ 从 Ventoy 菜单启动，现场拍照保存那一轮的结果。 [Ubuntu ras-mc-ctl 手册](https://manpages.ubuntu.com/manpages/resolute/man8/ras-mc-ctl.8.html) · [Linux EDAC](https://docs.kernel.org/driver-api/edac.html) · [Linux machine check](https://docs.kernel.org/arch/x86/x86_64/machinecheck.html) · [Memtest86+ 测试说明](https://www.memtest.org/readme)

## T2. 只测 DDR4

1. 沿用 T1 的硬件。DDR4 仍用 CPU0、CPU1 各自 DIMM 1/3/5/8/10/12。F10 确认 192 GiB、每路六条，NUMA 开、Fast Boot 和 SNC 关。P1000 留在槽 4，无线过渡时 AX210 留在槽 7。
2. F9 选 Ventoy UEFI，在菜单选现有的 Memtest86+ x86_64。选完整地址范围和默认测试集，Rowhammer 保持关闭。先做 1 pass 快筛，再持续至至少 **4 个完整 pass**。I1 装好正式 FIT 后，日后复测可从 [FIT 的 GRUB 菜单](FIT-RECOVERY.md#i1-备好本机救援入口)选 Memtest86+。可用时开 ECC 轮询并拍下结果，另查 BIOS 事件和 Linux EDAC。要求 0 错。
3. 回 SanDisk 上的临时 Xubuntu，按下面顺序核容量、开温度采样、跑 Linux 压测。日志都留在 `~/z8-burnin`。

### 开跑前核容量和 NUMA

192 GiB DDR4 的 75% 是 **144 GiB**。两路交错时预计每路用约 **72 GiB**，各路标称余下约 **24 GiB** 给固件保留、内核、桌面和测试额外开销。`stressapptest -M` 用 MiB，`144 × 1024 = 147456`。前面的 Memtest86+ 负责扫完整可测试地址范围，这一轮看 Linux 下持续读写时是否出现数据校验或硬件错误。 [stressapptest 源码](https://github.com/stressapptest/stressapptest/blob/master/src/sat.cc#L740-L754) · [MiB 单位定义](https://github.com/stressapptest/stressapptest/blob/master/src/sattypes.h) · [Memtest86+ 手册](https://www.memtest.org/readme)

先装好本轮工具，再在系统安静时看可用量。

```bash
sudo apt install stressapptest fio ndctl daxctl hdparm smartmontools sysstat
```

```bash
bash host/run-step.sh t2-memory
```

- `free -h` 看 `Mem:` 行的 `total` 和 `available`。`total` 应接近 192 GiB，`available` 应明显高于 144 GiB，好让测试缓冲和程序开销都落在 DDR4 里。若可用量已接近 144 GiB，先退出占内存的程序，必要时重启验机系统后复查。 [Ubuntu free 手册](https://manpages.ubuntu.com/manpages/resolute/man1/free.1.html)
- `numactl --hardware` 应列出两个带 CPU 的 DDR4 节点。每路的 `node N size` 应接近 96 GiB，实际值会扣掉固件保留。再看 `node N free`，空闲的两路应各有接纳约 72 GiB 的空间。若只有一路 `free` 偏低，先排查该路已有的内存占用。`node free` 是空闲页，整机可回收缓存后的估算看 `free -h` 的 `available`。容量或节点数异常时先查 F10、插条和 NUMA。压测命令中的 `0,1` 用实测节点编号。 [Ubuntu numactl 手册](https://manpages.ubuntu.com/manpages/resolute/man8/numactl.8.html)

### 散热、监控与停测

- **风道。** Memtest86+ 和 Linux 压测都装好原厂内存风扇、内部风罩和侧板。确认内存风扇线已接好、风扇运转、进出风口通畅，HP 要求各通风面留约 10 cm。机箱风扇由 HP 固件按传感器自动调速。若确认风道正常后仍需要提高最低风量，F10 的 `Advanced → Built-In Device Options → Increase Idle Fan Speed (%)` 调的是最低转速，实际温控仍由固件负责。Memtest86+ 有温度显示时一并观察。发现风扇故障或固件热告警时，在 Memtest86+ 按 Esc 退出。 [HP Z8 G4 服务手册，第 3、4、6 章](https://kaas.hpcloud.hp.com/pdf-public/pdf_6792418_en-US-1.pdf)
- **CPU。** 先用 `sensors` 记两颗 8269CY 各自 `coretemp` 的 `Package id`、当前温度和 `crit`（TjMax）。开跑后在监控终端看各路 `PkgTmp` 和总览行的 `CoreThr`，后者是本采样间隔新发生的热节流次数。 [Linux coretemp](https://docs.kernel.org/hwmon/coretemp.html) · [Ubuntu turbostat 手册](https://manpages.ubuntu.com/manpages/resolute/man8/turbostat.8.html)
- **内存。** `sensors` 若列出 `jc42`，另开终端用 `watch -n 5 'sensors "jc42-*"'` 看可读到的 DIMM 温度及 `high`、`crit` 告警。若没有相关读数，记录实际可见的传感器，现场主要核内存风扇、风道和固件热告警。此时 DIMM 实温未知。 [Linux jc42](https://docs.kernel.org/hwmon/jc42.html)

监控终端先采几轮空闲数据，再开负载。`turbostat` 沿用 T1 已装的内核工具。

```bash
bash host/run-step.sh t2-temperature
```

从开跑开始盯温度，读数趋稳后定时查看。**任一路 `PkgTmp` 到 `crit − 5°C`、总览行出现 `CoreThr > 0`、DIMM 出现高温告警、风扇停转或系统报过热，立即到压测终端按 Ctrl+C。** `crit − 5°C` 是本次验机选用的人工停测线。停负载后保留采样到温度回落，保存日志和 BIOS Event Log。检查散热器安装、风扇和风道，复测前先归档这一轮日志，再用相同 144 GiB 配置重跑。 [Intel 硬件热保护与 Linux 计数](https://docs.kernel.org/admin-guide/thermal/intel_thermal_throttle.html)

### 跑满 144 GiB、4 小时

在另一个终端执行。压测退出后照常收集日志。

```bash
bash host/run-step.sh t2-ddr4 0,1
```

把 `0,1` 换成上一步看到的两个 DDR4 节点号。脚本核两路有 CPU 且各有超过 72 GiB 空闲，交错分配 144 GiB，保存压测前后两次 ECC/RAS 和内核事件。

放行要求是完成 4 小时、`Status: PASS`，且无新增 CE/UE、MCE 或掉条。跑完再停止温度采样。若中途停测，记录停测原因及当时的温度和日志。

### 70 GiB 只用于单路定位

双路出现读写校验错误或新增内存相关的 CE、UE、MCE，要判断故障在哪一路时，再逐路跑 **70 GiB**（`-M 71680`）。掉条先恢复正常枚举，触发热告警先处理散热。单路定位沿用上面的监控，按实机把命令最后的 `0` 改为待查节点，每次只跑一路。`-s 14400` 是最长运行时间，复现就可停。故障排除后，以双路 144 GiB 完整跑通作为 T2 放行依据。 [numactl 的绑核与绑内存](https://manpages.ubuntu.com/manpages/resolute/man8/numactl.8.html)

```bash
bash host/run-step.sh t2-ddr4 0
```

## T3. PMem 100，App Direct 的专用检查

1. T2 通过后关机断电。DDR4 留在原位，往 CPU0 和 CPU1 各自的 DIMM 2/4/6/7/9/11 加 PMem。这批模块带着原来的 Memory Mode 配置，首次混插开机时内存总量可能是 PMem 容量；goal 生效后再跑 Memtest86+。打开 [T3 的 App Direct 操作](PMEM.md#t3-配置-app-direct)，依次做 F10 查条与临时解冻、Linux 盘点和提交 App Direct goal、重启核对两路 region。再用 Memtest86+ 复测混插 DDR4 至少一个完整 pass。回 SanDisk 上的临时系统切 namespace，使用下面的诊断和写读校验验 PMem。

```bash
bash host/run-step.sh t3-pmem
```

脚本收集拓扑、固件、区域、传感器和热/介质日志，再触发 `ipmctl` 内置诊断。

这次运行覆盖 Quick、Config、Security、FW。Security 结果对照实际冻结/锁定策略；未预期的告警、region 缺失、介质错误增量或训练失败先处理。需要按模块复查时用 `sudo ipmctl start -diagnostic Quick -dimm 0xNNNN`，DIMM ID 用工具实际返回值。验收前后保存传感器的 Media/Controller 温度和模块报告的阈值，并记录有无节流，使用该批模块/固件阈值。 [Intel ipmctl 命令](https://www.intel.com/content/www/us/en/support/articles/000032861/technologies/memory-and-storage.html) · [诊断参数](https://docs.pmem.io/ipmctl-user-guide/debug/run-diagnostic)

2. 用 **fsdax 文件与 devdax 设备分别做持久写入和 CRC32C 回读**。装 Ubuntu 26.04 amd64 的 fio 3.41-2，按 [PMem 工具清单](PMEM.md) 核 `libpmem` / `dev-dax`。按 [正式模型卷](PMEM.md#模型卷) 创建双路条带，在该卷写入并校验一份 400 GiB 测试文件，两个成员各承受约 200 GiB 的写入。对两个约 500 GiB 的 devdax 仅在全新、未 kmem online 且可清空的 namespace 执行，先 8 GiB，再约 448 GiB 或按可用量下调。2 MiB 的块大小与 devdax 对齐一致。切勿把正在用的生产设备代入 fio。

```bash
(
    set -e
    logs="$HOME/z8-burnin/pmem"
    mkdir -p "$logs"
    findmnt -rn -M /srv/pmem-model -t xfs -O dax=always
    sudo env PMEM_TEST_FILE=/srv/pmem-model/burnin.bin PMEM_TEST_SIZE=400G \
        fio --output-format=json --output="$logs/pmem-fsdax-verify.json" host/pmem-fsdax.fio
)
```

```bash
logs="$HOME/z8-burnin/pmem"
sudo env PMEM_TEST_DAX=/dev/REPLACE_FIRST_DAX PMEM_TEST_SIZE=8G \
    fio --output-format=json --output="$logs/pmem-devdax0-quick.json" host/pmem-devdax.fio
# 用两个实际设备和各轮容量分别运行 devdax job，每轮使用不同的输出文件。
```

对 fsdax 做跨重启持久性检查。先执行 `sudo sha256sum /srv/pmem-model/burnin.bin > "$HOME/z8-burnin/pmem/burnin.sha256"`，`sync`、干净关机后切 AC。重新启动临时系统后，填回两个 fsdax UUID，执行 `sudo bash host/pmem-dax-stripe.sh mount "$FS0_UUID" "$FS1_UUID"` 挂载，再执行 `sudo sha256sum -c "$HOME/z8-burnin/pmem/burnin.sha256"`。测试后检查 fio `error=0`、校验一致，ipmctl 介质/热日志无新增错误。通过后移除本次 `/srv/pmem-model/burnin.bin`，保留 SanDisk 上的日志与校验值。按 [模型挂载服务](PMEM.md#交给启动服务)完成 T3 的挂载交接。 [fio PMDK 文件引擎](https://github.com/axboe/fio/blob/master/engines/libpmem.c) · [fio devdax 引擎](https://github.com/axboe/fio/blob/master/engines/dev-dax.c)

3. 按 [PMem 转 kmem](PMEM.md#剩余-pmem-转-kmem) 启动到 `memhp_default_state=offline`，两个 devdax 上线为 Movable 后用 `numactl -H` 查两个慢节点。逐节点对实测的慢节点号运行 `numactl --membind=慢节点号 stressapptest -s 7200 -M 131072 -m 12 -W`，用 `numastat -p` 核实际分配，并保存当轮的 PMem 温度和介质错误计数。

4. 保存 [双路 NUMA 拓扑](PMEM.md#核对双路-numa-拓扑)，用 [逐路下沉验证](PMEM.md#核实每路-ddr4-的冷页去向) 检查 DDR4 的冷页实际去哪一块 PMem，两路都通过后启用正常页下沉，再做 [kmem 冷启计时](PMEM.md#t3-记录-kmem-冷启动时间)。保存四个 UUID 和两份实填 env 后进入 T4。

## T4. 存储、网络硬件和无坞基线

### P4618 链路与双控制器

先装槽 1 的 P4618，从验机介质启动。记录桥接层次、各端口实际协商宽度和两个 NVMe 序列号，然后再装槽 5 的 D4800X。

```bash
sudo apt install pciutils nvme-cli
sudo lspci -tv
sudo lspci -d 10b5:8718 -vv | grep -E '^[0-9a-f]|LnkSta:'
sudo nvme list
```

用 `lspci -tv` 把桥和末端控制器对应起来。预期一条 `LnkSta` 为 `Speed 8GT/s, Width x8` 的主机上行、两条 `Speed 8GT/s, Width x4` 的板内下行，以及两个各约 3.2 TB 的 Intel NVMe namespace，各自有控制器和序列号。若型号过滤无输出，按树里桥的 PCI 地址执行 `sudo lspci -s <BDF> -vv`，核 `LnkSta` 和 `LnkCap`。上行低于 Gen3 x8 时，先回 F10 查两颗 CPU 已识别、Slot 1 保持 `Bifurcation = Auto`、`Limit PCIe Speed = Auto`，同时确认没有 Thunderbolt 3 卡。然后关机断电检查卡的金手指、插槽和挡板是否让卡完全插到位，重插后复测。上行已是 Gen3 x8 但只见一组 3.2 TB 时，从缺失的下行分支查对应 NVMe 枚举和内核 AER／NVMe 错误。两个端点与链路均通过再进入 SMART 检查。 [Intel P4618 产品简报](https://www.mouser.com/datasheet/2/612/dc-p4610-p4618-series-brief-1660967.pdf) · [HP 槽位白皮书，第 7 页](https://www.workstation4u.de/hp-z8-g4-technichalwhitepaper.pdf#page=7)

### NVMe 健康与 SATA 枚举

按 [SATA 接线与认盘](BIOS.md) 做 1 → 4 → 7 盘冷启动和 SATA7 光驱枚举。七块 HC620 全部在线后，按序列号保存 SATA0–6 对应的整盘 by-id，逐盘查 `ZONED` 和普通区、顺序写区。到此只操作裸设备的识别和测试。D4800X 分区、dm-zoned 格式化、RAIDZ1 建池和 scrub 都在正式安装 I4。

```bash
sudo apt install nvme-cli smartmontools hdparm fio
sudo nvme list -v
lsblk -d -o NAME,MODEL,SERIAL,SIZE,TRAN,ZONED,LOG-SEC,PHY-SEC
# 核实为两个 3.2 TB P4618 端点及一个 1.5 TB D4800X，换成各自整盘 by-id。
ssds=(/dev/disk/by-id/nvme-REPLACE_P4618_A
      /dev/disk/by-id/nvme-REPLACE_P4618_B
      /dev/disk/by-id/nvme-REPLACE_D4800X)
for disk in "${ssds[@]}"; do
    sudo nvme fw-log "$disk"
    sudo smartctl -x "$disk"
done
sudo nvme id-ns -H "${ssds[2]}"
sudo nvme id-ctrl -H "${ssds[2]}"
sudo nvme list-subsys "${ssds[2]}"
sudo blockdev --getsize64 "${ssds[2]}"
```

记录 NVMe 的 Critical Warning、Available Spare、Percentage Used、Media and Data Integrity Errors。先按 [固件手册](FIRMWARE.md#t4-p4618d4800x-与-hc620) 判定两个 P4618 端点和 D4800X 是否需要更新。若更新，冷启后重新按序列号核两个 P4618 端点及 D4800X，再做以下测试。在上一个命令块的终端里，沿用已核身份的 `ssds` 数组，逐个只读五分钟。压前后比较 SMART 和温度。若内核报 I/O 错误、重置或介质错误增加，处理后重测。SSD 测完再开始 HDD 长自检。

```bash
bash host/run-step.sh t4-nvme-read "${ssds[@]}"
```

脚本拒绝分区、重复设备和未找到的 by-id，逐个采集 SMART、只读五分钟、再采 SMART。SMART 的非零位掩码会留在日志，三个端点仍都会尝试读测，整步最终报非零。

记录 D4800X 的 T4 整盘型号、序列号、字节数、LBAF、`cmic` 与唯一 NVMe 路径。用设备对应的 `lspci -Dvv -s 实测BDF` 对照负载前后的 Gen3 x4 和 AER，核 `/dev/disk/by-id/nvme-*`。这块盘的 GPT 在 I4 创建，届时再核同根 by-id 下的 `-part1` 到 `-part9`。

### 七块 HC620 并行慢扫

等七盘冷启和风道确认后，给每块盘发一次 **SMART Extended Self-test**。命令很快返回，扫描由各盘固件独立运行。按七盘中最晚完成的一块安排时间。每盘先看 `smartctl -c` 的 Extended self-test polling time，实际启动后以工具回报的预计完成时间为准。先预留一晚到一天以上。作为量级参考，14 TB 若由主机以 150–200 MB/s 顺序读完，约需 19–26 小时；WD 给这款 14 TB 的最大持续速率为 233 MB/s。主机全盘读的估时和固件自检的 ETA 用各自的口径。 [smartctl 手册](https://manpages.ubuntu.com/manpages/resolute/man8/smartctl.8.html) · [WD HC620 规格表](https://documents.westerndigital.com/content/dam/doc-library/en_us/assets/public/western-digital/product/data-center-drives/ultrastar-dc-hc600-series/data-sheet-ultrastar-dc-hc620.pdf)

先用本机已核对的七个整盘 by-id 替换数组中的示例，然后留存一份启动前 SMART。

```bash
hdds=(/dev/disk/by-id/ata-REPLACE_SATA{0..6})
bash host/run-step.sh t4-hdd-status "${hdds[@]}"
```

确认各盘没有正在运行的自检后，用同一终端发起七盘自检。脚本核对设备均为不同的 14 TB host-managed 整盘，随后发 `smartctl -t long`，磁盘在后台并行扫描。

```bash
bash host/run-step.sh t4-hdd-start "${hdds[@]}"
```

等待期间和最后一次分别重跑 `bash host/run-step.sh t4-hdd-status "${hdds[@]}"`。状态脚本逐盘采健康、温度、自检记录，SMART 的非零状态也可能来自历史错误，需要读报告。

测试期间保持供电、通风，关闭自动休眠，避免同时跑 HDD 压测。每盘验最新一条 Extended 为 `Completed without error`，用启动前后日志的通电小时、序号和状态确认是这次结果。关注新增重映射、待处理扇区、不可校正扇区，以及内核 I/O 错误。若新增 SATA CRC 错误或链路 reset，先复核线材、供电与端口；若自检因关机或 reset 中断，处理原因后补跑该盘。无须在原始 HC620 上跑 `badblocks -w`，这类随机位置写入会遇到主机管理 SMR 的顺序写限制。正式安装的 scrub 校验池内已有数据的 checksum，裸盘慢扫查各盘自身的介质与自检结果。 [OpenZFS scrub](https://openzfs.github.io/openzfs-docs/man/master/8/zpool-scrub.8.html)

### 主机基线

七盘运行时复查当前网络。走有线时记录板载网口驱动和协商速率；仍用 AX210 过渡时复查 Wi-Fi，使用蓝牙时也查蓝牙控制器，并保存 `iwlwifi` 日志。确认重启可联网。主机保持独立，保存硬件、内核、RAS、SMART 与 SATA 对应表。P1000 为唯一显卡。

```bash
bash host/run-step.sh t4-inventory
```

七盘自检和主机基线通过后进 T5。

## T5. 算力坞 V100 与 PCIe 拷机

- T4 通过后，先在临时系统复核 T1 已装的 R580 和 P1000；T1 没装的按 [NVIDIA 显卡驱动安装步骤](INSTALL.md#安装并锁定-nvidia-显卡驱动) 补装。关机断电接坞。逐卡、每槽两卡、四卡依次冷启动。按实际 V100 UUID 选择测试设备，脚本保存压测前后的 ECC、温度、功耗、退休页和 PCIe 查询结果。提前在临时系统按 [CUDA 工具构建步骤](INSTALL.md#算力坞验收)准备 GPU Burn、P2P、NCCL 和 pinned DMA。用 `nvidia-smi -L` 抄 UUID。单卡轮执行 `bash host/run-step.sh t5-gpu-burn GPU-REPLACE0`。双卡轮在每个槽分别执行 `bash host/run-step.sh t5-gpu-burn GPU-REPLACE0,GPU-REPLACE1`，两处 UUID 填该槽的两张卡。四卡轮执行 `bash host/run-step.sh t5-gpu-burn GPU-REPLACE0,GPU-REPLACE1,GPU-REPLACE2,GPU-REPLACE3`。脚本验证输入确为 V100，配好库和 `compare.fatbin` 路径，单卡和同槽双卡各施压 15 分钟，四卡施压 60 分钟，记录前后的 ECC、温度、功耗和链路。机旁继续看泵、VRM/HBM 与接头热浸。GPU Burn 开跑就是满载，`-m` 只调显存占用，没有降载档；热负荷的分级靠逐卡、每槽两卡、四卡这个顺序。每一级开跑的头两分钟另开终端运行 `watch -n 2 nvidia-smi --query-gpu=index,temperature.gpu,power.draw --format=csv`，温度一直上升不收敛就按 Ctrl+C，先查泵、水路里的气和冷头贴合。 [GPU Burn](https://github.com/wilicc/gpu-burn)
- 正常关机再换线。每次检查新增 Xid、AER、GPU ECC、PCIe 降宽，对照无坞基线核存储设备枚举。四卡通过后执行 [P2P/NCCL](INSTALL.md#算力坞验收)，再按 [pinned DMA 命令](PMEM.md#四卡-pinned-dma-验收) 验证双路 DDR4 交错下四卡能同时传输。然后做 1017 冒烟。

### T5 末的 1017 推理冒烟

在 T5 开始时即可准备权重，约 232 GiB，下载时间单独安排。用临时 Xubuntu 的用户运行。编译和日志放 SanDisk 上的临时 Xubuntu，先用 `df -h / /var/lib` 核对剩余空间，再装 Docker 和下载 CUDA 构建镜像。模型权重直接写 T3 的正式模型卷。以下从 `z8-kit` 根目录执行；T3 已启用模型单元时用 `findmnt` 核验。若临时系统还未挂好模型卷，先执行 `sudo systemctl start z8-pmem-model.service`。

```bash
kit=$(realpath .)
sudo apt install docker.io git libgomp1 libssl3t64 numactl pipx
sudo systemctl enable --now docker.service
export PATH="$HOME/.local/bin:$PATH"
pipx install huggingface_hub
if findmnt -rn -M /srv/pmem-model -t xfs -O dax=always; then
    mkdir -p "$HOME/z8-smoke" && cd "$HOME/z8-smoke"
else
    printf 'Mount the PMem model volume before continuing.\n' >&2
fi
```

复制 [llama.cpp 主服务](../inference/README.md#llamacpp-v100-主服务) 中的编译、下载和启动命令，先完成下载，四卡硬件测试通过后再启动模型。`CUDA_VISIBLE_DEVICES` 和 `Z8_DRAM_INTERLEAVE` 用 T5、T3 记录的实值。用 `xfs_io -r -c 'fiemap -v' "$DS41_GGUF"` 记录首分片的 extent。另开终端执行下列命令，从仓库 `z8-kit` 根运行。若已切到 Xolotl，用 `--base http://127.0.0.1:8150/v1 --reasoning-effort none` 替换 `--usage`，以 Xolotl 服务日志记录生成速度。`--prompt-file` 可省略，冒烟用探针自带的短提示即可。

```bash
bash host/run-step.sh i6-probe --usage --repeats 1 --tools
```

先用 128K 单槽、f16 GPU KV 和 36 GiB GPU 专家缓存起服务，专家读进主机内存，加载为分钟级。显存不足时按[上下文降档](../inference/README.md#上下文降档与验收)操作并记录生效档。记录各卡显存、DDR4 页位置、首次填充、生成速度和工具往返；20 轮真实工具闭环在 I6 完成。工具往返成功且生成达到 5 tok/s 时通过推理冒烟。2–5 tok/s 可继续，I6 给一天处理该差距。两种引擎均无法加载或降档后仍低于 2 tok/s 时，在验机窗口内决定算力坞的去留。

## I7. 正式安装后的整机混合负载

按 [CPU 分核手册](CPU-PLACEMENT.md) 从每路 2 核起步，核启停时普通任务 CPU 集合的变化。随后以这套正式配置跑一次 8 小时混合负载，涵盖 Buck2 上传与回读、1017 的实际工具请求、SSH/RDP。主方案覆盖冷读和热读，全 XFS 回退覆盖其本地 CAS 写入与回读。默认单槽串行使用 harness。明确选用双槽且已通过 I6 时，才用两个并发 harness。全程要求无新增 Xid、AER、MCE、不可解释的 CE、SMART/NVMe 介质错误、ZFS 校验错误或 OOM。出现错误回到相关硬件阶段复现。

```bash
# 分开终端运行，日志落 P4618。先确认 log 与测试进程都能在当前用户运行。
nvidia-smi --query-gpu=timestamp,index,temperature.gpu,power.draw,pcie.link.gen.current,pcie.link.width.current --format=csv -l 5 > gpu.csv
iostat -xz 5 > iostat.log
# 主方案采四块裸冷盘的缓存水位。完成时 Ctrl+C，保留日志末尾的四盘最小值。
bash host/run-step.sh i5-cold-watermark
# 另在 z8data 已导入时监视归档池。
sudo zpool iostat -v z8data 5 > zpool-iostat.log
sudo journalctl -kf -o short-monotonic > kernel-follow.log
```

用 I5 确认的远程执行配置轮流执行 clean checkout 的 Buck2 目标和短增量构建，并保持指向本地 1017 的 OMP 工单或 `inference/probe.py` 回放。在开始与结束各执行一次 `bash host/run-step.sh i7-snapshot PID`，用实际推理 PID 替换 `PID`。脚本收集 slice、两路内存、PMem 页迁移和内核错误。如果主系统安装了 ipmctl，同时保存 `sudo ipmctl show -sensor`。记录四盘最低空闲缓存区数、构建完成时间、推理 p95 首字延迟和 decode 速度作为上线基线。
