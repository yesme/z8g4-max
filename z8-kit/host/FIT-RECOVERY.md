# Samsung FIT 救援和元信息备份

FIT 的 p1 FAT32 1 GiB 与 p2 ext4 8 GiB 分别挂 `/boot/efi`、`/boot`。p3 是 **24 GiB ext4 `Z8TOOLS`**，p4 是 **8 GiB ext4 `Z8RECOVERY`**，两者按需挂载。剩余约 78 GiB 留空。从 FIT 启动的 Live 可修系统。要用首装 YAML 重建 FIT 或 P4618，先从独立的三星 T3（Ventoy）启动。

## I1 备好本机救援入口

从装好的 Xubuntu 首启。确认 FIT 的 p1、p2 确实承载 EFI 和 `/boot`，p3、p4 在同一整盘上并带正确卷标。新盘由 I1 的 YAML 创建这两个分区。已有仅两分区的 FIT 要先从 Ventoy 启动，在未分配空间创建 p3、p4，保留 p1、p2。先留一份外部备份，再动分区表。

```bash
findmnt -M /boot -o SOURCE,TARGET,FSTYPE
findmnt -M /boot/efi -o SOURCE,TARGET,FSTYPE
lsblk -o NAME,PKNAME,MODEL,SERIAL,SIZE,FSTYPE,LABEL,MOUNTPOINTS
sudo apt install memtest86+ gdisk
sudo install -d -m 0755 /etc/z8-storage
```

将验证过 SHA-256 的 **同一份** `xubuntu-26.04.1-desktop-amd64.iso` 从 Ventoy 拷到 `Z8TOOLS`。这里是在正式系统里，Thunar 挂载的 Ventoy 路径用 `findmnt` 或文件管理器的位置栏照抄。`kit` 是当前仓库 `z8-kit` 的实际目录。以下在该目录运行，ISO 子目录按 Ventoy 上实际存放位置改。`autoinstall.yaml` 保存 I1 核实的磁盘序列号和获准留在 FIT 的登录密码散列。只复制按仓库模板生成的配置。

```bash
(
    set -euo pipefail
    ventoy=/media/jackywang/REPLACE_VENTOY_LABEL
    iso="$ventoy/REPLACE_ISO_DIRECTORY/xubuntu-26.04.1-desktop-amd64.iso"
    tools=/mnt/z8-tools
    test -f "$iso" && test -f "$ventoy/z8/autoinstall.yaml"
    sudo install -d "$tools"
    sudo mount -t ext4 -o noatime LABEL=Z8TOOLS "$tools"
    trap 'sudo umount "$tools"' EXIT
    sudo install -d "$tools"/{iso,debs,z8g4-max}
    sudo cp -- "$iso" "$tools/iso/"
    printf '%s  %s\n' \
        0cd5160f72ae6b7a26be7a29248b60cbd579b9e6aa8fbd274e95264da0ade43d \
        "$tools/iso/${iso##*/}" | sudo sha256sum --check --strict -
    sudo install -m 0600 "$ventoy/z8/autoinstall.yaml" "$tools/autoinstall.yaml"
    git -C .. archive HEAD | sudo tar -xf - -C "$tools/z8g4-max"
    sudo sync -f "$tools"
)
```

