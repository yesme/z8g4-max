# 远程入口

## SSH

I2 优先用板载 RJ-45。HP QuickSpecs 列板载 Intel I219-LM 和 Intel X722 1GbE，Linux 分别用 `e1000e` 和 `i40e`。HP 的双口 10GbE 模块是选配。有线插通后，在本机控制台记录实际接口、驱动和协商速率。 [HP Z8 G4 网络规格](https://h30434.www3.hp.com/psg/attachments/psg/Business-PC-Workstation-POS/44704/1/Z8%20G4%20Quickspecs%20v67.pdf#page=77) · [NetworkManager 连接属性](https://networkmanager.dev/docs/api/latest/nm-settings-nmcli.html)

```bash
sudo apt install ethtool
nmcli device status
nmcli connection show --active
nic='REPLACE_WITH_ETHERNET_INTERFACE'
profile='REPLACE_WITH_ETHERNET_PROFILE'
sudo ethtool -i "$nic"
sudo ethtool "$nic"
sudo ethtool -P "$nic"
sudo nmcli connection modify "$profile" connection.autoconnect yes connection.permissions '' \
    802-3-ethernet.cloned-mac-address permanent ipv4.route-metric 100 ipv6.route-metric 100
sudo nmcli connection up "$profile"
ip -br address show dev "$nic"
ip route show default
```

用 `ethtool -P` 打印的有线 MAC 在路由器做 DHCP 地址保留。千兆板载口接通时预期 `Speed: 1000Mb/s`、`Duplex: Full`，按实际读数记录。mini 与 Mac 也各自检查实际协商速率。

**没有网线时用 AX210 过渡。** 从 Xfce 面板连 Wi-Fi，再用下面的命令保存系统级连接；做 DHCP 保留时用 AX210 的实际永久 MAC。

```bash
nmcli connection show --active
profile='REPLACE_WITH_WIFI_PROFILE'
sudo nmcli connection modify "$profile" connection.autoconnect yes \
    connection.permissions '' 802-11-wireless.cloned-mac-address permanent \
    ipv4.route-metric 600 ipv6.route-metric 600
sudo nmcli connection up "$profile"
ip -br link
ip -br address
```

如果重启停在登录界面时 Wi-Fi 未连接，在本机打开 Xfce 的连接编辑器。家庭 WPA-PSK/SAE 网络在 `Wi-Fi Security` 中选择为所有用户保存密码，重新连接，再测试一次。这样密码由系统连接配置保存，开机时即可使用。有线连通并在登录界面确认 SSH 可用后，正常关机断电，拆下 AX210 和其蓝牙内部 USB 线，再用有线重验。若 DHCP 地址变了，把客户端 SSH 别名指向新的地址。

用 `hostnamectl --static` 核 `jackywang-xubuntu-max`。执行 `sudo apt install openssh-server tmux`，用 `sudo sshd -t` 校验配置。Ubuntu 26.04 默认 socket 激活，执行 `sudo systemctl enable --now ssh.socket` 并用 `ss -ltn 'sport = :22'` 确认监听。用本机控制台把公钥放入 `jackywang` 的 `~/.ssh/authorized_keys`，以第二条 SSH 连接验证后再关闭密码登录。重启后先停在登录界面，从 Mac 验证当前网络与 SSH 能自行恢复。把 [SSH 样例](ssh_config.example)的 Host 块合并到客户端 `~/.ssh/config`，将各块的 `HostName` 填为保留 IP 或实际可解析的 LAN DNS 名。`ssh jackywang-xubuntu-max` 或 `ssh z8` 都使用登录用户 `jackywang`。RDP 和推理端口按需走 `ssh -NT z8-ports`。Linux 客户端访问编译农场用 `ssh -NT z8-build`，客户端的 18980、18983 分别转到 max 的 8980 和 8983。

## xrdp

`sudo apt install xrdp xorgxrdp dbus-daemon`。以 `jackywang` 复制 [`xsession.example`](xsession.example) 到 `~/.xsession` 并设 0700。合并 `/etc/xrdp/xrdp.ini` 的 `[Globals]` 中 `port=tcp://127.0.0.1:3389`，用 `man xrdp.ini` 核对当前版本语法，保留其余会话定义。用 `sudo systemctl restart xrdp`、`ss -ltnp` 和 `journalctl -u xrdp -u xrdp-sesman` 验证。若日志指出 TLS 私钥不可读，按本机证书权限和包说明配置 `xrdp` 服务用户。通过 tunnel 用 RDP 客户端连 `127.0.0.1:13389`，选择 Xorg、用户 `jackywang`。`xsession.example` 用 `dbus-run-session` 给远程 Xfce 启一条独立的 D-Bus 会话总线。同账户使用 xrdp 时，在 `/etc/xrdp/startwm.sh` 载入系统和用户 profile 的代码之后、执行 `/etc/X11/Xsession` 的分支之前加 `unset DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR`，避免 Xsession 向本机的共享用户总线发布远程 `DISPLAY` 和 `XAUTHORITY`。I2 分别在本机 Xfce 已登录和未登录时测试；I3 串流期间再起一条 RDP 会话，随后重启 Sunshine 并核其捕获源仍是本机 P620。若仍冲突，记录 sesman 和 Xfce 日志；需要同时用两种图形入口时，为 xrdp 建独立图形用户。

xrdp 与 SSH 配置完成后，从 `z8-kit` 根运行 `bash host/run-step.sh i2-remote`，一次打印当前网络、SSH 配置校验、服务状态与本机的 22/3389 监听。随后从另一台机器实际连 SSH 和 RDP。

## Sunshine

I3 用 Sunshine `v2026.914.233613` 的官方 Ubuntu 26.04 amd64 deb。该版带 Linux NVENC API 动态选择和 legacy preset 修复，配合 R580 使用。下载后与 release 的 SHA256 核对，执行 `sudo apt install ./sunshine_2026.914.233613-1+ubuntu26.04_amd64.deb`。若日志仍显示无法打开 NVENC，先用 xrdp 做独立 GUI 登录，并保存 Sunshine 与 P620 编码器日志定位。 [官方发布资产](https://github.com/SunshineStream/Sunshine/releases/expanded_assets/v2026.914.233613) · [R580 NVENC 动态 API 修复](https://github.com/LizardByte/build-deps/pull/776) · [Sunshine 发布说明](https://app.lizardbyte.dev/2026-09-14-v2026.914.233613/)

Sunshine 在 P620 的**本机** Xfce/X11 会话运行，`xsession.example` 供 xrdp 独立桌面使用。将 [`sunshine.conf.example`](sunshine.conf.example) 的设置合并到当前用户的 Sunshine 配置。以 `jackywang` 在本机 Xfce 运行 `systemctl --user enable --now app-dev.lizardbyte.app.Sunshine.service`。按样例只公布 H.264，随后在 Web UI 设置凭证，只允许可信 LAN/VPN 访问所需端口。显示器或虚拟屏接 P620，从 `xrandr` 和 Sunshine 日志找到实际已连接接口，按需填写 `output_name`。下面的命令分别在仅 P620 和接回四张 V100 后执行。NVENC 支持矩阵列出 P620 与 Tesla V100，测试时以实际编码 PID 和 GPU 为准。 [Sunshine 显示与编码配置](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html#output_name) · [NVIDIA NVENC 矩阵](https://developer.nvidia.com/video-encode-decode-support-matrix)

```bash
nvidia-smi --query-gpu=index,name,uuid,pci.bus_id --format=csv
xrandr --query
journalctl --user -b -u app-dev.lizardbyte.app.Sunshine.service --no-pager
# Moonlight 正在串流 1080p60 H.264 时核对 Sunshine 编码会话的 GPU。
nvidia-smi encodersessions
```

如果接坞后**画面**落到错误 GPU，先确认 F10 的主显卡是槽 4。P620 的 PCI 地址以接坞后为准。需要显式固定时，为 LightDM 本机 `seat0` 指定 `/etc/X11/z8-console.conf`，在 `/etc/lightdm/lightdm.conf.d/90-z8-console.conf` 写 `[Seat:seat0]` 和 `xserver-config=z8-console.conf`。Xorg 配置用下面的 `Device` 与 `Screen`。示例 `0000:3b:00.0` 转成十进制 `PCI:59:0:0`，实际安装前替换。通过 SSH 保持一条连接，再重启显示管理器验证本地桌面。若启动失败，移走该 LightDM drop-in 后重启显示管理器即可回退。 [LightDM seat 配置](https://github.com/ubuntu/lightdm/blob/main/data/lightdm.conf) · [Xubuntu Xorg BusID](https://manpages.ubuntu.com/manpages/resolute/man5/xorg.conf.5.html)

```text
Section "Device"
    Identifier "P620"
    Driver "nvidia"
    BusID "PCI:59:0:0"
EndSection
Section "Screen"
    Identifier "P620Screen"
    Device "P620"
EndSection
```

如果只选错**编码** GPU，用 `systemctl --user edit app-dev.lizardbyte.app.Sunshine.service` 为该服务增加 `[Service]` 和 `Environment=CUDA_VISIBLE_DEVICES=GPU-<P620实际UUID>`，重启后复验 NVENC 会话归属。CUDA 设备 UUID 仅在 Sunshine 服务内应用。Linux X11 + NVENC 的配置不填 Windows 示例的 `adapter_name` 营销型号。若该构建仍选错编码器，按实际版本的 X11/CUDA 路径定位。 [CUDA 可见设备](https://docs.nvidia.com/cuda/archive/12.9.1/cuda-c-programming-guide/index.html#env-vars) · [Sunshine Linux X11 实现](https://github.com/SunshineStream/Sunshine/blob/master/src/platform/linux/x11grab.cpp)
