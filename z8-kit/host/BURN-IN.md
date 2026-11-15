# Z8 G4 拷机与故障演练

按 [上机操作顺序](FIRST-BOOT.md) 确认每轮接线和启动介质，再回本页执行 T1–T5 命令。T1 把 Xubuntu 26.04.1 装到可清空的 SanDisk U 盘，以便重启后继续使用显卡驱动与诊断工具。测试日志保存在 SanDisk，I1 前拔下留存。T3 配 PMem 专用测试卷，T4 查裸盘，HC620 与 P4800X 的数据池在 I4 创建。

T1–T4 在主机独立运行时完成，槽 2/3 的直通卡未装、算力坞断电。T4 完成后关机接坞，T5 通过后关机断开 V100，再做正式安装。

## T1. CPU、BIOS 与联网

装两颗 8269CY、散热器、内存风道、12 条 DDR4、槽 4 的 P620 和槽 7 的 AX210。断电时接好 AX210 两根天线与蓝牙内部 USB 线，T1 联网只需要 PCIe Wi-Fi 路径。P4618、P4800X、HC620 和算力坞留到对应阶段。按 [BIOS 手册](BIOS.md) 设 F10，并按 [固件手册](FIRMWARE.md) 处理主板固件。

### 首次 Live Wi-Fi 与临时验机系统

