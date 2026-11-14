# Buck2 与 Buildbarn

## P4618 热层与 HC620 冷层

`/srv/work/jackywang/<repo>`、`buck-out`、materializer DB 在 P4618 XFS。Buildbarn 的 AC、CMS、CAS 索引、持久状态和可丢的热读缓存也在 P4618，单独目录限额。HC620 RAIDZ1 的 `/data/buildbarn` 存权威 CS 大块文件。`storage/README.md` 安装 ZFS 和 systemd，挂载准备好后再启动 `z8-buildbarn.service`。

`compose.tiered.yaml` 启动一个 `bb-storage`。固定为 512 GiB 冷 CS、64 GiB 热 CS，另有 512 MiB 冷 CS 索引、128 MiB 热索引、4 GiB CMS、2 GiB AC。按典型 blob 数、淘汰、索引冲突和稳态带宽扩容。配置中 `readCaching` 热命中在 P4618；首次冷读从 RAIDZ1 读并回填热缓存，新上传直接写慢 CS。`oldBlocks/currentBlocks/newBlocks` 是同一后端的滚动生命周期，无法把 new 固定在 SSD、old 固定在 HDD。I4 未达持续写门槛时走全 XFS 回退。 [Buildbarn block allocator](https://github.com/buildbarn/bb-storage/blob/main/pkg/proto/configuration/blobstore/blobstore.proto) · [readCaching 实现](https://github.com/buildbarn/bb-storage/blob/main/pkg/blobstore/readcaching/read_caching_blob_access.go)

冷块文件所在的 ZFS 数据集继承 `compression=zstd-3`，本地设 `primarycache=metadata`。P4618 上的 64 GiB 热 CAS 负责重复读取。 [冷 CAS 配置](../storage/README.md#冷-cas-压缩)

镜像里的 `LocalBlobAccess` 在新块内递增分配偏移，旧块轮转后复用偏移。并发写可交错，文件覆写会触发 ZFS CoW。淘汰动作只把逻辑块归还给 Buildbarn 自己的 allocator，文件对应范围仍存在于 ZFS，下一次覆写后旧物理块才有机会释放。冷 CAS 是可重建数据，给这份 dataset 配快照策略时将它排除，避免把轮转后的历史 extent 长期留在池内。现有布局继续用 HC620 放权威冷块，P4618 放热块和元数据。 [固定镜像的块分配实现](https://github.com/buildbarn/bb-storage/blob/ca3d8b4/pkg/blobstore/local/block_device_backed_block_allocator.go) · [backend 配置定义](https://github.com/buildbarn/bb-storage/blob/main/pkg/proto/configuration/blobstore/blobstore.proto)

首次用 `sudo docker compose -f compose.tiered.yaml config --images` 核镜像引用，用 `config` 核绑定。两个 Linux cache 配置以及 scheduler、worker、runner-installer 都固定到原 11 月 2 日标签的 GHCR 镜像索引 digest，标签供查版本。各索引包含 `linux/amd64`。首次启动需看日志确认 schema、文件/目录权限、GetCapabilities 和 CAS/AC 读写。`docker compose -p z8-tiered -f compose.tiered.yaml logs --tail 100` 与 `ss -ltn` 可复核。 [Buildbarn GHCR 包](https://github.com/buildbarn/bb-storage/pkgs/container/bb-storage) · [Docker digest 引用](https://docs.docker.com/reference/cli/docker/image/pull/#pull-an-image-by-digest-immutable-identifier)

```bash
cd /opt/z8-kit/buildbarn
sudo docker compose -p z8-tiered -f compose.tiered.yaml config
sudo docker compose -p z8-tiered -f compose.tiered.yaml pull cache
sudo systemctl start z8-buildbarn.service
sudo docker compose -p z8-tiered -f compose.tiered.yaml ps
sudo docker compose -p z8-tiered -f compose.tiered.yaml logs --tail 100 cache
sudo stat /data/buildbarn/blocks
sudo ls -ld /srv/buildbarn/tiered/{cs,cs-hot,cms,ac}
```

容器运行后，用 `sudo docker image inspect <Compose 中的镜像引用> --format '{{json .RepoDigests}}'` 核实际 digest。运行期比较 `stat`、`du -h` 和 `zfs list`，区分块文件的逻辑大小与实际分配。冷 CS、热 CS 的容量值在 `tiered-cache.jsonnet`，索引与块的配置生成在 `disk.libsonnet`。以后只有发现典型项目的有效冷缓存反复被提前淘汰时才扩容。块文件容量与其持久索引相互关联，变更时优先另开空状态目录和新冷块路径跑一轮，避免用变更后的几何直接读取旧状态。

全闪存 `compose.yaml` 用于冷库回退。切换时先停 tiered service，两个配置都监听 8980，各用自己的索引与状态目录。

## Buck2 客户端

**每个构建节点运行一个本机 Buildbarn，独立持有 AC 和 CAS。** Z8 的 Linux harness 和 Z8 上的 Linux worker 使用 Z8 冷库。同一台 Mac 的不同项目和工作树可以复用 Mac 的本地缓存。客户端用本机 `127.0.0.1:8980`，构建仍由各自主机的原生工具链执行。每增加一台独立构建节点，就在该节点部署自己的服务和数据卷。 [Buildbarn 本地块存储](https://github.com/buildbarn/bb-storage/blob/main/README.md)

把 `cache-executor.bzl.example` 合入项目已注册的本地 execution platform，保留 OS、CPU、SDK 和工具链约束。样例在未加载缓存配置时关闭缓存查询和上传。两端分别带 `buck2-linux.buckconfig` 或 `buck2-macos.buckconfig` 开启本机读写。`linux-x86_64`、`macos-arm64` 和 `macos-x86_64` 是 Action Cache 的实例名，物理独立由各自的服务和卷保证。RE 产物按需物化时，依赖的是本机缓存进程。 [Buck2 RE 配置](https://buck2.build/docs/users/remote_execution/) · [CommandExecutorConfig](https://buck2.build/docs/api/build/CommandExecutorConfig/) · [Buck2 延迟物化](https://buck2.build/docs/users/advanced/deferred_materialization/)

### Mac 本机冷库

Mac 用 Docker Desktop 运行同一种 `bb-storage`。镜像固定为上游 11 月 4 日的多架构 digest，Intel Mac 拉 `linux/amd64`，Apple Silicon 拉 `linux/arm64`。编译器和 Buck2 仍在 macOS 原生运行。Docker 的 `mac-buildbarn_mac-store` 命名卷在本机 VM 磁盘上。固定 **64 GiB CS、4 GiB CMS、2 GiB AC** 的块文件规模，索引另计，检查 Mac 和 Docker VM 两边的余量。Mac 的这一级用本地 SSD 就够，三个存储区都在同一卷。 [Buildbarn 镜像](https://github.com/buildbarn/bb-storage/pkgs/container/bb-storage) · [Docker Desktop for Mac](https://docs.docker.com/desktop/setup/install/mac-install/) · [Docker Desktop 卷和磁盘设置](https://docs.docker.com/desktop/settings-and-maintenance/settings/)

```bash
# 在 Mac 上进入从部署包解出的 buildbarn 目录。
mkdir -p "$HOME/.config/z8"
cp buck2-macos.buckconfig "$HOME/.config/z8/"
docker compose -p mac-buildbarn -f compose.macos.yaml config
docker compose -p mac-buildbarn -f compose.macos.yaml pull
docker compose -p mac-buildbarn -f compose.macos.yaml up -d --pull never
docker compose -p mac-buildbarn -f compose.macos.yaml ps
docker compose -p mac-buildbarn -f compose.macos.yaml logs --tail 100 cache
docker volume inspect mac-buildbarn_mac-store
```

Apple Silicon 保留 `macos-arm64`，Intel Mac 将 `~/.config/z8/buck2-macos.buckconfig` 中的 `instance_name` 改为 `macos-x86_64`。确认 Docker Desktop 已启动且本机 8980 没有旧 SSH 转发在监听。两个镜像首次联网拉完后，后续 `up --pull never` 可以离线运行。Compose `down` 默认保留命名卷，避免使用 `down -v` 清除缓存。 [Docker Compose down](https://docs.docker.com/reference/cli/docker/compose/down/)

```bash
# 在 Mac 项目目录运行，替换目标标签。
cfg="$HOME/.config/z8/buck2-macos.buckconfig"
target=//app:target
buck2 build --config-file "$cfg" "$target"
buck2 log what-ran --emit-cache-queries
buck2 log what-materialized --sort-by-size
```

验收用依赖已准备齐全的目标。在工作树 A 构建并确认上传；关闭 Mac Wi-Fi、确认 Z8 不可达，再从同一提交的干净工作树 B 构建，核 AC 命中和实际产物。需要同时验断网下的 cache miss 时，再选一个此前未上传的目标。Docker VM 或本机冷库停机时，使用下列独立 daemon 和输出目录重新构建，规避上一轮尚未物化的缓存结果。Z8 的同机缓存停机也可用这条命令，前提是选本机 execution platform、备齐工具链和输入。 [Buck2 build 参数](https://buck2.build/docs/users/commands/build/) · [Buck2 isolation dir](https://buck2.build/docs/concepts/isolation_dir/)

```bash
buck2 --isolation-dir local-rebuild build --local-only --no-remote-cache "$target"
```

Buck2 自带 Deferred Materialization，RE 产物在本地 action 需要时才拉。可合并 `buck2-deferred.buckconfig.example`，让 materializer 用 SQLite 持久化本地状态。普通 shell 对任意文件路径读取不会触发该机制。显式需要的目标先经 Buck2 构建/运行。开源 RE 后端的 TTL 刷新有限，冷 CAS 淘汰后可能需要重构；保持 completeness checking，并测试延迟拉取后再旋转冷块。 [Buck2 Deferred Materialization](https://buck2.build/docs/users/advanced/deferred_materialization/)

### 验证 Linux 缓存

I4 的覆盖脚本已验 dm-zoned 回收，I5 只走真实 Buck2 路径。在工作树 A 构建产生新 digest 的目标，确认上传；从干净工作树 B 读取同一产物，首次取回填热层。仅需核一次实际物化和热层读，AC hit 单独不足以证明下载。用 `zpool iostat -v z8data 2` 和 `iostat -xz 2` 核实际设备活动。 [I4 持续写与覆盖](../storage/README.md#5-i4-验证实际写入scrub-与缺盘)

在 Linux 工作树 A 和同一提交的干净工作树 B 各执行一次下列命令，替换项目目标标签。分别保存两次的 log，检查缓存查询、AC 命中和本地执行动作数量。

```bash
cfg=/opt/z8-kit/buildbarn/buck2-linux.buckconfig
target=//app:target
buck2 build --config-file "$cfg" "$target"
buck2 log show > buck2-build-events.jsonl
buck2 log what-ran --emit-cache-queries
buck2 log what-materialized --sort-by-size
buck2 log what-uploaded
```

启用 Linux worker 后，用一个真实 RE 输出确认需要时才物化。 [Buck2 日志子命令](https://buck2.build/docs/users/commands/log/)

## Git worktree 与 XFS reflink

同一个 Git 仓库建多个 worktree，复用对象库并保留各自的检出和 index。两个 worktree 各用自己的 `buck-out`、daemon 状态及物化数据库，跨树构建结果复用走同一个 Buildbarn AC/CAS。两个独立编译动作或两次 RPC 下载各自写入文件时，XFS 不会按内容自动合并。避免把 `buck-out` 硬链、软链或 bind 到另一个活跃 worktree 的输出树。 [Git worktree](https://git-scm.com/docs/git-worktree) · [Buck2 隔离目录](https://buck2.build/docs/concepts/isolation_dir/) · [Buck2 CAS 下载路径](https://github.com/facebook/buck2/blob/main/app/buck2_execute_impl/src/materializers/deferred/io_handler.rs#L199)

```bash
cd /srv/work/jackywang
git -C example worktree list
git -C example rev-parse --path-format=absolute --git-common-dir
git -C example-codex rev-parse --path-format=absolute --git-common-dir
findmnt -T /srv/work/jackywang -o SOURCE,TARGET,FSTYPE
xfs_info /srv/work/jackywang
```

前两个 Git 路径应指向同一主仓库的 `.git`。XFS 应显示 `reflink=1`。下面用真实写入过的文件做一次对照，预期 inode 不同、物理范围相同并标记 `shared`。测试文件只在工作区临时目录内。

```bash
(
    set -e
    dir=$(mktemp -d /srv/work/jackywang/.xfs-reflink.XXXXXX)
    trap 'rm -f -- "$dir/original" "$dir/clone"; rmdir -- "$dir"' EXIT
    dd if=/dev/urandom of="$dir/original" bs=1M count=16 conv=fsync status=none
    cp --reflink=always -- "$dir/original" "$dir/clone"
    stat -c '%d:%i %n' "$dir/original" "$dir/clone"
    filefrag -sv "$dir/original" "$dir/clone"
)
```

Buck2 没有已核实的全局 reflink 开关。需要独立发布件时，取 Buck2 已物化的产物，在同一 XFS 上显式 clone，`--reflink=always` 失败会报错。工作树继续各自管理 `buck-out`，跨树结果通过 Buildbarn 复用。 [Buck2 LocalCopy](https://github.com/facebook/buck2/blob/main/app/buck2_execute_impl/src/materializers/io.rs#L156) · [Linux FICLONE](https://man7.org/linux/man-pages/man2/FICLONE.2const.html)

```bash
cd /srv/work/jackywang/example
target=//app:binary
src=$(buck2 build -M all --show-full-simple-output "$target") || exit 1
test -f "$src" || exit 1
outdir=$(mktemp -d /srv/work/jackywang/.buck2-reflink.XXXXXX)
cp --reflink=always --preserve=mode -- "$src" "$outdir/export"
filefrag -sv "$src" "$outdir/export"
```

## Linux worker

1. 有实际 Linux RE 任务时启用 worker，复用 I5 已验证的本机 CAS。
2. `compose.worker.yaml` 加入 scheduler、runner、worker，worker 通过 Docker 内网向同一个 `cache:8980` 读写 CS/CMS/AC。Linux 使用 `buck2-shared-worker.buckconfig` 与既有 `linux-worker-executor.bzl.example`。在 `/opt/z8-kit/buildbarn` 执行 `docker compose -p z8-tiered -f compose.tiered.yaml -f compose.worker.yaml config`，再 `sudo systemctl enable --now z8-buildbarn-worker.service`。服务预建 XFS 上的 `worker/build`、`worker/cache` 与 `runner-bin`，共用 `/run/z8-bb-runner` 上的 socket。runner 启动时清理自己的残留 socket，worker 等 socket 出现再启动。固定镜像的 worker、runner-installer 和 runner 都以 UID 0 启动。用隔离 checkout 验实际 RE、按需下载、worker 停启后 CAS 持续服务。I7 把 runner 放进 [构建侧 cgroup](../host/CPU-PLACEMENT.md#生成并安装)。 [Compose v2.40.3 按服务监控](https://github.com/docker/compose/blob/v2.40.3/pkg/compose/up.go#L177)
3. Runner 固定 4 个活动 action、12 CPU 时间额度、32 GiB 内存上限。用一个真实目标核编译产物与 action 日志。

[上游 Docker Compose](https://github.com/buildbarn/bb-deployments/tree/main/docker-compose) · [Buck2 Buildbarn 样例](https://github.com/facebook/buck2/tree/main/examples/remote_execution/buildbarn)

## 全 XFS 回退

适用于 I4 冷库持续写达不到目标时。先停 tiered 服务，再用 P4618 上单独的 64 GiB CAS 配置跑本地构建。这里新建实例状态，Buck2 首轮会重新填充缓存。

```bash
sudo systemctl disable --now z8-buildbarn-worker.service z8-buildbarn.service
cd /opt/z8-kit/buildbarn
export BB_DATA_DIR=/srv/buildbarn/cache-xfs
sudo install -d -m 0750 "$BB_DATA_DIR"/{cs,cms,ac}/persistent_state
test "$(findmnt -n -T "$BB_DATA_DIR" -o FSTYPE)" = xfs &&
    sudo env BB_DATA_DIR="$BB_DATA_DIR" docker compose -p z8-xfs -f compose.yaml up -d cache
ss -ltn 'sport = :8980'
```

先确认 `findmnt` 显示 P4618 的 XFS，再启动 cache。验证 AC/CAS 后用 `buck2-linux.buckconfig` 走本地执行。回到 tiered 前先用同一 Compose 项目和目录环境执行 `down`，再启用原 systemd 服务。
