# 引导与系统盘

## I1. 安装 Xubuntu 26.04.1

### I1.1 用 Ubuntu Server 26.04.1 准备正式安装

Xubuntu Desktop Live 用于 T1–T5 验机和 I1 救援。正式系统用 Ubuntu Server 26.04.1 的 Subiquity 安装 RAID0/XFS，再安装同版 `xubuntu-desktop`。Server 支持 md RAID0，Desktop 安装器的 mdadm 问题 [#1210](https://github.com/canonical/ubuntu-desktop-provision/issues/1210) 仍开放。由 Curtin 一次创建阵列和三个文件系统。 [Subiquity 的 RAID 支持](https://canonical-subiquity.readthedocs-hosted.com/en/latest/howto/configure-storage.html#raid)

T5 通过后关机断电，断开 V100、七块 HC620 和 P4800X，拔掉临时系统盘。保留 DDR4、PMem、P620、P4618 和接好天线的 AX210。插入 Samsung FIT 目标盘、校验 SHA-256 后写好的 Server ISO U 盘，以及下节的 CIDATA 介质。用 F9 选 Server 介质的 UEFI 入口。 [Ubuntu Server 26.04.1 ISO](https://releases.ubuntu.com/26.04/)

| 设备 | 布局 |
|---|---|
| Samsung FIT 128 GB | 1 GiB FAT32 ESP 挂 `/boot/efi`，8 GiB ext4 挂 `/boot` |
| P4618 两个 3.2 TB NVMe | 各取一个等大的成员分区，md RAID0、metadata 1.2、512 KiB chunk。XFS 挂 `/`，显式 `crc=1,reflink=1` 和 `su=512k,sw=2` |

8 GiB ext4 供已验内核、新版试启项和生成 initramfs 时的临时文件使用。512 KiB 是 26.04 mdadm 的创建默认值，Curtin 创建阵列时沿用该值。 [mdadm 默认 chunk](https://manpages.ubuntu.com/manpages/resolute/man8/mdadm.8.html) · [Curtin mdadm 源码](https://github.com/canonical/curtin/blob/main/curtin/block/mdadm.py)

**Dracut 负责生成 initramfs。** Ubuntu 从 25.10 开始切换默认生成器，Ubuntu Server 26.04.1 新装直接使用 Dracut。Canonical 采用它来统一早期启动的 systemd 工作方式，并复用上游的存储和网络启动模块。 [Ubuntu 26.04 发布说明](https://documentation.ubuntu.com/release-notes/26.04/summary-for-lts-users/#dracut) · [Canonical 的切换设计](https://discourse.ubuntu.com/t/spec-switch-to-dracut/54776)

本机开机时，固件启动 Samsung FIT ESP 上的 GRUB。GRUB 从 FIT 的 `/boot` 读取内核和 `initrd.img-*`，Linux 将后者解开到内存，作为临时根。这个临时环境用 NVMe 驱动看到 P4618 的两个成员，交给 `mdadm` 组装 RAID0，再挂载 XFS `/` 并切进正式系统。I1.4 用 `dracut` 更新这份镜像，用 `lsinitrd` 检查其中的组件。

### I1.2 生成安装配置并核身份

在 T4 记录 FIT 和 P4618 两个硬件端点的 **三个唯一 `ID_SERIAL`**。给变量填已确认的整盘 by-id，在验机系统执行下列命令。若只有一个 P4618 端点或共享上行低于 Gen3 x8，回到 [T4 链路检查](BURN-IN.md#p4618-链路与双控制器)。

```bash
FIT=/dev/disk/by-id/usb-REPLACE_FIT
A=/dev/disk/by-id/nvme-REPLACE_P4618_A
B=/dev/disk/by-id/nvme-REPLACE_P4618_B
lsblk -d -o NAME,PATH,MODEL,SERIAL,SIZE,TRAN "$FIT" "$A" "$B"
for disk in "$FIT" "$A" "$B"; do
    udevadm info --query=property --name="$disk" | grep '^ID_SERIAL='
done
```

把 [安装配置](root-storage.yaml.example) 复制为 `user-data`。替换三个 `REPLACE_*_ID_SERIAL`，每项整串抄录且不含 `ID_SERIAL=` 前缀。填写密码哈希，可用 `openssl passwd -6` 交互生成。把 `user-data` 与空 `meta-data` 放到一个卷标为 `CIDATA` 的独立 FAT 卷根目录。这个配置会重建三个目标设备的分区表。安装脚本在写盘前停在 `early-commands` 等待设备核对。CIDATA 内含密码哈希，保存在本地介质。 [Canonical NoCloud 安装指南](https://canonical-subiquity.readthedocs-hosted.com/en/latest/tutorial/providing-autoinstall.html) · [Subiquity 按序列号匹配](https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html#disk-selection-extensions)

从 Server 介质进 Subiquity，切到安装器的另一控制台。核对本次启动的三个序列号、设备容量和 `/autoinstall.yaml` 里的 storage 匹配项，确认三块设备可清空后再运行 `sudo touch /run/z8-storage-confirmed`，然后回到安装器处理其确认提示。若配置未加载或序列号对不上，停在写盘前检查 CIDATA。基础系统可离线完成，从 FIT 启动后装桌面和远程入口。

### I1.3 安装桌面

若安装阶段没连上 Wi-Fi，在本机控制台先给 AX210 配网络。缺 `wpasupplicant` 时用手机 USB 网络共享安装，或在 T1 已联网的临时系统准备 26.04 的包和依赖。用 `ip -br link` 确认接口名，把以下内容写到 `/etc/netplan/90-z8-wifi.yaml`。家庭 WPA2/WPA3 兼容模式使用预共享密钥。文件设 0600，执行 `sudo netplan try`，确认默认路由和 APT 可用后接受配置。 [Netplan 无线配置](https://netplan.readthedocs.io/en/latest/netplan-yaml/)

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

```bash
sudo apt update
sudo apt install xubuntu-desktop
sudo reboot
```

### I1.4 核验 FIT 引导并做救援验证

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
id jackywang
sudo xfs_info /
```

首启应看到主机名 `jackywang-xubuntu-max`、用户 `jackywang` 和根卷的 `reflink=1,sunit=128,swidth=256`（4 KiB XFS 块）。 [Ubuntu 26.04 mkfs.xfs](https://manpages.ubuntu.com/manpages/resolute/man8/mkfs.xfs.8.html)

### 首启后定稿挂载参数

按 [全机挂载表](MOUNTS.md) 和 [fstab 样例](fstab-boot.example) 修改安装器写好的三行。保留实际文件系统 UUID 及其他行，完成 `findmnt --verify` 后更新 initramfs 和 GRUB。另在 `/etc/mdadm/mdadm.conf` 核对目标阵列 UUID，避免重复写入 ARRAY 项。将 `mdraid` 模块和 `nvme`、`raid0`、`xfs` 驱动写入 Dracut 的持久配置，供本次和以后构建 initramfs 使用。 [Dracut 26.04 配置手册](https://manpages.ubuntu.com/manpages/resolute/man5/dracut.conf.5.html)

```bash
sudo install -d /etc/dracut.conf.d
printf '%s\n' 'add_dracutmodules+=" mdraid "' 'force_drivers+=" nvme raid0 xfs "' | \
    sudo tee /etc/dracut.conf.d/51-z8-root.conf
abi=$(uname -r)
sudo dracut --force "/boot/initrd.img-$abi" "$abi"
sudo update-grub
sudo lsinitrd -m "/boot/initrd.img-$abi" | grep -w mdraid
sudo lsinitrd "/boot/initrd.img-$abi" | grep -E '(^|/)(mdadm|raid0\.ko|xfs\.ko|nvme\.ko)'
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
sudo install -d -m 0700 -o jackywang -g "$(id -gn jackywang)" /srv/work/jackywang
findmnt -T /srv/work/jackywang -o SOURCE,TARGET,FSTYPE
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

从解压的 kit 根运行。核 R580 candidate 是实际驱动、安装模拟使用专有 R580 和配套 generic 模块。然后执行 `sudo apt install linux-modules-nvidia-580-generic nvidia-driver-580`。如模块元包拉入更新的 generic 内核，让本次重启进入该内核。系统依旧保持 UEFI，Secure Boot 已在 BIOS 关闭。 [Ubuntu generic R580 模块包](https://packages.ubuntu.com/resolute/linux-modules-nvidia-580-generic) · [APT 优先级](https://manpages.ubuntu.com/manpages/resolute/man5/apt_preferences.5.html)

```bash
# 重启后在正式系统执行。
uname -r
modinfo -F version nvidia
modinfo -F license nvidia
nvidia-smi -L
nvidia-smi --query-gpu=name,pci.bus_id,driver_version --format=csv
sudo journalctl -k -b -g 'NVRM|Xid'
```

确认 P620 正常、R580 已加载、SSH 仍能登录，按 [远程手册](../remote/README.md#sunshine) 验 Sunshine/NVENC。关机断电后接回通过 T5 的四张 V100。再开机，复查四张 V100 的 UUID、拓扑与快速 CUDA/NCCL，并在 Moonlight 串流时再核一次捕获的显示接口和 P620 的编码会话，然后进入 I4。今后更新内核或驱动前先模拟升级，保留上一版已知可启动的内核，并在重启后查 NVIDIA、ZFS 与 dm-zoned。

## 固定 GA 轨道并试启新内核

两套测试系统分别记录实际 ABI。临时 Xubuntu 在 T1 安装微码和当前 GA 更新后记录 `uname -r`，后续测试一直从该项启动。正式安装的 ISO、APT 和 R580 预编译模块若带来不同 ABI，在 I3 复跑 CUDA/NCCL，在 I4 复验 ZFS 与 dm-zoned。冻结从各自跑通所需组件后开始，等 I7 通过解除正式系统的 hold。临时系统的 hold 无法跨到新装系统。 [Ubuntu 内核轨道](https://documentation.ubuntu.com/kernel/reference/hwe-kernels/) · [Ubuntu 自动安全更新](https://documentation.ubuntu.com/security/security-updates/#automatic-security-updates)

```bash
sudo install -m 0644 host/z8-no-hwe.pref.example /etc/apt/preferences.d/z8-no-hwe
sudo install -m 0644 host/51z8-kernel-manual.example /etc/apt/apt.conf.d/51z8-kernel-manual
dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-generic*' 'linux-modules-nvidia-*'
apt-cache policy linux-generic linux-generic-hwe-26.04 linux-modules-nvidia-580-generic
apt-config dump | grep -F 'Unattended-Upgrade::Package-Blacklist'
sudo unattended-upgrade --dry-run
# GA 元包已装时，验机期间在当前系统 hold。
sudo apt-mark hold linux-generic linux-image-generic linux-headers-generic
apt-mark showhold
```

I3 安装 R580 后，在正式系统追加驱动 hold。

```bash
sudo apt-mark hold linux-modules-nvidia-580-generic
apt-mark showhold
```

I7 通过后，在正式系统运行 `sudo apt-mark unhold linux-generic linux-image-generic linux-headers-generic linux-modules-nvidia-580-generic`。已经装过 HWE 的系统先装 GA 和配套模块并验证可启动，再移除 HWE 元包。上述 blacklist 只影响 unattended-upgrades。安排手动维护更新被排除的包，并用 `apt-get -s dist-upgrade` 检查升级集。要停用跨 Ubuntu 发行版提示，在 `/etc/update-manager/release-upgrades` 的现有 `[DEFAULT]` 段设 `Prompt=never`，继续更新 26.04 的软件源。

在插显示器时演练一次 GRUB 回滚。在 `/etc/default/grub.d/55-z8-saved.cfg` 写 `GRUB_DEFAULT=saved`、`GRUB_TIMEOUT_STYLE=menu`、`GRUB_TIMEOUT=5` 三行。在 `findmnt -M /boot` 确认源为 FIT 上独立 ext4，再执行下列命令。子菜单用 `父菜单 ID>子菜单 ID`，都从当前 `grub.cfg` 抄。用固定 ABI 的普通菜单项，避免默认项随新内核移动。 [Ubuntu grub-reboot](https://manpages.ubuntu.com/manpages/resolute/man8/grub-reboot.8.html)

```bash
findmnt -M /boot -o SOURCE,FSTYPE,OPTIONS
df -h /boot /boot/efi
du -h /boot/initrd.img-* /boot/vmlinuz-*
sudo update-grub
sudo grep -E '^[[:space:]]*(submenu|menuentry) ' /boot/grub/grub.cfg
old_abi=$(uname -r)
old_entry='REPLACE_SUBMENU_ID>REPLACE_OLD_KERNEL_MENUENTRY_ID'
sudo grub-set-default "$old_entry"
sudo grub-editenv list
dpkg-query -W "linux-image-$old_abi" "linux-modules-$old_abi" \
    "linux-modules-extra-$old_abi" "linux-modules-nvidia-580-$old_abi"
# 把上面确实已安装的四项标为 manual，防止自动清理回退 ABI。
sudo apt-mark manual "linux-image-$old_abi" "linux-modules-$old_abi" \
    "linux-modules-extra-$old_abi" "linux-modules-nvidia-580-$old_abi"
sudo apt update
sudo apt-get -s dist-upgrade
# 把新 ABI 填作 7.0.0-N-generic，包含末尾的 -generic。
new_abi=REPLACE_NEW_ABI
apt-cache policy "linux-modules-nvidia-580-$new_abi"
```

模拟需包含目标 ABI 和对应 R580 模块，无意外卸载后才执行已审阅的升级。装完用 `modinfo -k "$new_abi" nvidia`、`modinfo -k "$new_abi" zfs`、`modinfo -k "$new_abi" dm_zoned` 查模块，并核 NVIDIA 用户态与保留的旧 ABI 模块版本也兼容。单次引导只回退内核，若同一交易升级了用户态驱动或 ZFS，旧 ABI 与新用户态仍需配套验证。试启前先停止作业。

```bash
sudo grep -E '^[[:space:]]*(submenu|menuentry) ' /boot/grub/grub.cfg
new_entry='REPLACE_SUBMENU_ID>REPLACE_NEW_KERNEL_MENUENTRY_ID'
sudo grub-reboot "$new_entry"
sudo grub-editenv list
sudo systemctl reboot
```

新内核起来后，核 `uname -r`、`grub-editenv list` 中 `next_entry` 已消费，并从客户端验证 Wi-Fi SSH。再查 `nvidia-smi -L`、`zpool status -x z8data`、`sudo dmsetup status --target zoned` 的七个成员、模型卷的实际挂载点、`sudo daxctl list` 两路 online 和 `sudo journalctl -k -b -p err`。成功才 `sudo grub-set-default "$new_entry"`。若试启失联，机旁优先用控制台重启或从 GRUB 选择旧项。先在本机验证一次性项确实被消费，才依赖下一次重启回旧项。

## 算力坞验收

T5 从临时系统运行本节，I3 在正式系统复测。按 [PCIe P2P 的 IOMMU 设置](BIOS.md#接坞后的-pcie-p2p) 区分 NVLink 与 PCIe，确定内核启动参数后再做数据传输测试。用 CUDA 12.9.1 工具链构建 CUDA Samples 和 nccl-tests。在各自 checkout 构建后，显式给四张 V100 的 UUID。用实际构建输出路径替换下面两个可执行文件。

```bash
export CUDA_DEVICE_ORDER=PCI_BUS_ID
export CUDA_VISIBLE_DEVICES=GPU-REPLACE0,GPU-REPLACE1,GPU-REPLACE2,GPU-REPLACE3
/path/to/p2pBandwidthLatencyTest
NCCL_DEBUG=INFO /path/to/all_reduce_perf -b 8 -e 256M -f 2 -g 4
```

记录每对 P2P 可达性与带宽、all-reduce 错误数和带宽。分别测试两张同 socket 卡与跨 socket 卡。用 CUDA H→D/D→H 负载运行时从另一终端读 `nvidia-smi -q -d PCI`，确认实际 Gen3 x8。加载四卡与 CPU 后检查 `journalctl -k -b` 的新增 Xid、AER、ECC；保留日志和各卡温度、功耗。 [NVIDIA CUDA 样例](https://github.com/NVIDIA/cuda-samples) · [NVIDIA nccl-tests](https://github.com/NVIDIA/nccl-tests)