脚本使用 [发布镜像的 SHA256SUMS](https://cdimage.ubuntu.com/xubuntu/releases/26.04.1/release/SHA256SUMS) 核对 FIT 上副本。仓库副本用 `git archive` 只复制选定提交的版本控制内容。API 密钥、SSH 私钥、已登录的 CLI 配置和 Wi-Fi 密码留在原有管理位置。放在 FIT 的安装文件只含 Ubuntu `identity.password` 的散列，其他凭证字段留空。

从 `z8-kit` 根安装 GRUB 菜单片段。`42_z8_recovery` 与 GRUB 的 `40_custom` 同用一个生成机制，保留已有自定义项。这里设置 5 秒菜单，普通启动继续选择当前系统。

```bash
(
    set -euo pipefail
    printf '%s\n' GRUB_TIMEOUT_STYLE=menu GRUB_TIMEOUT=5 |
        sudo tee /etc/default/grub.d/54-z8-fit-menu.cfg >/dev/null
    { printf '%s\n' '#!/bin/sh' 'exec tail -n +3 "$0"'; cat host/grub-fit-recovery.cfg.example; } |
        sudo tee /etc/grub.d/42_z8_recovery >/dev/null
    sudo chmod 0755 /etc/grub.d/42_z8_recovery
    sudo update-grub
    sudo grub-script-check /boot/grub/grub.cfg
    sudo grep -Ei 'menuentry.*(memtest|z8-fit-live)' /boot/grub/grub.cfg
)
```

拔掉 Ventoy，从 FIT 分别进入一次 Memtest86+ 和 **Z8 recovery**。Live 中 `findmnt /cdrom` 应显示 loop 设备。用 `sudo losetup --list --output NAME,BACK-FILE` 找到该 ISO 的后端文件，再用 `lsblk -o NAME,FSTYPE,LABEL,MOUNTPOINTS` 核对其所在分区为 `Z8TOOLS`。测试完正常重启，回正式系统。

## 离线工具和 I3 CUDA 工具

在同版 Xubuntu Live 联网准备离线工具包。以下命令只下载。把 `archives/` 中的 `.deb` 以及 [PMem 手册的三份 ipmctl 包](PMEM.md#t3-准备工具)存入 `Z8TOOLS/debs/`。在 Live 启动后检查与运行 ABI 匹配的 `linux-tools-$(uname -r)` 已收齐。

```bash
downloads=$(mktemp -d)
mkdir -p "$downloads/archives/partial"
sudo apt update
sudo apt-get -o Dir::Cache::archives="$downloads/archives" --download-only --no-install-recommends install \
    dm-zoned-tools ndctl daxctl nvme-cli smartmontools gdisk xfsprogs \
    stress-ng stressapptest fio rasdaemon lm-sensors numactl linux-tools-common \
    "linux-tools-$(uname -r)"
ls -lh "$downloads/archives"/*.deb
```

可先存到 Ventoy 的 `z8/`，回正式系统后按上一段临时挂载 `Z8TOOLS`，把这些 `.deb` 复制到 `debs/`。需要离线安装时，将目标包及其未预装的依赖 `.deb` 一起交给 `sudo dpkg --install`。用同版 Live 准备可以省去 Live 已安装的依赖。应在断网 Live 用这组包试一次再移除临时源文件。

I3 从 SanDisk 取得并复验 CUDA 工具后，临时挂载 `Z8TOOLS`，执行 `sudo cp -a "$HOME/z8-burnin/cuda-check" /mnt/z8-tools/` 后 `sudo sync -f /mnt/z8-tools` 并卸载。重装时可从 FIT 取回同目录，再由已安装 R580 的正式系统运行。

I5 构建调度器并通过 RE 后，可按上面的办法临时挂载 `Z8TOOLS`，将兼容镜像保存下来。重装用 `sudo docker load -i /mnt/z8-tools/z8-bb-scheduler.tar` 恢复该标签。

```bash
sudo docker image save -o /mnt/z8-tools/z8-bb-scheduler.tar z8/bb-scheduler:c9ba98c-command-platform
sudo sync -f /mnt/z8-tools
sudo umount /mnt/z8-tools
```

## 开启元信息备份

I1 完成并验过本机 GRUB 后，用 `sudoedit /etc/z8-storage/recovery-notes.txt` 保存 F10 设置、DIMM 插槽和 D4800X 转接与改装记录。接着执行以下命令，创建第一份备份并建立 boot 校验基线。每周一 03:30 复核，由 `Persistent=true` 补执行关机时错过的任务。日志在系统 journal。

```bash
(
    set -e
    sudo install -m 0755 host/z8-recovery-backup.sh /usr/local/sbin/z8-recovery-backup
    sudo install -m 0755 host/inventory.sh /usr/local/sbin/z8-inventory
    sudo install -m 0644 host/systemd/z8-recovery-backup.{service,timer} /etc/systemd/system/
    sudo install -m 0644 host/99z8-fit-boot.example /etc/apt/apt.conf.d/99z8-fit-boot
    sudo systemctl daemon-reload
    sudo z8-recovery-backup --refresh-boot
    sudo systemctl enable --now z8-recovery-backup.timer
    systemctl list-timers z8-recovery-backup.timer
    apt-config dump | grep -F '/usr/local/sbin/z8-recovery-backup --apt-'
)
```

模型上线后把 GGUF 的 revision 和校验值放 `/etc/z8-storage/model-manifest.txt`。I4、I5、I7 和每次改存储配置后，运行 `sudo z8-recovery-backup`。手工运行 `dracut`、`update-grub` 或修改引导文件后，验证可启动再用 `sudo z8-recovery-backup --refresh-boot` 认可新的基线。I4 的快照保存 D4800X 整盘 GPT、`/etc/z8-storage/cold-layout.json`、`hybrid.tsv` 和 `storage.env`，并采集已在线的 dm 表。冷库内容、裸索引和 checkpoint 属于可重建缓存。缺席时记录 D4800X 状态，其他元信息继续备份。

脚本按同盘和卷标核验 `Z8RECOVERY`，每次临时挂载。备份记录写入独立目录、读回验 SHA-256，再原子更新 `latest`，保留最新 12 份。周检对比 EFI 和 `/boot` 的普通文件清单，排除 GRUB 自行改写的 `grubenv`。差异、缺基线或读取失败时，脚本仍保存元信息和 `boot-check.txt`，能取得原基线时也保存 `boot-baseline.sha256`。快照校验并卸载后才以非零退出，原基线仍可供排查。查看 `journalctl -u z8-recovery-backup.service -b` 和快照记录。

### APT 改动启动文件时自动更新基线

`99z8-fit-boot` 在 APT 调用 dpkg 前后分别计算两个挂载点内的文件散列。两份清单有变化、升级前通过原基线、APT history 有完整且无错误的包事务时，才更新 `Z8RECOVERY` 上的基线。核查 `journalctl -t z8-fit-apt`，包含 UTC 时间、事务包名与版本、旧新清单的 SHA-256。最近一笔自动更新也留在 `boot-baseline-apt.txt`，纳入后续快照。钩子保留 APT 本身的退出状态，FIT 检查失败会单独记录。直接运行 `dpkg` 以及手工改启动文件时，按上一节人工验证及更新基线。 [Ubuntu 26.04 APT 调用 dpkg 的钩子](https://manpages.ubuntu.com/manpages/resolute/man5/apt.conf.5.html)

Ubuntu 26.04 的 Dracut 提供 `update-initramfs`，内核安装和移除会经 kernel hooks 生成或移除 initramfs 并更新 GRUB。即使内核、NVIDIA 和 ZFS 留给手动维护，自动升级 Dracut、mdadm、Intel 微码或 Plymouth 仍可通过 `update-initramfs` 或 dpkg 触发器重建 initramfs。更新已安装的 GRUB EFI 或 shim 在其维护脚本条件满足时可改写 ESP。Memtest86+ 会更新 `/boot` 下的测试程序，并在已配置 GRUB 时更新菜单。当前的 APT 钩子按内容变化决定是否刷新，涵盖 unattended-upgrades 的 APT 事务。 [Ubuntu 26.04 Dracut 变更](https://github.com/ubuntu/ubuntu-release-notes/blob/main/docs/26.04/summary-for-lts-users.md) · [Dracut Ubuntu 源包](https://launchpad.net/ubuntu/+source/dracut/110-11ubuntu0.1) · [unattended-upgrades 的 APT 提交路径](https://github.com/mvo5/unattended-upgrades/blob/master/unattended-upgrade)

### 每个阶段留一份到另一台机器

I1 还未启用 SSH 时，先在正式系统中生成归档，写到已挂载 Ventoy 的 `z8/` 目录。用下一段导出命令，先把目录名改成实际挂载路径。将 Ventoy 拔下，在另一台机器保存这份归档。I2 配好 SSH 后可从客户端取回。

```bash
(
    set -euo pipefail
    umask 077
    ventoy=/media/jackywang/REPLACE_VENTOY_LABEL
    mountpoint -q "$ventoy"
    mkdir -p "$ventoy/z8"
    archive="$ventoy/z8/z8-recovery-$(date +%Y%m%d-%H%M%S).tar"
    sudo /usr/local/sbin/z8-recovery-backup --stdout > "$archive.part"
    tar -tf "$archive.part" >/dev/null
    mv -- "$archive.part" "$archive"
    sync -f "$ventoy"
)
```

I2 配好 SSH 后，在 `jackywang-xubuntu-max` 上用 `sudo visudo -f /etc/sudoers.d/z8-recovery-export` 安装这一条。该规则只授予 `jackywang` 无密码执行带精确参数 `--stdout` 的命令。文件由 root 持有，权限为 `0440`。保存后执行 `sudo visudo -c` 校验规则。

```sudoers
jackywang ALL=(root) NOPASSWD: /usr/local/sbin/z8-recovery-backup --stdout
```

从配置了 `z8` SSH 别名的客户端流式取走。FIT 的 `/boot` 或 ESP 不可用时仍会导出其余元数据，归档的 `boot-check.txt` 会记 `unavailable` 或 `unreadable`，没有完整的启动文件清单。推理用户的 launcher 和环境以 `jackywang` 的权限读取。还没装 sudoers 规则时，用普通 SSH 会话在主机上运行 `sudo z8-recovery-backup --stdout` 并重定向到 `~/z8-recovery.tar`，再从另一台机器用 `scp z8:z8-recovery.tar .` 复制。备份文件和散列清单按机器外的备份规则保管。

```bash
umask 077
archive="z8-recovery-$(date +%Y%m%d-%H%M%S).tar"
ssh -T z8 sudo -n /usr/local/sbin/z8-recovery-backup --stdout > "$archive.part" &&
    tar -tf "$archive.part" >/dev/null && mv -- "$archive.part" "$archive"
```

备份只包含重建资料。从 p4 恢复时在 Live 临时只读挂载 `Z8RECOVERY`，进 `latest` 运行 `sha256sum --check --strict SHA256SUMS`，再使用对应的 GPT、mdadm、ZFS GUID 和配置。恢复 /etc 和 systemd 配置时逐文件对照新硬件的序列号和 UUID。FIT 整盘失效时用 Ventoy 启动并从机器外备份取回资料。

## 从 Live 离线装 mdadm

安装镜像挂在 `/cdrom` 后，直接用 `dpkg` 安装自带的 amd64 包。Xubuntu 26.04.1 Desktop Live 已包含它的依赖。该镜像中，用 `apt-get --no-download` 安装这份本地包会报 `Pathname to install is not absolute`。 [官方镜像文件清单](https://cdimage.ubuntu.com/xubuntu/releases/26.04.1/release/xubuntu-26.04.1-desktop-amd64.list)

```bash
sudo dpkg --install /cdrom/pool/main/m/mdadm/mdadm_4.5-5ubuntu1_amd64.deb
mdadm --version
dpkg-query -W mdadm
```

Live 的安装日志可能出现 `/cow` 的 `grub-probe` 提示。无网卡 QEMU 中这条命令以退出码 0 完成，`mdadm --version` 显示 4.5，`dpkg-query` 显示 `4.5-5ubuntu1`。

接着按 [I1 的只读根盘救援](INSTALL.md#i14-核验-fit-引导并做救援验证)操作。P4618 一半损坏时 RAID0 根需重建。保留 FIT 和数据池备份，用 Ventoy 启动并核新端点序列号后再走重装。重建 FIT 前应已从机器外取回备份，重装完成后重新布置工具盘和备份基线。
