# 远程入口

## SSH

I2 使用槽 7 的 AX210 接内网。正式 Xubuntu 首次登录后连接同一 Wi-Fi，把连接设为开机自动连接且可供所有用户使用。若使用路由器的 DHCP 保留地址，在本机控制台给该连接设固定硬件 MAC，并用 `ip -br link` 看实际地址。Xubuntu 桌面安装使用 NetworkManager，可在该配置上执行下例，连接名从第一条命令抄。若走 I1.3 且 AX210 已由 Netplan 的 `networkd` 管理，使用该接口当前 MAC 做 DHCP 保留并验证开机连接。 [NetworkManager 连接属性](https://networkmanager.dev/docs/api/latest/nm-settings-nmcli.html)

```bash
nmcli connection show --active
profile='REPLACE_WITH_WIFI_PROFILE'
sudo nmcli connection modify "$profile" connection.autoconnect yes \
    connection.permissions '' 802-11-wireless.cloned-mac-address permanent
sudo nmcli connection up "$profile"
ip -br link
ip -br address
```

如果重启停在登录界面时 Wi-Fi 未连接，在本机打开 Xfce 的连接编辑器。家庭 WPA-PSK/SAE 网络在 `Wi-Fi Security` 中选择为所有用户保存密码，重新连接，再测试一次。这样密码由系统连接配置保存，开机时即可使用。

用 `hostnamectl --static` 核 `z8g4-max`。执行 `sudo apt install openssh-server tmux`，用 `sudo sshd -t` 校验配置。Ubuntu 26.04 默认 socket 激活，执行 `sudo systemctl enable --now ssh.socket` 并用 `ss -ltn 'sport = :22'` 确认监听。用本机控制台把公钥放入 `z8user` 的 `~/.ssh/authorized_keys`，以第二条 SSH 连接验证后再关闭密码登录。重启后先停在登录界面，从 Mac 验证 Wi-Fi 与 SSH 能自行恢复。把样例 Host 块合并到客户端 `~/.ssh/config`，将两个 `HostName` 填为保留 IP 或实际可解析的 LAN DNS 名。`ssh z8g4-max` 或 `ssh z8` 都使用登录用户 `z8user`。RDP 和推理端口按需走 `ssh -NT z8-ports`。

## xrdp

`sudo apt install xrdp xorgxrdp`。以 `z8user` 复制 `xsession.example` 到 `~/.xsession` 并设 0700。合并 `/etc/xrdp/xrdp.ini` 的 `[Globals]` 中 `port=tcp://127.0.0.1:3389`，用 `man xrdp.ini` 核对当前版本语法，保留其余会话定义。用 `sudo systemctl restart xrdp`、`ss -ltnp` 和 `journalctl -u xrdp -u xrdp-sesman` 验证。若日志指出 TLS 私钥不可读，按本机证书权限和包说明配置 `xrdp` 服务用户。通过 tunnel 用 RDP 客户端连 `127.0.0.1:13389`，选择 Xorg、用户 `z8user`。首次测试前先登出该用户的本机 Xfce。若确需 Sunshine 控制台与 RDP 同时运行，并且同一用户的两个 Xfce 会话冲突，可为其中一个会话另建图形用户。

## Sunshine

I3 确认 P620 已加载 NVIDIA 580 分支后，装能在该驱动上打开 H.264 NVENC 的 Sunshine 构建，记录安装版本。FFmpeg 以 NVENC API 13.0 构建时的最低驱动为 570，API 13.1 则要求 610。若日志报 `minimum required Nvidia driver` 或 NVENC API 版本不符，检查 Sunshine 所用编码库，按现有 V100 驱动分支选择兼容构建。 [Sunshine 安装](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2getting__started.html) · [FFmpeg NVENC 版本检查](https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/nvenc.c) · [NVIDIA SDK 13.1 要求](https://docs.nvidia.com/video-technologies/video-codec-sdk/13.1/read-me/index.html#system-requirements)

Sunshine 在 P620 的**本机** Xfce/X11 会话运行，`xsession.example` 供 xrdp 独立桌面使用。合并 `sunshine.conf.example`，在 Web UI 设置凭证，只允许可信 LAN/VPN 访问所需端口。显示器或虚拟屏接 P620，从 `xrandr` 和 Sunshine 日志找到实际已连接接口，按需填写 `output_name`。下面的命令分别在仅 P620 和接回四张 V100 后执行。NVENC 支持矩阵列出 P620 与 Tesla V100，测试时以实际编码 PID 和 GPU 为准。 [Sunshine 显示与编码配置](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html#output_name) · [NVIDIA NVENC 矩阵](https://developer.nvidia.com/video-encode-decode-support-matrix)

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