用 **F9 → Ventoy UEFI → Xubuntu 26.04.1 Desktop → Try Xubuntu** 进入 Live。已核 Live 的 `linux-modules-7.0.0-30-generic` 含 `iwlwifi`、`iwlmvm`、`btusb` 和 `btintel`，镜像也带 `linux-firmware-intel-wireless` 与 NetworkManager。AX210 插好后即可尝试联网。用 Xfce 面板的网络图标连接实际 LAN 的 Wi-Fi，或用终端 `nmcli --ask` 提示输入密码。先确认 AX210、`iwlwifi`、接口、地址与路由，再验证 APT。普通 Live 的网络配置和临时安装的软件随重启清空。 [官方 Live 包清单](https://cdimage.ubuntu.com/xubuntu/releases/26.04/release/xubuntu-26.04.1-desktop-amd64.manifest) · [Linux AX210 驱动](https://wireless.docs.kernel.org/en/latest/en/users/drivers/iwlwifi.html) · [nmcli 手册](https://networkmanager.pages.freedesktop.org/NetworkManager/NetworkManager/nmcli.html)

```bash
lspci -nnk | grep -A3 -Ei 'Network controller|AX210'
rfkill list
nmcli device status
nmcli device wifi list
# 使用 Xfce 图标连接，或把下面的占位符换成 SSID。
nmcli --ask device wifi connect 'REPLACE_WITH_SSID'
ip -br address
ip route show default
getent ahostsv4 archive.ubuntu.com
sudo apt update
```

如果扫不到 SSID，先核两根天线、F10 槽 7 和 `rfkill list`。软阻断时运行 `sudo rfkill unblock wifi`。PCIe 已识别但接口缺失时，看 `sudo journalctl -k -b --no-pager -g 'iwlwifi|firmware'`。如果日志确实报缺固件，用另一台联网机器从 26.04 官方源下载 `linux-firmware-intel-wireless` 的 `.deb`，经 USB 拷入，`sudo dpkg -i ./linux-firmware-intel-wireless_*.deb` 后在本机控制台运行 `sudo modprobe -r iwlmvm iwlwifi`，再运行 `sudo modprobe iwlwifi`。安装好的临时系统也可重启。能够连上 AP 但没有默认路由或 DNS 时，先处理 DHCP/DNS。`apt update` 若报告仓库访问失败，先解决该错误再安装工具。

Live 联网验证通过后，把临时系统装到 **可清空的 SanDisk Ultra Fit CZ430 128 GB**。此时 P4618 等存储还未安装，FIT 也先不接。先只插三星 Portable SSD T3 250 GB，从其 Ventoy 菜单启动，等进入 Live 再插 SanDisk。CZ430 的标称容量约为 119 GiB，供临时桌面系统、CUDA 构建工具和日志使用。 [SanDisk 型号规格](https://www.sandisk.com/products/usb-flash-drives/sandisk-ultra-fit-usb-3-1?sku=SDCZ430-128G-G46) · [Xubuntu 容量要求](https://xubuntu.org/download/#system-requirements)

1. 在 Live 中，插入 SanDisk 前后各运行一次 `lsblk -d -o NAME,PATH,MODEL,SERIAL,SIZE,TRAN`，用新增设备的型号和序列号认出 SanDisk，容量约 119 GiB。Samsung FIT 也是 128 GB，所以不要按容量单独判断。再打开 **Install Xubuntu → Interactive installation → Erase disk and install Xubuntu**。只选 SanDisk，使用默认 ext4，保持加密和第三方驱动选项关闭。在最后确认页核对目标后继续。 [桌面安装流程](https://ubuntu.com/desktop/docs/en/latest/tutorial/install-ubuntu-desktop/#erase-disk-and-install-ubuntu)
2. 安装后按提示拔 Ventoy，SanDisk 留在原 USB 口。从 F9 启动指向 SanDisk 的 UEFI 引导项。运行 `findmnt /`、`findmnt /boot/efi`，用 `lsblk` 验证两者都在 SanDisk。用 AX210 重连 Wi-Fi 并执行 `sudo apt update`。
3. 用 `mkdir -p "$HOME/z8-burnin"` 建日志目录。后续保存验机输出的命令从这个目录运行，或显式给出目录路径。T2/T3 内存测试时才从 Ventoy 选 Memtest86+，其余各轮从 SanDisk 上的临时 Xubuntu 启动。

### CPU 拷机

从 SanDisk 上的临时系统启动并确认联网后，准备 CPU 微码和压测工具。微码安装后先重启，再记录两个物理 socket、每路一个 DDR4 节点和当前微码版本。若 `numactl --hardware` 显示的拓扑不符，先回 F10 核对 NUMA 开、SNC 关，再确认两路 DDR4 枚举。

```bash
sudo apt update
sudo apt install intel-microcode linux-firmware-intel-wireless stress-ng rasdaemon lm-sensors numactl
```

重启进 SanDisk 临时系统后运行下列检查。

```bash
sudo systemctl enable --now rasdaemon
lscpu
awk '/^microcode/ {print $3}' /proc/cpuinfo | sort -u
numactl --hardware
sudo ras-mc-ctl --errors
stress-ng --cpu "$(nproc)" --cpu-method matrixprod --verify --timeout 30m --metrics-brief
sudo ras-mc-ctl --errors
sudo journalctl -k -b --no-pager | grep -Ei 'mce|EDAC|thermal|throttl'
```

保留 `matrixprod` 作为通用负载，再单独跑 30 分钟 **AVX-512 VNNI**。Xubuntu 26.04 的 stress-ng 0.20.01 提供 `vpdpbusd512` intrinsic。8269CY 启动后应枚举 Linux 标志 `avx512f` 和 `avx512_vnni`。先跑 5 秒确认确有 bogo ops 且压力项通过，再跑双路全核。 [Ubuntu stress-ng VNNI 参数](https://manpages.ubuntu.com/manpages/resolute/man1/stress-ng.1.html) · [Cascade Lake AVX 频率实测](https://www.nas.nasa.gov/hecc/support/kb/cascade-lake-processors_579.html)

```bash
# 从 ~/z8-burnin 运行。
sudo apt install linux-tools-common "linux-tools-$(uname -r)"
sudo modprobe msr
grep -m1 -w avx512f /proc/cpuinfo
grep -m1 -w avx512_vnni /proc/cpuinfo
lscpu -e=CPU,CORE,SOCKET,NODE,ONLINE
stress-ng --vnni 1 --vnni-intrinsic --vnni-method vpdpbusd512 --verify -t 5s --metrics-brief
```

另开终端开始每 5 秒采样，留 30 秒空闲基线后开始 AVX-512 压测。

```bash
sudo turbostat --quiet --cpu core --interval 5 \
    --show Package,Core,CPU,Busy%,Bzy_MHz,CoreTmp,PkgTmp,CoreThr,PkgWatt,PKG_% \
    --out t1-avx512-turbostat.txt
```

```bash
(
    set -o pipefail
    stress-ng --vnni "$(nproc)" --vnni-intrinsic --vnni-method vpdpbusd512 \
        --verify --timeout 30m --metrics-brief 2>&1 | tee t1-avx512-stress-ng.log
)
sudo ras-mc-ctl --errors
sudo journalctl -k -b --no-pager | grep -Ei 'mce|EDAC|thermal|throttl'
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

1. 沿用 T1 的硬件。DDR4 仍用 CPU0、CPU1 各自 DIMM 1/3/5/8/10/12。F10 确认 192 GiB、每路六条，NUMA 开、Fast Boot 和 SNC 关。P620 和 AX210 分别留在槽 4 和槽 7。
2. F9 选 Ventoy UEFI，在菜单选现有的 Memtest86+ x86_64。选完整地址范围和默认测试集，Rowhammer 保持关闭。先做 1 pass 快筛，再持续至至少 **4 个完整 pass**。可用时开 ECC 轮询并拍下结果，另查 BIOS 事件和 Linux EDAC。要求 0 错。
3. 回 SanDisk 上的临时 Xubuntu，按下面顺序核容量、开温度采样、跑 Linux 压测。日志都留在 `~/z8-burnin`。

### 开跑前核容量和 NUMA

192 GiB DDR4 的 75% 是 **144 GiB**。两路交错时预计每路用约 **72 GiB**，各路标称余下约 **24 GiB** 给固件保留、内核、桌面和测试额外开销。`stressapptest -M` 用 MiB，`144 × 1024 = 147456`。前面的 Memtest86+ 负责扫完整可测试地址范围，这一轮看 Linux 下持续读写时是否出现数据校验或硬件错误。 [stressapptest 源码](https://github.com/stressapptest/stressapptest/blob/master/src/sat.cc#L740-L754) · [MiB 单位定义](https://github.com/stressapptest/stressapptest/blob/master/src/sattypes.h) · [Memtest86+ 手册](https://www.memtest.org/readme)

先装好本轮工具，再在系统安静时看可用量。

```bash
sudo apt install stressapptest stress-ng rasdaemon fio ndctl daxctl \
    hdparm smartmontools lm-sensors sysstat
free -h
numactl --hardware
```

- `free -h` 看 `Mem:` 行的 `total` 和 `available`。`total` 应接近 192 GiB，`available` 应明显高于 144 GiB，好让测试缓冲和程序开销都落在 DDR4 里。若可用量已接近 144 GiB，先退出占内存的程序，必要时重启验机系统后复查。 [Ubuntu free 手册](https://manpages.ubuntu.com/manpages/resolute/man1/free.1.html)
- `numactl --hardware` 应列出两个带 CPU 的 DDR4 节点。每路的 `node N size` 应接近 96 GiB，实际值会扣掉固件保留。再看 `node N free`，空闲的两路应各有接纳约 72 GiB 的空间。若只有一路 `free` 偏低，先排查该路已有的内存占用。`node free` 是空闲页，整机可回收缓存后的估算看 `free -h` 的 `available`。容量或节点数异常时先查 F10、插条和 NUMA。压测命令中的 `0,1` 用实测节点编号。 [Ubuntu numactl 手册](https://manpages.ubuntu.com/manpages/resolute/man8/numactl.8.html)

### 散热、监控与停测

- **风道。** Memtest86+ 和 Linux 压测都装好原厂内存风扇、内部风罩和侧板。确认内存风扇线已接好、风扇运转、进出风口通畅，HP 要求各通风面留约 10 cm。机箱风扇由 HP 固件按传感器自动调速。若确认风道正常后仍需要提高最低风量，F10 的 `Advanced → Built-In Device Options → Increase Idle Fan Speed (%)` 调的是最低转速，实际温控仍由固件负责。Memtest86+ 有温度显示时一并观察。发现风扇故障或固件热告警时，在 Memtest86+ 按 Esc 退出。 [HP Z8 G4 服务手册，第 3、4、6 章](https://kaas.hpcloud.hp.com/pdf-public/pdf_6792418_en-US-1.pdf)
- **CPU。** 先用 `sensors` 记两颗 8269CY 各自 `coretemp` 的 `Package id`、当前温度和 `crit`（TjMax）。开跑后在监控终端看各路 `PkgTmp` 和总览行的 `CoreThr`，后者是本采样间隔新发生的热节流次数。 [Linux coretemp](https://docs.kernel.org/hwmon/coretemp.html) · [Ubuntu turbostat 手册](https://manpages.ubuntu.com/manpages/resolute/man8/turbostat.8.html)
- **内存。** `sensors` 若列出 `jc42`，另开终端用 `watch -n 5 'sensors "jc42-*"'` 看可读到的 DIMM 温度及 `high`、`crit` 告警。若没有相关读数，记录实际可见的传感器，现场主要核内存风扇、风道和固件热告警。此时 DIMM 实温未知。 [Linux jc42](https://docs.kernel.org/hwmon/jc42.html)

监控终端先采几轮空闲数据，再开负载。`turbostat` 沿用 T1 已装的内核工具。

```bash
cd "$HOME/z8-burnin"
sudo modprobe coretemp
sudo modprobe msr
sensors | tee ddr4-sensors-before.log
sudo turbostat --quiet --cpu package --interval 5 --header_iterations 1 \
    --show Package,CPU,Busy%,Bzy_MHz,PkgTmp,CoreThr 2>&1 | tee ddr4-turbostat.log
```

从开跑开始盯温度，读数趋稳后定时查看。**任一路 `PkgTmp` 到 `crit − 5°C`、总览行出现 `CoreThr > 0`、DIMM 出现高温告警、风扇停转或系统报过热，立即到压测终端按 Ctrl+C。** `crit − 5°C` 是本次验机选用的人工停测线。停负载后保留采样到温度回落，保存日志和 BIOS Event Log。检查散热器安装、风扇和风道，复测前先归档这一轮日志，再用相同 144 GiB 配置重跑。 [Intel 硬件热保护与 Linux 计数](https://docs.kernel.org/admin-guide/thermal/intel_thermal_throttle.html)

### 跑满 144 GiB、4 小时

在另一个终端执行。压测退出后照常收集日志。

```bash
cd "$HOME/z8-burnin"
set -o pipefail
sudo systemctl enable --now rasdaemon
sudo ras-mc-ctl --status
sudo ras-mc-ctl --errors | tee ddr4-ras-before.log
sudo ras-mc-ctl --error-count | tee ddr4-ecc-before.log
sudo journalctl -kb -o short-monotonic > ddr4-kernel-before.log
numactl --interleave=0,1 stressapptest -s 14400 -M 147456 -m 24 -W 2>&1 \
    | tee ddr4-4h.log
sudo ras-mc-ctl --errors | tee ddr4-ras-after.log
sudo ras-mc-ctl --error-count | tee ddr4-ecc-after.log
sudo journalctl -kb -o short-monotonic > ddr4-kernel-after.log
diff -u ddr4-ecc-before.log ddr4-ecc-after.log
```

放行要求是完成 4 小时、`Status: PASS`，且无新增 CE/UE、MCE 或掉条。跑完再停止温度采样。若中途停测，记录停测原因及当时的温度和日志。

### 70 GiB 只用于单路定位

双路出现读写校验错误或新增内存相关的 CE、UE、MCE，要判断故障在哪一路时，再逐路跑 **70 GiB**（`-M 71680`）。掉条先恢复正常枚举，触发热告警先处理散热。单路定位沿用上面的监控，按实机把 `node=0` 改为待查节点，每次只跑一路。`-s 14400` 是最长运行时间，复现就可停。故障排除后，以双路 144 GiB 完整跑通作为 T2 放行依据。 [numactl 的绑核与绑内存](https://manpages.ubuntu.com/manpages/resolute/man8/numactl.8.html)

```bash
node=0
numactl --cpunodebind="$node" --membind="$node" \
    stressapptest -s 14400 -M 71680 -m 12 -W 2>&1 | tee "ddr4-node${node}.log"
```

## T3. PMem 100，App Direct 的专用检查

1. T2 通过后关机断电。DDR4 留在原位，往 CPU0 和 CPU1 各自的 DIMM 2/4/6/7/9/11 加 PMem。打开 [T3 的 App Direct 操作](PMEM.md#t3-配置-app-direct)，依次做 F10 查条与临时解冻、Linux 盘点和提交 App Direct goal、重启核对两路 region。再用 Memtest86+ 复测混插 DDR4 至少一个完整 pass。回 SanDisk 上的临时系统切 namespace，使用下面的诊断和写读校验验 PMem。

```bash
sudo ipmctl show -units GiB -socket
sudo ipmctl show -topology
sudo ipmctl show -dimm
sudo ipmctl show -firmware
sudo ipmctl show -memoryresources
sudo ipmctl show -region
sudo ipmctl show -sensor
sudo ipmctl show -error Thermal -dimm
sudo ipmctl show -error Media -dimm
sudo ipmctl start -diagnostic
```

这次运行覆盖 Quick、Config、Security、FW。Security 结果对照实际冻结/锁定策略；未预期的告警、region 缺失、介质错误增量或训练失败先处理。需要按模块复查时用 `sudo ipmctl start -diagnostic Quick -dimm 0xNNNN`，DIMM ID 用工具实际返回值。验收前后保存传感器的 Media/Controller 温度和模块报告的阈值，并记录有无节流，使用该批模块/固件阈值。 [Intel ipmctl 命令](https://www.intel.com/content/www/us/en/support/articles/000032861/technologies/memory-and-storage.html) · [诊断参数](https://docs.pmem.io/ipmctl-user-guide/debug/run-diagnostic)

2. 用 **fsdax 文件与 devdax 设备分别做持久写入和 CRC32C 回读**。装 Ubuntu 26.04 amd64 的 fio 3.41-2，按 [PMem 工具清单](PMEM.md) 核 `libpmem` / `dev-dax`。按 [正式模型卷](PMEM.md#模型卷) 创建双路条带，在该卷写入并校验一份 400 GiB 测试文件，两个成员各承受约 200 GiB 的写入。对两个约 500 GiB 的 devdax 仅在全新、未 kmem online 且可清空的 namespace 执行，先 8 GiB，再约 448 GiB 或按可用量下调。2 MiB 的块大小与 devdax 对齐一致。切勿把正在用的生产设备代入 fio。

```bash
sudo env PMEM_TEST_FILE=/srv/pmem-model/burnin.bin PMEM_TEST_SIZE=400G \
    fio --output-format=json --output=pmem-fsdax-verify.json host/pmem-fsdax.fio
sudo env PMEM_TEST_DAX=/dev/dax0.1 PMEM_TEST_SIZE=8G \
    fio --output-format=json --output=pmem-devdax0-quick.json host/pmem-devdax.fio
# 改成两个实际设备、合适的容量，分别执行 devdax job。
```

对 fsdax 做跨重启持久性检查。给测试文件计算 SHA-256 并存到 SanDisk 上的 `~/z8-burnin`，`sync`、干净关机后切 AC。重新启动临时系统后，填回两个 fsdax UUID，执行 `sudo bash host/pmem-dax-stripe.sh mount "$FS0_UUID" "$FS1_UUID"` 挂载，再用 `sha256sum -c` 核已保存的清单。测试后检查 fio `error=0`、所有 hash 一致，ipmctl 介质/热日志无新增错误。通过后移除本次 `/srv/pmem-model/burnin.bin`，保留 SanDisk 上的日志与校验值。 [fio PMDK 文件引擎](https://github.com/axboe/fio/blob/master/engines/libpmem.c) · [fio devdax 引擎](https://github.com/axboe/fio/blob/master/engines/dev-dax.c)

3. 通过后按 [PMem 手册](PMEM.md#剩余-pmem-转-kmem) 打开全局和每设备的 `memmap_on_memory`，再把两个 devdax 转成 kmem。用 `numactl -H` 确认实际慢节点，逐节点试 `numactl --membind=<slow-node> stressapptest -s 7200 -M 131072 -m 12 -W`。检查测试进程的 `numastat -p`。这轮确认慢内存可以直接分配、写入和回读。记录介质错误、温度、节流及各慢节点在线容量。

4. 保存 [双路 NUMA 拓扑](PMEM.md#核对双路-numa-拓扑)，用 [逐路下沉验证](PMEM.md#核实每路-ddr4-的冷页去向) 检查 DDR4 的冷页实际去哪一块 PMem，两路都通过后启用正常页下沉，再做 [kmem 冷启计时](PMEM.md#t3-记录-kmem-冷启动时间)。保存四个 UUID 和两份实填 env 后进入 T4。

## T4. 存储、网络硬件和无坞基线

### P4618 链路与双控制器

先装槽 1 的 P4618，从验机介质启动。记录桥接层次、各端口实际协商宽度和两个 NVMe 序列号，然后再装槽 5 的 P4800X。

```bash
sudo apt install pciutils nvme-cli
sudo lspci -tv
sudo lspci -d 10b5:8718 -vv | grep -E '^[0-9a-f]|LnkSta:'
sudo nvme list
```

用 `lspci -tv` 把桥和末端控制器对应起来。预期一条 `LnkSta` 为 `Speed 8GT/s, Width x8` 的主机上行、两条 `Speed 8GT/s, Width x4` 的板内下行，以及两个各约 3.2 TB 的 Intel NVMe namespace，各自有控制器和序列号。若型号过滤无输出，按树里桥的 PCI 地址执行 `sudo lspci -s <BDF> -vv`，核 `LnkSta` 和 `LnkCap`。上行低于 Gen3 x8 时，先回 F10 查两颗 CPU 已识别、Slot 1 保持 `Bifurcation = Auto`、`Limit PCIe Speed = Auto`，同时确认没有 Thunderbolt 3 卡。然后关机断电检查卡的金手指、插槽和挡板是否让卡完全插到位，重插后复测。上行已是 Gen3 x8 但只见一组 3.2 TB 时，从缺失的下行分支查对应 NVMe 枚举和内核 AER／NVMe 错误。两个端点与链路均通过再进入 SMART 检查。 [Intel P4618 产品简报](https://www.mouser.com/datasheet/2/612/dc-p4610-p4618-series-brief-1660967.pdf) · [HP 槽位白皮书，第 7 页](https://www.workstation4u.de/hp-z8-g4-technichalwhitepaper.pdf#page=7)

### NVMe 健康与 SATA 枚举

按 [SATA 接线与认盘](BIOS.md) 做 1 → 4 → 7 盘冷启动和 SATA7 光驱枚举。七块 HC620 全部在线后，按序列号保存 SATA0–6 对应的整盘 by-id，逐盘查 `ZONED` 和普通区、顺序写区。到此只操作裸设备的识别和测试。P4800X 分区、dm-zoned 格式化、RAIDZ1 建池和 scrub 都在正式安装 I4。

```bash
sudo apt install nvme-cli smartmontools hdparm fio
sudo nvme list -v
lsblk -d -o NAME,MODEL,SERIAL,SIZE,TRAN,ZONED,LOG-SEC,PHY-SEC
# 核实为两个 3.2 TB P4618 端点及一个 1.5 TB P4800X，换成各自整盘 by-id。
ssds=(/dev/disk/by-id/nvme-REPLACE_P4618_A
      /dev/disk/by-id/nvme-REPLACE_P4618_B
      /dev/disk/by-id/nvme-REPLACE_P4800X)
for disk in "${ssds[@]}"; do
    sudo nvme fw-log "$disk"
    sudo smartctl -x "$disk"
done
sudo nvme id-ns -H "${ssds[2]}"
sudo nvme id-ctrl -H "${ssds[2]}"
```

记录 NVMe 的 Critical Warning、Available Spare、Percentage Used、Media and Data Integrity Errors。先按 [固件手册](FIRMWARE.md#t4-p4618p4800x-与-hc620) 判定两个 P4618 端点和 P4800X 是否需要更新。若更新，冷启后重新按序列号核两个 P4618 端点及 P4800X，再做以下测试。可分别用 `sudo fio --readonly --name=nvme-read --filename="$disk" --rw=read --bs=1M --ioengine=libaio --direct=1 --iodepth=16 --time_based --runtime=300 --group_reporting` 读每个已核身份的整盘五分钟，压前后比较 SMART 和温度。若内核报 I/O 错误、重置或介质错误增加，处理后重测。SSD 测完再开始 HDD 长自检。

记录 P4800X 当前逻辑扇区大小，I4 新建 GPT 时由命令自动读取该值来计算对齐。

### 七块 HC620 并行慢扫

等七盘冷启和风道确认后，给每块盘发一次 **SMART Extended Self-test**。命令很快返回，扫描由各盘固件独立运行。按七盘中最晚完成的一块安排时间。每盘先看 `smartctl -c` 的 Extended self-test polling time，实际启动后以工具回报的预计完成时间为准。先预留一晚到一天以上。作为量级参考，14 TB 若由主机以 150–200 MB/s 顺序读完，约需 19–26 小时；WD 给这款 14 TB 的最大持续速率为 233 MB/s。主机全盘读的估时和固件自检的 ETA 用各自的口径。 [smartctl 手册](https://manpages.ubuntu.com/manpages/resolute/man8/smartctl.8.html) · [WD HC620 规格表](https://documents.westerndigital.com/content/dam/doc-library/en_us/assets/public/western-digital/product/data-center-drives/ultrastar-dc-hc600-series/data-sheet-ultrastar-dc-hc620.pdf)

```bash
# 替换成实机已核对的七个 ATA 整盘 by-id，按 SATA0–6 排列。
hdds=(/dev/disk/by-id/ata-REPLACE_SATA{0..6})
# 输出应为七个不同的 14 TB host-managed 整盘。
lsblk -dn -o NAME,MODEL,SERIAL,SIZE,TYPE,ZONED "${hdds[@]}"
# 把 logdir 指向 SanDisk 临时系统的日志目录。
logdir="$PWD/logs/hc620"
mkdir -p "$logdir"
for disk in "${hdds[@]}"; do
    sudo smartctl -x "$disk" > "$logdir/${disk##*/}.before.txt" 2>&1
done
# 先看各盘报告和已有自检状态，再发起新测试。
for disk in "${hdds[@]}"; do
    sudo smartctl -t long "$disk" 2>&1 | tee "$logdir/${disk##*/}.start.txt"
done
# 过一段时间按需查看进度及温度。
for disk in "${hdds[@]}"; do
    sudo smartctl -c -l selftest -A "$disk"
done
# 全部完成后留档。smartctl 的非零状态也可能来自历史错误，需读报告。
for disk in "${hdds[@]}"; do
    sudo smartctl -x "$disk" > "$logdir/${disk##*/}.after.txt" 2>&1
done
```

测试期间保持供电、通风，关闭自动休眠，避免同时跑 HDD 压测。每盘验最新一条 Extended 为 `Completed without error`，用启动前后日志的通电小时、序号和状态确认是这次结果。关注新增重映射、待处理扇区、不可校正扇区，以及内核 I/O 错误。若新增 SATA CRC 错误或链路 reset，先复核线材、供电与端口；若自检因关机或 reset 中断，处理原因后补跑该盘。无须在原始 HC620 上跑 `badblocks -w`，这类随机位置写入会遇到主机管理 SMR 的顺序写限制。正式安装的 scrub 校验池内已有数据的 checksum，裸盘慢扫查各盘自身的介质与自检结果。 [OpenZFS scrub](https://openzfs.github.io/openzfs-docs/man/master/8/zpool-scrub.8.html)

### 主机基线

AX210 自 T1 一直留在槽 7。七盘运行时复查 Wi-Fi 连接和蓝牙控制器，确认重启能重新连网，并记录 `iwlwifi` 日志。板载网口只记录枚举。主机保持独立，保存硬件、内核、RAS、SMART 与 SATA 对应表。P620 为唯一显卡。

```bash
mkdir -p logs/host-baseline
sudo bash host/inventory.sh | tee logs/host-baseline/inventory.txt
sudo journalctl -k -b --no-pager > logs/host-baseline/kernel.txt
sudo ras-mc-ctl --errors > logs/host-baseline/ras.txt
lsblk -e 7 -o NAME,PATH,MODEL,SERIAL,SIZE,TRAN,ZONED
```

七盘自检和主机基线通过后进 T5。

## T5. 算力坞 V100 与 PCIe 拷机

- T4 通过后，先在临时系统按 [NVIDIA 显卡驱动安装步骤](INSTALL.md#安装并锁定-nvidia-显卡驱动) 装驱动、确认 P620。关机断电接坞。逐卡、每槽两卡、四卡依次冷启动。按实际 V100 UUID 选择测试设备，`nvidia-smi -q -d ECC,POWER,TEMPERATURE,PCI` 保存前后。GPU Burn 用 CUDA 12.9.1 `make COMPUTE=70` 构建。分别跑单卡 15 min，再四卡 `gpu_burn -m 80% -tc 3600`，查校验、温度、频率、功耗、泵、VRM/HBM 和接头热浸。 [GPU Burn](https://github.com/wilicc/gpu-burn)
- 正常关机再换线。每次检查新增 Xid、AER、GPU ECC、PCIe 降宽，对照无坞基线核存储设备枚举。四卡通过后执行 [P2P/NCCL](INSTALL.md#算力坞验收)，再按 [pinned DMA 命令](PMEM.md#四卡-pinned-dma-验收) 验证双路 DDR4 交错下四卡能同时传输。然后做 1017 冒烟。

### T5 末的 1017 推理冒烟

在 T5 开始时即可准备权重，约 232 GiB，Wi-Fi 下载时间单独安排。用临时 Xubuntu 的用户运行。编译和日志放 SanDisk 上的临时 Xubuntu，先用 `df -h / /var/lib` 核对剩余空间，再装 Docker 和下载 CUDA 构建镜像。模型权重直接写 T3 的正式模型卷。以下从 `z8-kit` 根目录执行；已挂载的卷也可用同一条 `mount` 命令核验。

```bash
kit=$(realpath .)
sudo apt install docker.io libgomp1 libssl3t64 numactl pipx
sudo systemctl enable --now docker.service
export PATH="$HOME/.local/bin:$PATH"
pipx install huggingface_hub
sudo bash host/pmem-dax-stripe.sh mount "$FS0_UUID" "$FS1_UUID"
findmnt -rn -M /srv/pmem-model -t xfs -O dax=always || exit 1
mkdir -p "$HOME/z8-smoke"
cd "$HOME/z8-smoke"
```

复制 [llama.cpp 主服务](../inference/README.md#llamacpp-v100-主服务) 中的编译、下载和启动命令，先完成下载，四卡硬件测试通过后再启动模型。`CUDA_VISIBLE_DEVICES` 和 `Z8_DRAM_INTERLEAVE` 用 T5、T3 记录的实值。用 `xfs_io -r -c 'fiemap -v' "$DS41_GGUF"` 记录首分片的 extent。另开终端执行下列命令，从仓库 `z8-kit` 根运行。若已切到 Xolotl，用 `--base http://127.0.0.1:8150/v1 --reasoning-effort none` 替换 `--usage`，以 Xolotl 服务日志记录生成速度。`--prompt-file` 可省略，冒烟用探针自带的短提示即可。

```bash
python3 inference/probe.py --usage --repeats 1 --tools
nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv
sudo journalctl -k -b -g 'NVRM|Xid' --no-pager
```

记录各卡显存、DDR4 页位置、是否能出字、工具往返和生成速度。显存不足时按推理手册依次降到 4 GiB 专家缓存、单槽，再试 Xolotl。工具往返成功且生成达到 5 tok/s 就进入 I1。2–5 tok/s 仍可进 I1，I6 给一天处理该差距。两种引擎均无法加载或降档后仍低于 2 tok/s 时，在验机窗口内决定算力坞的去留。完成后停服务、关机并断开 V100。

## I7. 正式安装后的整机混合负载

按 [CPU 分核手册](CPU-PLACEMENT.md) 配置每路 6 核，核启停时普通任务 CPU 集合的变化。随后以这套正式配置跑一次 8 小时混合负载，涵盖 Buck2 上传、冷读和热读、1017 的实际工具请求、SSH/RDP。I6 通过双槽时使用两个并发 harness，单槽方案用串行请求。全程要求无新增 Xid、AER、MCE、不可解释的 CE、SMART/NVMe 介质错误、ZFS 校验错误或 OOM。出现错误回到相关硬件阶段复现。

```bash
# 分开终端运行，日志落 P4618。先确认 log 与测试进程都能在当前用户运行。
nvidia-smi --query-gpu=timestamp,index,temperature.gpu,power.draw,pcie.link.gen.current,pcie.link.width.current --format=csv -l 5 > gpu.csv
iostat -xz 5 > iostat.log
sudo zpool iostat -v z8data 5 > zpool-iostat.log
sudo journalctl -kf -o short-monotonic > kernel-follow.log
```

用 I5 确认的远程执行配置轮流执行 clean checkout 的 Buck2 目标和短增量构建，并保持指向本地 1017 的 OMP 工单或 `inference/probe.py` 回放。开始与结束各抓一次 `sudo bash host/pmem-numa-report.sh <PID>`。如果主系统安装了 ipmctl，同时保存 `sudo ipmctl show -sensor`。记录构建完成时间、推理 p95 首字延迟和 decode 速度作为上线基线。
