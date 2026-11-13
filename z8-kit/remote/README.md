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

I3 确认重启后 P620 已加载 NVIDIA 显卡驱动，再装 Sunshine。用 [官方安装文档](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2getting__started.html) 选当前 Linux 包。在 P620 负责的本机 Xfce/X11 会话内运行，合并 `sunshine.conf.example`。在 Web UI 设置凭证，按 [配置与端口文档](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html) 只允许可信 LAN/VPN 访问 Moonlight 所需端口。先在本机打开 Web UI 配对，用 Moonlight 手填 LAN/VPN 地址，1080p60/H.264 测画面、键鼠和音频。日志应显示 P620 NVENC，若落到软件编码则查 `nvidia-smi`、X11 显示、虚拟屏和捕获后端。xrdp 独立桌面由 Xorg 会话维护。
