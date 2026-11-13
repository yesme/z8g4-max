# 文件系统挂载与验收

适用于这台 Z8 G4 的 Xubuntu 26.04.1。I1 首启后填写 [fstab 样例](fstab-boot.example)；I4 用套件里的 systemd 服务挂模型卷和两个 ZFS 数据集。

| 挂载点与设备 | 由谁管理 | 首装参数与原因 |
|---|---|---|
| `/`，P4618 双端点 md RAID0/XFS | fstab，文件系统 UUID | `defaults,noatime,nodiscard`。Buck2、Git 和热 CAS 读取时省掉访问时间更新，采用按需或周期性 TRIM。系统与工作目录可执行。`crc=1,reflink=1` 是 mkfs 特性，首启用 `xfs_info /` 核对；XFS log 和分配策略采用默认值。 |
| `/srv/work/z8user`、`buck-out`、`/srv/buildbarn/tiered` | 根 XFS 内的目录 | 与 `/` 同一文件系统，工作树和本地产物在此范围可用 reflink。Buildbarn 容器将热层 bind 到 `/store`。 |
| `/boot`，FIT p2 ext4 | fstab，文件系统 UUID，fsck pass 2 | `defaults,noatime,errors=remount-ro,X-fstrim.notrim`。保留日志，内核升级时可写，省掉 FIT 的读取更新时间和批量 TRIM。 |
| `/boot/efi`，FIT p1 FAT32 | fstab，FAT 卷 UUID，fsck pass 2 | `defaults,noatime,umask=0077,X-fstrim.notrim`。挂载后文件只向 root 开放，GRUB 和 EFI 更新时可写。 |
| `/srv/pmem-model`，两路 App Direct fsdax 的 dm-stripe/ext4 | `z8-pmem-model.service` | `dax=always,noatime,data=ordered,nodiscard`。普通文件走 DAX，避免权重/Engram 热读更新 atime，保留 ext4 日志供 KV 和模型文件更新。2 MiB stripe 与 ext4 stride 在建卷时设定。 |
| `/data`，ZFS `z8data/data` | `data.mount`，`mountpoint=legacy` | mount 选项 `rw`。数据集用 `atime=off,compression=zstd-3,sync=standard,logbias=latency`，`special_small_blocks=24K`。 |
| `/data/buildbarn`，ZFS `z8data/data/buildbarn` | `data-buildbarn.mount`，`mountpoint=legacy` | mount 选项 `rw`。数据集继承 `atime=off,compression=zstd-3,sync=standard,logbias=latency`，本地设 `recordsize=1M,special_small_blocks=0`。容器将它 bind 到 `/cold`。 |
| HC620、P4800X p1–p8、七个 dm-zoned mapper | systemd 存储链与 zpool | 这些是块设备或池成员。只在 ZFS 数据集这一层挂载文件系统。池用 `autotrim=on`。 |
| 两路 PMem devdax 转 system-ram | `z8-pmem-kmem.service` | 作为内核内存节点上线，无文件系统。 |

