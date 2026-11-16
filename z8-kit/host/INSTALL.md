# 引导与系统盘

## I1. 安装 Xubuntu 26.04.1

### I1.1 从现有 Ventoy 启动 Xubuntu Desktop

I1 接两只 USB 设备。**三星 Portable SSD T3 250 GB（Ventoy）** 启动 `xubuntu-26.04.1-desktop-amd64.iso` 并存放安装 YAML，**三星 FIT 128 GB** 是引导盘的写入目标。T1–T5 的临时 Xubuntu 和验机记录留在 SanDisk CZ430 128 GB。按 [T5 交接步骤](FIRST-BOOT.md#2-t5-验算力坞) 保存记录并关机，拔下 SanDisk，再接 FIT。

T5 通过后关机断电，断开 V100、七块 HC620 和 D4800X。保留 DDR4、PMem、P620 和 P4618。优先接板载网口；还在用无线过渡时保留接好天线的 AX210。用 F9 选 Ventoy 的 UEFI 入口，在菜单选现有 Xubuntu 26.04.1 Desktop ISO。ISO 的 SHA-256 可在 Windows 用 `Get-FileHash -Algorithm SHA256` 核对。 [Xubuntu 26.04.1 ISO 与 SHA256SUMS](https://cdimage.ubuntu.com/xubuntu/releases/26.04.1/release/)

正式安装时，图形界面负责导入 YAML 和确认，Subiquity 把明确列出的磁盘动作交给 Curtin 创建阵列和文件系统。桌面安装器的 [#1210](https://github.com/canonical/ubuntu-desktop-provision/issues/1210) 涉及手动分区页找不到预建 md 阵列。I1 直接走自动安装，P4618 在这一阶段由安装器分区和组阵。 [桌面安装器导入配置](https://ubuntu.com/desktop/docs/en/latest/tutorial/install-ubuntu-desktop/#type-of-installation) · [Subiquity RAID 配置](https://canonical-subiquity.readthedocs-hosted.com/en/latest/howto/configure-storage.html#raid)

| 设备 | 布局 |
|---|---|
| Samsung FIT 128 GB | 1 GiB FAT32 ESP 挂 `/boot/efi`，8 GiB ext4 挂 `/boot`，p3 24 GiB ext4 `Z8TOOLS`，p4 8 GiB ext4 `Z8RECOVERY`，这两卷平时卸载。其余约 78 GiB 留空 |
| P4618 两个 3.2 TB NVMe | 各取一个等大的成员分区，md RAID0、metadata 1.2、512 KiB chunk。XFS 挂 `/`，显式 `crc=1,reflink=1` 和 `su=512k,sw=2` |

三星 FIT 128 GB 的 H2testw 实测为读取 **315 MB/s**、写入 **60 MB/s**（用户提供）。

8 GiB ext4 供已验内核、新版试启项和生成 initramfs 时的临时文件使用。512 KiB 是 26.04 mdadm 的创建默认值，Curtin 创建阵列时沿用该值。 [mdadm 默认 chunk](https://manpages.ubuntu.com/manpages/resolute/man8/mdadm.8.html) · [Curtin mdadm 源码](https://github.com/canonical/curtin/blob/main/curtin/block/mdadm.py)

**Dracut 负责生成 initramfs。** Ubuntu 从 25.10 开始切换默认生成器，Xubuntu 26.04.1 Desktop 镜像包含 Dracut。Canonical 采用它来统一早期启动的 systemd 工作方式，并复用上游的存储和网络启动模块。 [Ubuntu 26.04 发布说明](https://documentation.ubuntu.com/release-notes/26.04/summary-for-lts-users/#dracut) · [Xubuntu 26.04.1 软件包清单](https://cdimage.ubuntu.com/xubuntu/releases/26.04.1/release/xubuntu-26.04.1-desktop-amd64.manifest)

本机开机时，固件启动 Samsung FIT ESP 上的 GRUB。GRUB 从 FIT 的 `/boot` 读取内核和 `initrd.img-*`，Linux 将后者解开到内存，作为临时根。这个临时环境用 NVMe 驱动看到 P4618 的两个成员，交给 `mdadm` 组装 RAID0，再挂载 XFS `/` 并切进正式系统。I1.4 用 `dracut` 更新这份镜像，用 `lsinitrd` 检查其中的组件。

### I1.2 生成安装配置并核身份

在 T4 记录 FIT 和 P4618 两个硬件端点的 **三个唯一 `ID_SERIAL`**。把三个占位路径换成已确认的整盘 by-id，在验机系统从 `z8-kit` 根执行下列命令。若只有一个 P4618 端点或共享上行低于 Gen3 x8，回到 [T4 链路检查](BURN-IN.md#p4618-链路与双控制器)。

```bash
bash host/run-step.sh i1-disks /dev/disk/by-id/usb-REPLACE_FIT \
    /dev/disk/by-id/nvme-REPLACE_P4618_A /dev/disk/by-id/nvme-REPLACE_P4618_B
```

在 Windows 打开三星 T3 上 Ventoy **存放 ISO 的大数据分区**，在根目录新建 `z8` 文件夹，把 [安装配置样例](root-storage.yaml.example) 复制为 `z8\autoinstall.yaml`。替换三个 `REPLACE_*_ID_SERIAL`，整串抄录且省略 `ID_SERIAL=` 前缀。用临时 Xubuntu 的 `openssl passwd -6` 交互生成密码哈希，将输出填入 `identity.password`。保存为无 BOM 的 UTF-8 文本，在 Windows 显示文件扩展名并确认文件名是 `autoinstall.yaml`。实填文件含密码哈希，保留在私有副本中。

`CIDATA` 是 cloud-init 通过卷标自动寻找 NoCloud 配置时用的名字。此处由桌面安装器显式读取 YAML，Ventoy 的大分区可以保留原卷标和文件系统，现有 ISO 与 Memtest 工具继续从原菜单启动。 [Ventoy 的分区布局](https://www.ventoy.net/en/doc_disk_layout.html) · [NoCloud 卷标](https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html#source-2-drive-with-labeled-filesystem)

### 挂载 Ventoy 与保存 Live 日志

Ventoy 1.1.18 起可在由它启动的 Linux Live 里重挂载 ISO 所在的数据分区。T1 进入 Live 就试读一次。先在 Thunar 侧栏点 Ventoy 大数据卷，确认能看到 ISO 和仓库副本。若侧栏无法打开，挂载 Ventoy 提供的 `/dev/mapper/VentoyPart`。

```bash
sudo udevadm trigger
sudo udevadm settle
findmnt -S /dev/mapper/VentoyPart -o SOURCE,TARGET,OPTIONS
# 只有上条无输出且 /dev/mapper/VentoyPart 存在时，才手动挂载。
sudo mkdir -p /mnt/ventoy
sudo mount -o rw /dev/mapper/VentoyPart /mnt/ventoy
```

如果 Thunar 已挂载，把下面 `ventoy` 的值改成 `findmnt` 显示的 `TARGET`。退出 Live 前保存这轮日志。挂载点应显示 `rw`；试读失败时先按 Ventoy 官方 remount 步骤查 mapper，I1 可从另一只可读 U 盘取 YAML。

```bash
ventoy=/mnt/ventoy
if findmnt -rn -M "$ventoy" -O rw >/dev/null; then
    sudo mkdir -p "$ventoy/z8/live-logs" &&
        sudo cp -n -- "$HOME"/z8-burnin/steps/*.log "$ventoy/z8/live-logs/" && sync
fi
```

[Ventoy 1.1.18 的 Linux remount 说明](https://www.ventoy.net/en/doc_linux_remount.html)

### I1.3 在桌面安装器导入并确认写盘

1. 进 **Try Xubuntu**，用 [有线优先的 Live 联网步骤](BURN-IN.md#首次-live-联网与临时验机系统)确认有线或 AX210 过渡联网。打开终端，更新 APT 列表并给当前 Live 会话补上 `mdadm`。安装器需要它创建 RAID0，目标系统也需要通过 APT 安装它以便下次开机组阵。样例选择标准 `xubuntu-desktop` 源，APT 找不到可用镜像时中止。 [镜像软件包清单](https://cdimage.ubuntu.com/xubuntu/releases/26.04.1/release/xubuntu-26.04.1-desktop-amd64.manifest) · [Curtin 的存储依赖](https://github.com/canonical/curtin/blob/main/curtin/block/deps.py) · [安装源和 APT 配置](https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html#source)

   ```bash
   sudo apt update && sudo apt install mdadm
   command -v mdadm && command -v mkfs.xfs
   lsblk -o NAME,PATH,SIZE,MODEL,FSTYPE,LABEL,MOUNTPOINTS
   ```

2. 按[挂载步骤](#挂载-ventoy-与保存-live-日志)打开 Ventoy 大数据分区。用实际 `TARGET` 设置 `ventoy`，再把 YAML 复制到 Live 用户的家目录。

   ```bash
   ventoy=/mnt/ventoy
   install -m 0600 "$ventoy/z8/autoinstall.yaml" "$HOME/autoinstall.yaml"
   ```

3. 在桌面打开 **Install Xubuntu 26.04.1 LTS**。选择 **Type of installation → Automated with autoinstall file → Select file…**，选家目录里的 `autoinstall.yaml`，点 **Import**。安装器会把文件写入 Live 环境的 `/autoinstall.yaml` 并重启后端。样例的 `early-commands` 会在写盘前等待，导入页可能暂时一直转圈。此时 `Alt+Tab` 回到 Live 终端。 [桌面导入源码](https://github.com/canonical/ubuntu-desktop-provision/blob/ubuntu/26.04/apps/ubuntu_bootstrap/lib/services/autoinstall_service.dart) · [Subiquity 的 early-commands](https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html#early-commands)

4. 再次按 T4 记录定位三个整盘 by-id，填入下列命令。脚本用 `cmp` 核对导入文件，只打印 `storage` 段和设备序列号。退出 Live 前可把该日志复制到 Ventoy 大数据分区。

   ```bash
   bash host/run-step.sh i1-disks /dev/disk/by-id/usb-REPLACE_FIT \
       /dev/disk/by-id/nvme-REPLACE_P4618_A /dev/disk/by-id/nvme-REPLACE_P4618_B --imported
   ```

5. 看到 `Imported YAML matches`，三个 `ID_SERIAL` 与 T4 一致，根卷用两个 P4618 端点且 FIT 有 EFI、`/boot`、`Z8TOOLS`、`Z8RECOVERY` 四分区，才运行 `sudo touch /run/z8-storage-confirmed`。回到图形界面，在 **Ready to install** 再确认后点 **Install**。这会重建 FIT 和两个 P4618 端点的分区表。若导入报错或身份不一致，停在这一步检查。需要重新导入时先重启到新的 Live 会话，再从 I1.3 开始。这样会重新运行 early-commands 等待点。 [按序列号匹配磁盘](https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html#disk-selection-extensions) · [桌面安装器的最终确认](https://ubuntu.com/desktop/docs/en/latest/tutorial/install-ubuntu-desktop/#ready-to-install)

6. 安装配置设了 `shutdown: poweroff`。安装器完成并关机后拔下 **Ventoy**，FIT 留在原 USB 口。再开机进入装好的 Xubuntu Desktop。必要时从 F9 选择指向 FIT 的 UEFI 引导项。核当前有线连接。无线过渡时从 Xfce 网络图标重连，再执行 I1.4。

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
sudo mdadm --detail "$(findmnt -n -o SOURCE /)"
cat /proc/mdstat
hostnamectl --static
id jackywang
sudo xfs_info /
```

首启应看到主机名 `jackywang-xubuntu-max`、用户 `jackywang`，md 阵列为两个成员、RAID0、512 KiB chunk，根卷为 `reflink=1,sunit=128,swidth=256`（4 KiB XFS 块）。 [Ubuntu 26.04 mkfs.xfs](https://manpages.ubuntu.com/manpages/resolute/man8/mkfs.xfs.8.html)

### 首启后定稿挂载参数

按 [全机挂载表](MOUNTS.md) 和 [fstab 样例](fstab-boot.example) 修改安装器写好的三行。保留实际文件系统 UUID 及其他行，完成 `findmnt --verify` 后更新 initramfs 和 GRUB。另在 `/etc/mdadm/mdadm.conf` 核对目标阵列 UUID，避免重复写入 ARRAY 项。将 `mdraid` 模块和 `nvme`、`raid0`、`xfs` 驱动写入 Dracut 的持久配置，供本次和以后构建 initramfs 使用。 [Dracut 26.04 配置手册](https://manpages.ubuntu.com/manpages/resolute/man5/dracut.conf.5.html)

```bash
sudo install -d /etc/dracut.conf.d
printf '%s\n' 'add_dracutmodules+=" mdraid "' 'force_drivers+=" nvme raid0 xfs "' | \
    sudo tee /etc/dracut.conf.d/51-z8-root.conf
abi=$(uname -r)
backup="/boot/z8-initrd-$abi.pre-dracut"
if sudo test -s "$backup" || sudo cp -a -- "/boot/initrd.img-$abi" "$backup"; then
    sudo dracut --force "/boot/initrd.img-$abi" "$abi" && sudo update-grub
fi
sudo lsinitrd -m "/boot/initrd.img-$abi" | grep -w mdraid
sudo lsinitrd "/boot/initrd.img-$abi" | grep -E '(^|/)(mdadm|raid0\.ko|xfs\.ko|nvme\.ko)'
```

正常完成本节设置后可执行 `bash host/run-step.sh i1-boot`，一次保存当前 UEFI、FIT 分区、md 阵列、XFS 和当前 initramfs 的模块列表。第一次验证后再关机冷启一次，确认固件仍选中 FIT、三个常驻挂载点一致、两个 md 成员齐全。随后按 [FIT 救援手册](FIT-RECOVERY.md#i1-备好本机救援入口)装 Memtest86+、复制工具和 ISO、加入 GRUB 菜单，完成首份备份和外部副本。若首次引导即失败，从 Ventoy 启动 Xubuntu Live 做下方组装检查。FIT 救援菜单布置后也从 FIT 启动 Live 做一次同样的只读演练。

留存 RAID、GPT、EFI、fstab、`mdadm.conf`、驱动和软件包清单。首启失败时从 Ventoy UEFI 启动同一份 Xubuntu Desktop ISO 并选择 Try Xubuntu。FIT 救援菜单配置完成后，可在 FIT 的 GRUB 菜单进入 Live 并执行同样的只读检查。根据安装记录核对两个 P4618 成员与 FIT 的现有 UUID。确认目标 md 未自动组装时，才用明确列出的两个成员只读组装。若 Live 缺少工具，按 [从 Live 离线装 mdadm](FIT-RECOVERY.md#从-live-离线装-mdadm)处理。`xfsprogs` 可从工具盘 `debs/` 补上。核对 `mdadm --detail` 后只读挂载根卷。已自动组装时复用该 md 设备。若更新后 initrd 损坏，按本页维修挂载方式先独立挂上 FIT 的 `/boot`，将 `z8-initrd-<ABI>.pre-dracut` 复制回对应的 `initrd.img-<ABI>`。以下占位符来自 I1 实测记录，不能照抄设备名。

```bash
lsblk -f
cat /proc/mdstat
# 仅当目标阵列未自动组装时运行，替换两个成员分区的 by-id。
A=/dev/disk/by-id/nvme-REPLACE_P4618_A-part1
B=/dev/disk/by-id/nvme-REPLACE_P4618_B-part1
sudo mdadm --assemble --readonly /dev/md/z8root "$A" "$B"
```

```bash
# 已自动组装时把下面路径改为 /proc/mdstat 中的实际设备。
ROOT_MD=/dev/md/z8root
sudo mdadm --detail "$ROOT_MD"
sudo install -d /mnt/z8root
sudo mount -t xfs -o ro,norecovery "$ROOT_MD" /mnt/z8root
findmnt -M /mnt/z8root
sudo cat /mnt/z8root/etc/hostname
sudo umount /mnt/z8root
```

读到 `jackywang-xubuntu-max` 后结束演练，回 FIT 启动。 [Ubuntu 26.04 mdadm](https://manpages.ubuntu.com/manpages/resolute/man8/mdadm.8.html) · [XFS 的 norecovery](https://manpages.ubuntu.com/manpages/resolute/man5/xfs.5.html#norecovery)

实际维修时，按根、`/boot`、ESP 的顺序挂载，再 bind-mount `/dev`、`/proc`、`/sys`、`/run` 并 chroot 检查；只有实际引导文件损坏时才重装引导。阵列成员失效按根备份重建。

用本机控制台确认板载有线已连接；无线过渡时用 AX210。安装基础组件，然后按 [远程入口](../remote/README.md) 做 I2。先从另一台机器验 SSH 与 xrdp，之后才动显卡驱动。

```bash
sudo apt update
sudo apt install mdadm xfsprogs nvme-cli numactl pciutils dmidecode \
    smartmontools mokutil efibootmgr openssh-server tmux intel-microcode \
    linux-firmware-intel-wireless git curl e2fsprogs
```

### 目录和实际存储

`/srv` 是标准的本机服务数据目录，系统镜像通常已提供空目录。我们决定其中每个子目录的用途，并手动建目录或挂载点。本机的 `/srv` 默认属于 P4618 的根 XFS。创建命令可以补齐缺失的父目录。 [Filesystem Hierarchy Standard 的 /srv](https://specifications.freedesktop.org/fhs/latest/srv.html)

```bash
sudo install -d -m 0755 /srv/work /srv/buildbarn
sudo install -d -m 0700 -o jackywang -g "$(id -gn jackywang)" /srv/work/jackywang
findmnt -T /srv/work/jackywang -o SOURCE,TARGET,FSTYPE
findmnt -T /srv/buildbarn -o SOURCE,TARGET,FSTYPE
```

两个查询应显示 P4618 的 md 根卷、挂载点 `/` 和 `xfs`。I4 创建 `/srv/buildbarn/tiered`，I5 配置容器目录权限。I4 用 `sudo install -d -m 0755 /srv/pmem-model` 创建空的挂载点，随后挂载 PMem XFS DAX。只有 `findmnt -rn -M /srv/pmem-model -t xfs -O dax=always` 成功才下载模型或建 KV 文件目录。卸载后该路径再次指向 P4618 上的空目录。XFS reflink 的本地检查见 [Buck2 与工作树](../buildbarn/README.md#git-worktree-与-xfs-reflink)。

## 安装并锁定 NVIDIA 显卡驱动

T5 在临时系统执行本节的 APT 和重启核验，完成后回拷机手册接坞。I3 在正式系统重新执行本节，再做下面的 Sunshine 和复接验证。两次开始时都只有槽 4 的 P620。**R580 是 NVIDIA Linux 显卡驱动的 580.x 分支**，也是 NVIDIA 最后一条同时支持 V100（Volta）和 P620（Pascal）的驱动分支。这台机安装 Ubuntu 的专有驱动包 `nvidia-driver-580`，并接受该分支的补丁更新。2026 年 11 月 13 日核对的 APT 组合为 `580.178.04-0ubuntu0.26.04.1` 和 `linux-modules-nvidia-580-generic 7.0.0-43.43`。第三方 CUDA 构建留在独立用户空间，目标 `sm_70` 用 CUDA 12.x。 [NVIDIA 驱动支持矩阵](https://docs.nvidia.com/datacenter/tesla/drivers/cuda-toolkit-driver-and-architecture-matrix.html) · [580.x 支持的 GPU](https://download.nvidia.com/XFree86/Linux-x86_64/580.159.03/README/supportedchips.html) · [Ubuntu 驱动包](https://packages.ubuntu.com/resolute-updates/nvidia-driver-580) · [Ubuntu 驱动安装](https://ubuntu.com/server/docs/how-to/graphics/install-nvidia-drivers/)

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
# 重启后在当前测试系统或正式系统执行。
uname -r
modinfo -F version nvidia
modinfo -F license nvidia
nvidia-smi -L
nvidia-smi --query-gpu=name,pci.bus_id,driver_version --format=csv
sudo journalctl -k -b -g 'NVRM|Xid'
```

在 T5 核 P620 与 R580 后，返回 [算力坞测试](BURN-IN.md#t5-算力坞-v100-与-pcie-拷机)。下文用于 I3 正式系统。确认 P620 正常、R580 已加载、SSH 仍能登录，按 [远程手册](../remote/README.md#sunshine) 验 Sunshine/NVENC。关机断电后接回通过 T5 的四张 V100。再开机，复查四张 V100 的 UUID、拓扑与[快速 CUDA/NCCL](#算力坞验收)，并在 Moonlight 串流时再核一次捕获的显示接口和 P620 的编码会话，然后进入 I4。今后更新内核或驱动前先模拟升级，保留上一版已知可启动的内核，并在重启后查 NVIDIA、ZFS 与 dm-zoned。

## 固定 GA 轨道并试启新内核

验机和正式系统分别记录实际 ABI。临时 Xubuntu 在 T1 安装微码和当前 GA 更新后记录 `uname -r`，后续测试一直从该项启动。正式安装的 ISO、APT 和 R580 预编译模块若带来不同 ABI，在 I3 复跑 CUDA/NCCL，在 I4 复验 ZFS 与 dm-zoned。冻结从各自跑通所需组件后开始，等 I7 通过解除正式系统的 hold。临时系统的 hold 无法跨到新装系统。 [Ubuntu 内核轨道](https://documentation.ubuntu.com/kernel/reference/hwe-kernels/) · [Ubuntu 自动安全更新](https://documentation.ubuntu.com/security/security-updates/#automatic-security-updates)

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
    "linux-main-modules-zfs-$old_abi" "linux-modules-nvidia-580-$old_abi"
# 把上面确实已安装的四项标为 manual，防止自动清理回退 ABI。
sudo apt-mark manual "linux-image-$old_abi" "linux-modules-$old_abi" \
    "linux-main-modules-zfs-$old_abi" "linux-modules-nvidia-580-$old_abi"
```

先重启一次确认已保存的旧内核能从 FIT 启动，核 `uname -r` 和 SSH。确认后先刷新这次手工修改的基线，再模拟升级。

```bash
sudo z8-recovery-backup --refresh-boot
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

新内核起来后，核 `uname -r`、`grub-editenv list` 中 `next_entry` 已消费，并从客户端验证 SSH。再查 `nvidia-smi -L`、`zpool status -x z8data`、`sudo dmsetup status --target zoned` 的七个成员、模型卷的实际挂载点、`sudo daxctl list` 两路 online 和 `sudo journalctl -k -b -p err`。成功才 `sudo grub-set-default "$new_entry"`，执行 `sudo z8-recovery-backup`，再[取一份机器外备份](FIT-RECOVERY.md#每个阶段留一份到另一台机器)。APT 正常改动启动文件时由 [FIT 钩子](FIT-RECOVERY.md#apt-改动启动文件时自动更新基线)更新校验基线。手工改动引导文件时，验过后用 `sudo z8-recovery-backup --refresh-boot`。若试启失联，机旁优先用控制台重启或从 GRUB 选择旧项。先在本机验证一次性项确实被消费，才依赖下一次重启回旧项。

## 算力坞验收

T5 从 SanDisk 临时系统构建下列工具，产物留在 `~/z8-burnin/cuda-check`。CUDA 12.9.1 容器只负责编译，测试在装好 R580 的 Xubuntu 宿主执行。从 `z8-kit` 根运行，先用 `df -h / /var/lib` 检查 SanDisk 系统及 Docker 的剩余空间。 [NVIDIA CUDA 12.9.1 构建镜像](https://hub.docker.com/layers/nvidia/cuda/12.9.1-devel-ubuntu24.04/images/sha256-933d999bafbc7afa344e0e600fec13a6c3c0a191225fcd65db22185679b1476f) · [CUDA Samples v12.9 构建](https://github.com/NVIDIA/cuda-samples/blob/v12.9/Samples/5_Domain_Specific/p2pBandwidthLatencyTest/CMakeLists.txt) · [GPU Burn 构建](https://github.com/wilicc/gpu-burn/blob/master/Makefile) · [NCCL 测试构建](https://github.com/NVIDIA/nccl-tests/tree/v2.17.7#build)

```bash
bash host/run-step.sh t5-cuda-build
```

脚本安装 Docker、在同一 CUDA 镜像构建 P2P、NCCL、GPU Burn 和 pinned-copy，保存实际源码提交、可执行文件和用户态共享库。

I3 在正式系统复测时，按[只读挂载 SanDisk 的方法](PMEM.md#i4-在正式系统复用-pmem)挂到 `/mnt/z8-burnin-usb`，再运行下面的命令。若临时系统用了其他用户名，把 `src` 路径里的 `jackywang` 换掉。复制成功后卸载并拔下 SanDisk。I3 快速复测通过后，将 `cuda-check/` 再写一份到 [FIT 工具盘](FIT-RECOVERY.md#离线工具和-i3-cuda-工具)。

```bash
src=/mnt/z8-burnin-usb/home/jackywang/z8-burnin/cuda-check
mkdir -p "$HOME/z8-burnin"
sudo test -x "$src/all_reduce_perf" &&
    sudo cp -R -- "$src" "$HOME/z8-burnin/" &&
    sudo chown -R "$(id -u):$(id -g)" "$HOME/z8-burnin/cuda-check" &&
    sudo umount /mnt/z8-burnin-usb
```

T5 和 I3 都在宿主从 `z8-kit` 根执行以下命令。日志里的 `ldd` 应没有 `not found`，`libcuda.so.1` 应来自宿主的 R580。用正式启动默认的内核参数测试，再填四张 V100 的实际 UUID。`intel_iommu=off` 只用于 [PCIe 路径排查](BIOS.md#接坞后的-pcie-p2p)。T5 首轮 GPU Burn 和 [pinned DMA](PMEM.md#四卡-pinned-dma-验收)也用这个目录的产物。

```bash
bash host/run-step.sh i3-cuda GPU-REPLACE0,GPU-REPLACE1,GPU-REPLACE2,GPU-REPLACE3
```

脚本记录 NVLink 能力矩阵、链路状态和动态库来源，运行 P2P 带宽测试、四卡和六个两卡组合的 NCCL all-reduce 校验。四卡全互联的验收要求六对均显示 NVLink 可用且六对校验错误数为 0。某对无 NVLink 时保存实际拓扑，推理保持 `Z8_NVLINK_P2P=0`。

记录每对 P2P 可达性与带宽、all-reduce 错误数和带宽。分别测试两张同 socket 卡与跨 socket 卡。用 CUDA H→D/D→H 负载运行时从另一终端执行 `nvidia-smi --query-gpu=uuid,pci.bus_id,pcie.link.gen.current,pcie.link.width.current --format=csv`，确认实际 Gen3 x8。加载四卡与 CPU 后检查 `journalctl -k -b` 的新增 Xid、AER、ECC；保留日志和各卡温度、功耗。 [NVIDIA CUDA 样例](https://github.com/NVIDIA/cuda-samples) · [NVIDIA nccl-tests](https://github.com/NVIDIA/nccl-tests)
