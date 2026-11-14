# Linux 与 macOS 构建农场

max 运行唯一的 scheduler 和权威 AC/CAS。max、mini、Mac 的 Buck2 都用 `hardlinking` 实例。Linux 队列匹配 `OSFamily=linux` 和镜像，Darwin 队列匹配 `OSFamily=macos`、`arch=arm64`、`xcode=<版本>`。worker 主机名用来识别机器。先上线 max，再启 mini 和 Mac。 [Buildbarn 队列匹配](https://github.com/buildbarn/bb-remote-execution/blob/c9ba98cf52/pkg/scheduler/in_memory_build_queue.go#L608)

两台边缘机器共用 `edge-cache.jsonnet`。CAS 依次查本机 256 GiB 热 CS、表中的冷 CS 和 max。所有索引放热盘，首次从样例复制 `edge-site.json` 时，`coldIndexGiBPerTiB` 为 16。mini 的 640 GiB 冷 CS 配 10 GiB，Mac 首装的 512 GiB 配 8 GiB。已初始化的站点沿用原配置。采用新比例时停 cache，退役旧冷块文件、索引和持久状态，再写配置并重启。CMS 在热盘留 4 GiB 和 128 MiB 索引，AC 直接查 max，由权威端检查产物完整性。上传直达 max，缓存只在读取时回填。固定版本把 `FindMissing` 交给慢侧，max 不可达时直接用本机执行。 [索引计算](README.md#冷-cs-几何与容量) · [Buildbarn readCaching 源码](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/readcaching/read_caching_blob_access.go)

## SSH 与目录

在 mini 和 Mac 配置 [z8-build SSH 样例](../remote/ssh_config.example)。用专用密钥和已核对的 host key 验证 `ssh -NT -o BatchMode=yes z8-build`。本机 18980 和 18983 分别转到 max 的存储 8980 和 worker 调度端口 8983。max 的两端口都只监听 loopback。max 板载 GbE，NAB9S 双 2.5GbE；接线后以实际协商速度为准。 [HP QuickSpecs](https://h30434.www3.hp.com/psg/attachments/psg/Business-PC-Workstation-POS/44704/1/Z8%20G4%20Quickspecs%20v67.pdf) · [NAB9S 规格](https://store.minisforum.com/products/minisforum-nab9s-mini-pc)

| 节点 | 热层和工作目录 | 冷层 | Worker |
|---|---|---|---|
| jackywang-xubuntu-mini | PM9F1，系统、工作树与 buck-out 也在此盘 | S3610 上 640 GiB | 16 并发，16 CPU 配额，40 GiB |
| Mac mini M4 | 外接 PM9F1 的 APFS，系统和 Xcode 留内置盘 | 初装用同一外接 PM9F1 上 512 GiB。四块 CMR 到货后为 4×3 TiB | 4 并发 |

从持久的 `z8-kit/buildbarn` 目录把 `edge-site.json.example` 复制为 `edge-site.json`。填主机名及热、冷、工作目录的绝对路径。`socket` 用工作目录下的短绝对路径，例如 `/Volumes/Farm/w/r.sock`。Mac 再添加 `xcode`（`xcodebuild -version` 第一行去掉 `Xcode `）、`developerDir`（`xcode-select -p`）和 `caseInsensitive`（普通 APFS 为 `true`）。将 shell 变量 HOT、COLD、WORK 设为相同的路径。热、冷、工作目录填为对应已挂载卷下的子目录。先用 `df -h` 核实卷所在设备，再执行下列命令。worker 的两个子目录须在同一文件系统，输入靠硬链接物化。 [Buildbarn 硬链接后端](https://github.com/buildbarn/bb-remote-execution/blob/c9ba98cf52/cmd/bb_worker/main.go#L293)

```
mkdir -p "$HOT"/{cs,cs-cold,cms}/persistent_state "$COLD/cs" "$WORK"/{build,cache}
probe=$(mktemp "$WORK/cache/link.XXXXXX")
ln "$probe" "$WORK/build/${probe##*/}" &&
    rm -- "$probe" "$WORK/build/${probe##*/}"
```

## mini

先停止手动隧道，从 `z8-kit/buildbarn` 执行。两台 Linux worker 使用相同的容器内 `/worker/build`、镜像 digest、平台属性与 CPU 目标基线。工具链随镜像或项目输入提供，通用构建按项目选 `x86-64-v3`，禁用 `-march=native` 与 `-mtune=native`。

```
install -Dm0644 edge-tunnel.service.example "$HOME/.config/systemd/user/z8-edge-tunnel.service"
sudo loginctl enable-linger "$USER"
systemctl --user daemon-reload
systemctl --user enable --now z8-edge-tunnel.service

export BB_EDGE_HOT="$HOT" BB_EDGE_COLD="$COLD" BB_EDGE_WORK="$WORK"
export BB_DATA_DIR="$WORK"
sudo install -d -m 0750 "$BB_DATA_DIR/runner-bin"
sudo --preserve-env=BB_EDGE_HOT,BB_EDGE_COLD,BB_EDGE_WORK,BB_DATA_DIR \
    docker compose -p z8-edge -f compose.edge-linux.yaml config --quiet
sudo --preserve-env=BB_EDGE_HOT,BB_EDGE_COLD,BB_EDGE_WORK,BB_DATA_DIR \
    docker compose -p z8-edge -f compose.edge-linux.yaml up -d
```

## Mac mini M4

下载固定版本的三个 GitHub Actions 资产，分别解压，将文件放到 `$HOME/.local/libexec/z8-buildbarn`，命名为 `bb_storage`、`bb_worker`、`bb_runner`，设 0755。用 `file` 查 Mach-O arm64。若资产在部署时已过期，从对应 Git 提交构建 `//cmd/bb_storage`、`//cmd/bb_worker` 和 `//cmd/bb_runner`。 [bb-storage ca3d8b4](https://github.com/buildbarn/bb-storage/actions/runs/41419059475/artifacts/13130587121) · [bb-worker c9ba98c](https://github.com/buildbarn/bb-remote-execution/actions/runs/41423547182/artifacts/13131822142) · [bb-runner c9ba98c](https://github.com/buildbarn/bb-remote-execution/actions/runs/41423547182/artifacts/13132565093)

以专用的普通账户安装 LaunchAgents。runner 原生执行农场提交的代码，该账户只需访问 Xcode 和农场数据目录。先停旧 Docker 缓存和手动隧道。该账户登录且 Mac 唤醒时提供 Darwin worker。工具链规则给 Darwin 动作传 `XCODE_VERSION_OVERRIDE` 和 `APPLE_SDK_PLATFORM=MacOSX`，runner 用本机映射解析 `DEVELOPER_DIR` 和 SDK。单元测试只依赖项目输入、工具链及 SDK。 [Buildbarn Xcode 解析](https://github.com/buildbarn/bb-remote-execution/blob/c9ba98cf52/cmd/bb_runner/main.go#L145) · [Apple launchd](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)

```
out=$(mktemp -d)/agents
python3 macos-launch-agents.py "$HOME/.local/libexec/z8-buildbarn" "$out"
mkdir -p "$HOME/Library/LaunchAgents"
for plist in "$out"/*.plist; do
    plutil -lint "$plist" || break
    install -m 0644 "$plist" "$HOME/Library/LaunchAgents/" || break
    launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/${plist##*/}" || break
done
```

日志保存在 `~/Library/Logs/z8-buildbarn`。Mac 不在线时调度器按 60 秒无 worker 的队列超时清理该平台的任务。

### Mac 的四块 CMR 到货后

用磁盘工具将四块可清空的盘分别建为 GPT/APFS，卷名固定为 `FarmCold1` 至 `FarmCold4`。每块 4 TB 名义约 3.64 TiB，取 3 TiB 作块文件。Buildbarn 自己按 digest 分四段，每块盘各建一个稀疏文件，合计 12 TiB。每盘的索引为 48 GiB，共 192 GiB，留在 PM9F1。重建任一盘时使用原卷名和 shard 键，清掉该 shard 的旧索引和持久状态后由 max 回填。守卫要求四盘目录均到位才启动边缘存储。 [Apple APFS 数据卷](https://support.apple.com/guide/disk-utility/file-system-formats-dsku19ed921c/mac) · [Buildbarn sharding 语义](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/proto/configuration/blobstore/blobstore.proto#L317)

确认四卷实际已挂载。先退出当前 farm 的 cache LaunchAgent，再把下面字段加到 `edge-site.json`，并把 `coldIndexGiBPerTiB` 设为 16。分别创建各卷的 `buildbarn/cs` 和热盘的 `cs-cmr-1` 至 `cs-cmr-4` 内的 `persistent_state`。重新生成并安装 cache plist，再启动它。此前的 SSD 冷缓存另行清理，热 CS 和 CMS 继续复用。

```json
"coldShards": [
  "/Volumes/FarmCold1/buildbarn",
  "/Volumes/FarmCold2/buildbarn",
  "/Volumes/FarmCold3/buildbarn",
  "/Volumes/FarmCold4/buildbarn"
]
```

```bash
domain="gui/$(id -u)"
launchctl bootout "$domain/local.z8.farm.cache"
# 更新 edge-site.json 后继续。
for n in 1 2 3 4; do
    diskutil info "/Volumes/FarmCold$n" >/dev/null || exit 1
    mkdir -p "/Volumes/FarmCold$n/buildbarn/cs" "$HOT/cs-cmr-$n/persistent_state" || exit 1
done
out=$(mktemp -d)/agents
python3 macos-launch-agents.py "$HOME/.local/libexec/z8-buildbarn" "$out"
cache="$HOME/Library/LaunchAgents/local.z8.farm.cache.plist"
install -m 0644 "$out/local.z8.farm.cache.plist" "$cache"
launchctl bootstrap "$domain" "$cache"
```

## Buck2 上线

三台机器用同一个 `buck2-shared-worker.buckconfig`，都连接本机 8980。填 `macos_xcode`，与 Mac 的 `xcode` 一致。将 Linux 和 Darwin executor 样例合入项目注册的 execution platform，注册对应 OS、架构和工具链约束。项目应有分别指定默认目标平台的 Linux、Darwin 测试目标，测试框架须支持远程测试。执行一次并在调度日志核两个平台的实际 worker。 [Buck2 执行平台](https://buck2.build/docs/rule_authors/configurations/#custom-execution-platforms) · [Buck2 目标平台](https://buck2.build/docs/concepts/configurations/)

```
buck2 test --remote-only --config-file "$farm_cfg" //app:unit_linux //app:unit_darwin
```

跨机器从同一提交的干净工作树查 AC 命中。max 停机时切项目本机执行平台，使用 `buck2 --isolation-dir local-rebuild build --local-only --no-remote-cache "$target"`。若增加外部 Darwin worker，沿用相同平台属性，仍可加入 max 队列。独立的商用 RE 后端另用一份 buckconfig 和一次调用。源码规则只依赖环境语义和工具链，凭据与地址放运行配置。