[Xubuntu 26.04 的 XFS 挂载参数](https://manpages.ubuntu.com/manpages/resolute/man5/xfs.5.html) · [mount 与 FAT 参数](https://manpages.ubuntu.com/manpages/resolute/man8/mount.8.html) · [ext4 参数](https://manpages.ubuntu.com/manpages/resolute/man5/ext4.5.html) · [OpenZFS 2.4 数据集属性](https://openzfs.github.io/openzfs-docs/man/v2.4/7/zfsprops.7.html)

## I1 核对 fstab 和 P4618 的 TRIM

从已安装的系统执行。核对 FS UUID 和实际挂载。用 `sudoedit /etc/fstab` 合并样例中的三行，保持现有设备标识、其他行和根先于 `/boot`、`/boot/efi` 的顺序。完成后按 I1 更新 initramfs/GRUB，重启检查。

```bash
lsblk -o NAME,FSTYPE,UUID,PARTLABEL,MOUNTPOINTS
sudo cp -a /etc/fstab /etc/fstab.pre-z8-mounts
sudoedit /etc/fstab
sudo findmnt --verify --verbose
sudo systemctl daemon-reload
# 以下在重启后检查。
for mountpoint in / /boot /boot/efi; do
    findmnt -n -M "$mountpoint" -o TARGET,SOURCE,FSTYPE,OPTIONS
done
sudo xfs_info /
```

用 `sudo mdadm --detail /dev/md/z8root` 与 `xfs_info /` 核对 XFS 条带几何。按 Live 阶段的 512 KiB md chunk 和 4 KiB XFS block 计算，目标是 `sunit=128`、`swidth=256`，单位为 XFS block；安装器重建阵列后按它的实际 chunk 重算。若 `xfs_info` 显示零，先记录实际的小文件与顺序 I/O 表现，在需要重建空卷时再用正确的 mkfs 几何。阵列和工作树已上线时，保留 XFS 默认分配策略与写回时序。 [Ubuntu 26.04 mkfs.xfs](https://manpages.ubuntu.com/manpages/resolute/man8/mkfs.xfs.8.html)

用 `lsblk -D` 查 P4618 两个成员和 md 根卷的 `DISC-MAX`，以 **md 根卷**实际向上暴露的能力为准。有 discard 支持时，安排一次空闲时的 `sudo fstrim -v /` 并看日志，成功后保持每周 `fstrim.timer`。检查 `systemctl cat fstrim.service` 的 `ExecStart` 是否从 fstab 优先取挂载点，例如 `--listed-in /etc/fstab:/proc/self/mountinfo`，这样两条 FIT 的 `X-fstrim.notrim` 生效。若本机定时任务被改过且会扫描所有卷，可把其 `ExecStart` 覆盖为 `/usr/sbin/fstrim --verbose /`，然后启用 timer。md 根卷未透出 discard 时，保留 `nodiscard` 并以本机探测结果记录。 [Ubuntu 26.04 fstrim 选项](https://manpages.ubuntu.com/manpages/resolute/man8/fstrim.8.html)

```bash
lsblk -D -o NAME,DISC-GRAN,DISC-MAX
systemctl cat fstrim.service
# md 支持 discard，且已确认 fstrim 的目标之后执行。
sudo fstrim -v / && sudo systemctl enable --now fstrim.timer
systemctl list-timers fstrim.timer
```

## I4 核对模型卷和 ZFS

ZFS 在池导入后按 `/data → /data/buildbarn` 挂载，Buildbarn 等子挂载完成才启动。ZFS 的 `compression`、`recordsize`、`sync` 等由 `zfs create/set` 存在 dataset 上，挂载单元只带 `rw`。保留 [原有的设备和启动依赖](../storage/README.md#4-i4-安装存储依赖链)，这两个 ZFS 挂载点和模型卷由各自单元管理。

```bash
for mountpoint in /srv/pmem-model /data /data/buildbarn; do
    findmnt -n -M "$mountpoint" -o TARGET,SOURCE,FSTYPE,OPTIONS
done
findmnt -rn -M /srv/pmem-model -t ext4 -O dax=always,noatime
sudo zfs get -r mountpoint,atime,compression,recordsize,special_small_blocks,sync,logbias z8data/data
sudo zpool get autotrim z8data
```

模型卷的 DAX 还要检查实际文件的 `STATX_ATTR_DAX`，方法见 [PMem 手册](PMEM.md#模型卷)。冷 CAS 的压缩收益按 [存储手册的对照流程](../storage/README.md#冷-cas-压缩怎么定) 测。

冷 CAS 的 `recordsize=1M` 针对大块文件的首装值。小 blob 随机冷读可能要读解同一记录中的其他数据。在真实回放中比较随机冷读 p95 和设备读字节，若明显受读取放大拖累，再用独立冷 CAS 对照 `recordsize=256K`。更改 `recordsize` 后使用新建块文件做对照，已有块文件的记录大小可能保留原值。 [OpenZFS 2.4 recordsize](https://openzfs.github.io/openzfs-docs/man/v2.4/7/zfsprops.7.html#recordsize)
