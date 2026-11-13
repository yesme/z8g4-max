# 引导与系统盘

## I1. 安装 Xubuntu 26.04.1

### I1.1 用独立安装 U 盘进 Live

T5 通过后关机断电，拔掉四根 V100 PCIe 线，暂时断开七块 HC620 和 P4800X。保留 DDR4、PMem、P620、P4618 和带两根天线的 AX210。插入两只不同的 USB 设备，区分 Samsung FIT 目标盘与 Xubuntu 安装盘。校验 ISO 的 SHA-256 后按 F9 选安装盘的 UEFI 入口，进入试用桌面。用 Xfce 网络图标重新连接 T1 已验证的 Wi-Fi，确认有 DHCP 地址、默认路由和 DNS，再装 Live 缺的 `mdadm`、`nvme-cli`。镜像带 `7.0.0-30-generic`、`gdisk`、`parted`、`dosfstools` 和 `xfsprogs`。 [T1 联网](BURN-IN.md#首次-live-wi-fi-与临时验机系统) · [Xubuntu 镜像包清单](https://cdimage.ubuntu.com/xubuntu/releases/26.04/release/xubuntu-26.04.1-desktop-amd64.manifest)

```bash
test -d /sys/firmware/efi && echo 'UEFI boot'
uname -r
sudo apt update
sudo apt install mdadm nvme-cli
sudo nvme list -v
lsblk -e 7 -o NAME,PATH,MODEL,SERIAL,SIZE,TRAN,TYPE,FSTYPE,MOUNTPOINTS
ls -l /dev/disk/by-id/usb-* /dev/disk/by-id/nvme-*
```

确认两个约 3.2 TB 端点属于同一张 P4618 的两个控制器，各取一个唯一整盘 by-id。若仅枚举出一个端点，先按 T4 基线复核槽 1 设置和实际链路，再决定是否用这个端点装 XFS 根。FIT 继续负责引导。Live 缺网时先按 T1 排查；若 Wi-Fi 暂时不可用，可以从已联网的 26.04 系统下载 `mdadm`、`nvme-cli` 和 Live 缺的依赖，带 `.deb` 回来安装。I1.3 负责图形安装器无法接管 RAID/XFS 的情况。 [Intel P4610/P4618 产品资料](https://fenixalliance.swcontentsyndication.com/sw/swchannel/CustomerCenter/documents/19765/76825/dc-p4610-p4618-series-brief.pdf)

| 设备 | 分区 | 用途 |
|---|---|---|
| Samsung FIT | 1 GiB FAT32 ESP、2 GiB ext4 | `/boot/efi` 和 `/boot` |
| P4618 namespace A | RAID 成员分区 | 与 B 等大 |
| P4618 namespace B | RAID 成员分区 | 与 A 组 RAID0 |
| 独立 USB | Xubuntu 或 Ubuntu Server 安装/救援 | 引导、chroot、恢复 |

### I1.2 Live 中预建阵列，再检查图形安装器

把三项换成 I1.1 实机确认的整盘 by-id。先运行识别块并查看输出。下一块会重建这三块盘的分区表，三者必须是允许清空、均未挂载的目标盘，且 A/B 应等容量。检查两个 NVMe 端点身份与安装 U 盘的挂载来源后再继续。

```bash
FIT=/dev/disk/by-id/usb-REPLACE_FIT
A=/dev/disk/by-id/nvme-REPLACE_P4618_A
B=/dev/disk/by-id/nvme-REPLACE_P4618_B
readlink -e "$FIT" "$A" "$B"
lsblk -o NAME,PATH,MODEL,SERIAL,SIZE,TYPE,FSTYPE,MOUNTPOINTS "$FIT" "$A" "$B"
findmnt /cdrom
sudo wipefs -n "$FIT" "$A" "$B"
```

保持在同一终端执行。md chunk 采用 512 KiB。内核认到新分区后才建阵列并格式化。

```bash
sudo sgdisk --clear -n 1:0:+1G -t 1:ef00 -c 1:Z8-ESP \
    -n 2:0:+2G -t 2:8300 -c 2:Z8-BOOT "$FIT" &&
sudo sgdisk --clear -n 1:0:0 -t 1:fd00 -c 1:Z8-RAID-A "$A" &&
sudo sgdisk --clear -n 1:0:0 -t 1:fd00 -c 1:Z8-RAID-B "$B" &&
sudo partprobe "$FIT" "$A" "$B" &&
sudo udevadm settle
lsblk -o NAME,PATH,SIZE,TYPE,PARTLABEL "$FIT" "$A" "$B"
```

```bash
sudo mdadm --create /dev/md/z8root --metadata=1.2 --level=0 \
    --raid-devices=2 --chunk=512 "${A}-part1" "${B}-part1"
sudo mdadm --detail /dev/md/z8root
cat /proc/mdstat
```

核对详情是 RAID0、两个正确成员且均在线。然后建三个文件系统，查看而不挂载：

```bash
sudo mkfs.xfs -m crc=1,reflink=1 -L z8root /dev/md/z8root
sudo mkfs.fat -F 32 -n Z8ESP "${FIT}-part1"
sudo mkfs.ext4 -L z8boot "${FIT}-part2"
lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$FIT" "$A" "$B"
```

打开图形安装器，选手动分区，核对下面三项。阵列也可能显示为 `/dev/md127`，用 `mdadm --detail` 对照。空卷若由安装器重新格式化，安装预览仍应显示 XFS 根、FIT ext4 与 FIT ESP。预览须保留两个 P4618 成员分区。跳过安装器自动加装第三方显卡驱动的选项，留到 I3。在用户页将计算机名设为 `z8g4-max`，用户名设为 `z8user`。Server 安装器的 Profile setup 填同样两项。自动安装时合入样例的 `identity:`，将密码占位符替换为自己的密码哈希。 [Subiquity identity](https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html#identity)

| 安装器必须认得的设备 | 分配 |
|---|---|
| 已组装的 `z8root` | XFS，挂 `/` |
| FIT 的 2 GiB ext4 | 挂 `/boot` |
| FIT 的 1 GiB FAT32 ESP | EFI 系统分区，挂 `/boot/efi` |

任一项无法选择，或预览显示会重建 P4618 成员，就退出图形安装器，在写盘前转 I1.3。Canonical 桌面安装器的 mdadm 支持问题仍开放，能否接管这组预建布局需在目标 Live 环境看安装器结果。 [Canonical Desktop 安装器的 mdadm 进度](https://github.com/canonical/ubuntu-desktop-provision/issues/1210)

### I1.3 用 Ubuntu Server 26.04.1 安装并加 Xfce

用同版本 Ubuntu Server 26.04.1 ISO 启动，进入 **Custom storage layout**。Subiquity 支持在 shell 预建 md 后到存储界面选择。若 I1.2 已建好阵列，在进入存储界面前用 `cat /proc/mdstat` 检查是否自动组装。未组装时用 `sudo mdadm --assemble /dev/md/z8root "${A}-part1" "${B}-part1"`，A/B 需按这次启动复核。界面中把 FIT 设为引导盘，并按 I1.2 的表分配三个挂载点。若还未建阵列，在两端各建等大的未格式化分区，用 **Create software RAID (MD)** 选择 RAID0，再将阵列格式化为 XFS、挂到 `/`。 [Ubuntu Server ISO](https://releases.ubuntu.com/26.04/) · [Subiquity 存储操作](https://canonical-subiquity.readthedocs-hosted.com/en/latest/howto/configure-storage.html)

需要让安装器重建精确布局时，把 [root-storage.yaml.example](root-storage.yaml.example) 的 `storage:` 并入 `autoinstall:`，从 `interactive-sections` 移除 `storage`。这个样例会重建 FIT 和两个 P4618 端点的分区表。若本次空阵列仍处于组装状态，用 `lsblk` 和 `mdadm --detail` 确认它未挂载、两个成员均为本次目标，再用 `sudo mdadm --stop /dev/md/z8root`（按实际 md 名）停止。填本次启动的设备值，FIT 用 udev 的 `ID_SERIAL`，P4618 两端用内核路径。 [Subiquity 设备匹配](https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html#disk-selection-extensions) · [Curtin RAID](https://curtin.readthedocs.io/en/latest/topics/storage.html#raid-command)

```bash
test -d /sys/firmware/efi
lsblk -o NAME,PATH,MODEL,SERIAL,SIZE,TRAN
nvme list
udevadm info --query=property --name=/dev/REPLACE_FIT | grep '^ID_SERIAL='
```

用独立介质或 NoCloud 按 [官方方法](https://canonical-subiquity.readthedocs-hosted.com/en/latest/tutorial/providing-autoinstall.html) 提供完整 autoinstall。可在 `autoinstall:` 下加入以下早期命令。停住时从安装器另一终端核对 `/autoinstall.yaml` 的三个匹配项与上面的设备输出，确认后执行 `sudo touch /run/z8-storage-confirmed` 继续。为免把之前启动的枚举套到这次，核对使用本次 `lsblk` 和 `nvme list -v`。

```yaml
early-commands:
  - while [ ! -e /run/z8-storage-confirmed ]; do sleep 1; done
```

Subiquity 的网络页若列出 AX210，在那里选实际 SSID 并确认联网，安装完成后从 FIT 首启先检查 `ip -br address` 和默认路由。网络页若没有可用 Wi-Fi，可以离线完成基础系统。先用已联网的临时 Xubuntu 下载 `wpasupplicant` 和 Server 缺的依赖，或用手机 USB 网络共享让 Server 临时联网安装该包。然后按下例添加独立 `/etc/netplan/90-z8-wifi.yaml`，把接口名、SSID、口令换成实值。用 `sudo chmod 600 /etc/netplan/90-z8-wifi.yaml` 收紧权限，在本机控制台 `sudo netplan try`，核默认路由和 APT 后确认。此例用于家庭 WPA2/WPA3 兼容模式的预共享密钥网络，纯 WPA3 或企业网按实际认证方式配置。联网后执行 `sudo apt update` 和 `sudo apt install xubuntu-desktop`，再重启验证 Xfce。 [Subiquity 基本安装](https://canonical-subiquity.readthedocs-hosted.com/en/latest/howto/basic-server-installation.html) · [Netplan 无线配置](https://netplan.readthedocs.io/en/latest/netplan-yaml/)

```yaml
network:
  version: 2
  wifis:
    REPLACE_WITH_AX210_INTERFACE:
      renderer: networkd
      dhcp4: true
      access-points:
        "REPLACE_WITH_SSID":
          password: "REPLACE_WITH_PASSWORD"
```

### I1.4 从 FIT 首启并做救援验证

首启后在系统内核对以下信息。若缺 `mokutil` 或 `efibootmgr`，先执行 `sudo apt install mokutil efibootmgr`。更新内核前确保 ESP 和 `/boot` 实际指向 FIT 分区。

```bash
findmnt /
findmnt /boot
findmnt /boot/efi
uname -r
test -d /sys/firmware/efi && echo 'UEFI boot'
LC_ALL=C mokutil --sb-state  # SecureBoot disabled
sudo efibootmgr -v
sudo mdadm --detail --scan
cat /proc/mdstat
hostnamectl --static
id z8user
sudo xfs_info /
```

首启应看到主机名 `z8g4-max`、用户 `z8user` 和根卷 `reflink=1`。Xubuntu 26.04.1 的 `mkfs.xfs` 默认启用 reflink，Live 预建已显式指定，安装器格式化路径也在这里核实。该属性在 mkfs 时决定。 [Ubuntu 26.04 mkfs.xfs](https://manpages.ubuntu.com/manpages/resolute/man8/mkfs.xfs.8.html)

### 首启后定稿挂载参数

按 [全机挂载表](MOUNTS.md) 和 [fstab 样例](fstab-boot.example) 修改安装器写好的三行。保留实际文件系统 UUID 及其他行，完成 `findmnt --verify` 后更新 initramfs 和 GRUB。另在 `/etc/mdadm/mdadm.conf` 核对目标阵列 UUID，避免重复写入 ARRAY 项。

```bash
sudo update-initramfs -u -k all
sudo update-grub
lsinitramfs "/boot/initrd.img-$(uname -r)" | grep -E '(^|/)(mdadm|raid0\.ko|xfs\.ko)'
```

第一次验证后再关机冷启一次，确认固件仍选中 FIT、三个挂载点一致、两个 md 成员齐全。若首启落到 initramfs，先用独立救援盘执行下一段的组装检查。

留存 RAID、GPT、EFI、fstab、mdadm.conf、驱动和软件包清单。故障恢复时从独立 USB UEFI 启动，核对所有设备后组装目标 md，按原次序挂根、boot、ESP，bind-mount `/dev`、`/proc`、`/sys`、`/run` 后 chroot 检查。先验证救援能读根，再按是否损坏 GRUB/EFI 决定重装引导。阵列成员失效按根备份重建。将救援 USB 与常驻启动 USB 做物理区分。

用本机控制台确认 AX210 已连接 Wi-Fi，安装基础组件，然后按 [远程入口](../remote/README.md) 做 I2。先从另一台机器验 SSH 与 xrdp，之后才动显卡驱动。

```bash
sudo apt update
sudo apt install mdadm xfsprogs nvme-cli numactl pciutils dmidecode \
    smartmontools mokutil efibootmgr openssh-server tmux intel-microcode \
    linux-firmware-intel-wireless
```

### 目录和实际存储

`/srv` 是标准的本机服务数据目录，系统镜像通常已提供空目录。我们决定其中每个子目录的用途，并手动建目录或挂载点。本机的 `/srv` 默认属于 P4618 的根 XFS。创建命令可以补齐缺失的父目录。 [Filesystem Hierarchy Standard 的 /srv](https://specifications.freedesktop.org/fhs/latest/srv.html)

```bash
sudo install -d -m 0755 /srv/work /srv/buildbarn
sudo install -d -m 0700 -o z8user -g "$(id -gn z8user)" /srv/work/z8user
findmnt -T /srv/work/z8user -o SOURCE,TARGET,FSTYPE
findmnt -T /srv/buildbarn -o SOURCE,TARGET,FSTYPE
```

两个查询应显示 P4618 的 md 根卷、挂载点 `/` 和 `xfs`。I5 创建并按容器权限配置 `/srv/buildbarn/tiered`。I4 用 `sudo install -d -m 0755 /srv/pmem-model` 创建空的挂载点，随后挂载 PMem ext4 DAX。只有 `findmnt -rn -M /srv/pmem-model -t ext4 -O dax=always` 成功才下载模型或建 KV 文件目录。卸载后该路径再次指向 P4618 上的空目录。XFS reflink 的本地检查见 [Buck2 与工作树](../buildbarn/README.md#git-worktree-与-xfs-reflink)。

## 安装并锁定 NVIDIA 显卡驱动

I3 开始时 V100 断开、P620 在槽 4。**R580 是 NVIDIA Linux 显卡驱动的 580.x 分支**，也是 NVIDIA 最后一条同时支持 V100（Volta）和 P620（Pascal）的驱动分支。这台机安装 Ubuntu 的专有驱动包 `nvidia-driver-580`，并接受该分支的补丁更新。2026 年 11 月 13 日核对的 APT 组合为 `580.178.04-0ubuntu0.26.04.1` 和 `linux-modules-nvidia-580-generic 7.0.0-43.43`。第三方 CUDA 构建留在独立用户空间，目标 `sm_70` 用 CUDA 12.x。 [NVIDIA 驱动支持矩阵](https://docs.nvidia.com/datacenter/tesla/drivers/cuda-toolkit-driver-and-architecture-matrix.html) · [580.x 支持的 GPU](https://download.nvidia.com/XFree86/Linux-x86_64/580.159.03/README/supportedchips.html) · [Ubuntu 驱动包](https://packages.ubuntu.com/resolute-updates/nvidia-driver-580) · [Ubuntu 驱动安装](https://ubuntu.com/server/docs/how-to/graphics/install-nvidia-drivers/)

```bash
sudo install -m 0644 host/z8-nvidia-580.pref.example /etc/apt/preferences.d/z8-nvidia-580
sudo apt update
uname -r
apt-cache policy nvidia-driver-580 nvidia-driver-580-open linux-modules-nvidia-580-generic \
    "linux-modules-nvidia-580-$(uname -r)"
apt-cache show nvidia-driver-580 | grep -E '^(Version|Depends|Description):'
sudo apt-get -s install linux-modules-nvidia-580-generic nvidia-driver-580
```

从解压的 kit 根运行。核 R580 candidate 是实际驱动、安装模拟使用专有 R580 和配套 generic 模块。然后执行 `sudo apt install linux-modules-nvidia-580-generic nvidia-driver-580`。如模块元包拉入更新的 generic 内核，让本次重启进入该内核。若准备保留当前 ABI，先用上面的 `apt-cache policy` 核对其配套模块有 Candidate，再单独装 `linux-modules-nvidia-580-$(uname -r)`。系统依旧保持 UEFI，Secure Boot 已在 BIOS 关闭。 [Ubuntu generic R580 模块包](https://packages.ubuntu.com/resolute/linux-modules-nvidia-580-generic) · [APT 优先级](https://manpages.ubuntu.com/manpages/resolute/man5/apt_preferences.5.html)

```bash
# 重启后在正式系统执行。
uname -r
modinfo -F version nvidia
modinfo -F license nvidia
nvidia-smi -L
nvidia-smi --query-gpu=name,pci.bus_id,driver_version --format=csv
sudo journalctl -k -b -g 'NVRM|Xid'
```

确认 P620 正常、R580 已加载、SSH 仍能登录，按远程手册验 Sunshine/NVENC。关机断电后接回通过 T5 的四张 V100。再开机，复查四张 V100 的 UUID、拓扑与快速 CUDA/NCCL，然后进入 I4。今后更新内核或驱动前先模拟升级，保留上一版已知可启动的内核，并在重启后查 NVIDIA、ZFS 与 dm-zoned。

## 算力坞验收

T5 从临时系统运行本节，I3 在正式系统复测。按 [PCIe P2P 的 IOMMU 设置](BIOS.md#接坞后的-pcie-p2p) 区分 NVLink 与 PCIe，确定内核启动参数后再做数据传输测试。用与驱动配套的 CUDA 12.x 样例和 nccl-tests。在各自 checkout 构建后，显式给四张 V100 的 UUID。用实际构建输出路径替换下面两个可执行文件。

```bash
export CUDA_DEVICE_ORDER=PCI_BUS_ID
export CUDA_VISIBLE_DEVICES=GPU-REPLACE0,GPU-REPLACE1,GPU-REPLACE2,GPU-REPLACE3
/path/to/p2pBandwidthLatencyTest
NCCL_DEBUG=INFO /path/to/all_reduce_perf -b 8 -e 256M -f 2 -g 4
```

记录每对 P2P 可达性与带宽、all-reduce 错误数和带宽。分别测试两张同 socket 卡与跨 socket 卡。用 CUDA H→D/D→H 负载运行时从另一终端读 `nvidia-smi -q -d PCI`，确认实际 Gen3 x8。加载四卡与 CPU 后检查 `journalctl -k -b` 的新增 Xid、AER、ECC；保留日志和各卡温度、功耗。 [NVIDIA CUDA 样例](https://github.com/NVIDIA/cuda-samples) · [NVIDIA nccl-tests](https://github.com/NVIDIA/nccl-tests)
