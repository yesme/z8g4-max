# Buck2 与 Buildbarn

## P4618 热层与 HC620 冷层

`/srv/work/z8user/<repo>`、`buck-out`、materializer DB 在 P4618 XFS。Buildbarn 的 AC、CMS、CAS 索引、持久状态和可丢的热读缓存也在 P4618，单独目录限额。HC620 RAIDZ1 的 `/data/buildbarn` 存权威 CS 大块文件。`storage/README.md` 安装 ZFS 和 systemd，挂载准备好后再启动 `z8-buildbarn.service`。

`compose.tiered.yaml` 启动一个 `bb-storage`。初始试配为 512 GiB 冷 CS、64 GiB 热 CS，另有 512 MiB 冷 CS 索引、128 MiB 热索引、4 GiB CMS、2 GiB AC。按典型 blob 数、淘汰、索引冲突和稳态带宽扩容。配置中 `readCaching` 热命中在 P4618；首次冷读从 RAIDZ1 读并回填热缓存，新上传直接写慢 CS。`oldBlocks/currentBlocks/newBlocks` 是同一后端的滚动生命周期，无法把 new 固定在 SSD、old 固定在 HDD。若上传是瓶颈，先用 P4800X 的 dm-zoned 写入路径与 P4618 全闪存基线 A/B；SSD write-back 再下刷需独立的缓冲机制和恢复设计。 [Buildbarn block allocator](https://github.com/buildbarn/bb-storage/blob/main/pkg/proto/configuration/blobstore/blobstore.proto) · [readCaching 实现](https://github.com/buildbarn/bb-storage/blob/main/pkg/blobstore/readcaching/read_caching_blob_access.go)

当前 cold block file 由 ZFS 做盘上压缩。Buildbarn 的切块与拼块是本地后端布局，ByteStream zstd 另控制传输。I5 用真实上传和冷读取对比 [冷 CAS 的 `zstd-3`、`lz4` 与 `off`](../storage/README.md#冷-cas-压缩怎么定)。

首次用 `docker compose -f compose.tiered.yaml config` 检查绑定与镜像。试配用上游 11 月镜像标签，首次启动需看日志确认 schema、文件/目录权限、GetCapabilities 和 CAS/AC 读写，再记录实际镜像 digest。`docker compose -p z8-tiered -f compose.tiered.yaml logs --tail 100` 与 `ss -ltn` 可复核。若镜像拒绝热读包装的 schema，可先把 `tiered-cache.jsonnet` 中的 `chunkStorage` 改为其 `slow` backend，用同一冷块与索引跑通，再在当前版 schema 下恢复热读。

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

容器运行后，用 `sudo docker image inspect <实际镜像标签> --format '{{json .RepoDigests}}'` 抄下 digest。运行期比较 `stat`、`du -h` 和 `zfs list`，区分块文件的逻辑大小与实际分配。冷 CS、热 CS 的容量值在 `tiered-cache.jsonnet`，索引与块的配置生成在 `disk.libsonnet`。先记录淘汰间隔、日上传量和命中率，再决定是否加大冷 CS。块文件容量与其持久索引相互关联，变更时优先另开空状态目录和新冷块路径跑一轮，避免用变更后的几何直接读取旧状态。

原全闪存 `compose.yaml` 保留作对照。切换时先停 tiered service，两个配置都监听 8980，各用自己的索引与状态目录。

## Buck2 客户端

**每个构建节点运行一个本机 Buildbarn，独立持有 AC 和 CAS。** Z8 的 Linux harness 和 Z8 上的 Linux worker 使用 Z8 冷库。同一台 Mac 的不同项目和工作树可以复用 Mac 的本地缓存。客户端用本机 `127.0.0.1:8980`，构建仍由各自主机的原生工具链执行。每增加一台独立构建节点，就在该节点部署自己的服务和数据卷。 [Buildbarn 本地块存储](https://github.com/buildbarn/bb-storage/blob/main/README.md)

把 `cache-executor.bzl.example` 合入项目已注册的本地 execution platform，保留 OS、CPU、SDK 和工具链约束。样例在未加载缓存配置时关闭缓存查询和上传。两端分别带 `buck2-linux.buckconfig` 或 `buck2-macos.buckconfig` 开启本机读写。`linux-x86_64`、`macos-arm64` 和 `macos-x86_64` 是 Action Cache 的实例名，物理独立由各自的服务和卷保证。RE 产物按需物化时，依赖的是本机缓存进程。 [Buck2 RE 配置](https://buck2.build/docs/users/remote_execution/) · [CommandExecutorConfig](https://buck2.build/docs/api/build/CommandExecutorConfig/) · [Buck2 延迟物化](https://buck2.build/docs/users/advanced/deferred_materialization/)

### Mac 本机冷库

Mac 用 Docker Desktop 运行同一种 `bb-storage`。镜像固定为上游 11 月 4 日的多架构 digest，Intel Mac 拉 `linux/amd64`，Apple Silicon 拉 `linux/arm64`。编译器和 Buck2 仍在 macOS 原生运行。Docker 的 `mac-buildbarn_mac-store` 命名卷在本机 VM 磁盘上。先按 **64 GiB CS、4 GiB CMS、2 GiB AC** 的块文件规模试配，索引另计，检查 Mac 和 Docker VM 两边的余量。Mac 的这一级用本地 SSD 就够，三个存储区都在同一卷。 [Buildbarn 镜像](https://github.com/buildbarn/bb-storage/pkgs/container/bb-storage) · [Docker Desktop for Mac](https://docs.docker.com/desktop/setup/install/mac-install/) · [Docker Desktop 卷和磁盘设置](https://docs.docker.com/desktop/settings-and-maintenance/settings/)

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

Buck2 自带 Deferred Materialization，RE 产物在本地 action 需要时才拉。可合并 `buck2-deferred.buckconfig.example`，让 materializer 用 SQLite 持久化本地状态。普通 shell 对任意文件路径读取不会触发该机制。显式需要的目标先经 Buck2 构建/运行。若是 cache-only 工作流，按 `buck2 log show` 和冷读量实证该版本是否延迟拉取对应 AC 命中输出。开源 RE 后端的 TTL 刷新有限，冷 CAS 淘汰后可能需要重构；保持 completeness checking，并测试延迟拉取后再旋转冷块。 [Buck2 Deferred Materialization](https://buck2.build/docs/users/advanced/deferred_materialization/)

选 Linux 本机目标比较干净 checkout 冷缓存、热缓存、同一目标第二次本地使用、并发上传，以及构建+推理时的 p95。`buck2 log show` 查远端 AC 命中，`iostat -xz 2` 与 `zpool iostat -v 2` 查冷盘读/写。专门选择一个超过 dm-zoned cache 的上传/覆盖段观察 reclaim。热命中、冷读、上传的结果分别与全闪存基线对照。

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

再挑一个含 RE 输出、后续被本地动作消费的依赖链。第一遍构建生产者，第二遍构建本地消费者；用每步的日志和服务端读量核何时下载。若第二步从旧 AC 拿到结果、CAS 文件已经轮转，观察客户端是否重新执行，结合服务端 completeness checking 定位。 [Buck2 日志子命令](https://buck2.build/docs/users/commands/log/)

## Git worktree 与 XFS reflink

同一个 Git 仓库建多个 worktree，复用对象库并保留各自的检出和 index。两个 worktree 各用自己的 `buck-out`、daemon 状态及物化数据库，跨树构建结果复用走同一个 Buildbarn AC/CAS。两个独立编译动作或两次 RPC 下载各自写入文件时，XFS 不会按内容自动合并。避免把 `buck-out` 硬链、软链或 bind 到另一个活跃 worktree 的输出树。 [Git worktree](https://git-scm.com/docs/git-worktree) · [Buck2 隔离目录](https://buck2.build/docs/concepts/isolation_dir/) · [Buck2 CAS 下载路径](https://github.com/facebook/buck2/blob/main/app/buck2_execute_impl/src/materializers/deferred/io_handler.rs#L199)

```bash
cd /srv/work/z8user
git -C example worktree list
git -C example rev-parse --path-format=absolute --git-common-dir
git -C example-codex rev-parse --path-format=absolute --git-common-dir
findmnt -T /srv/work/z8user -o SOURCE,TARGET,FSTYPE
xfs_info /srv/work/z8user
```

前两个 Git 路径应指向同一主仓库的 `.git`。XFS 应显示 `reflink=1`。下面用真实写入过的文件做一次对照，预期 inode 不同、物理范围相同并标记 `shared`。测试文件只在工作区临时目录内。

```bash
(
    set -e
    dir=$(mktemp -d /srv/work/z8user/.xfs-reflink.XXXXXX)
    trap 'rm -f -- "$dir/original" "$dir/clone"; rmdir -- "$dir"' EXIT
    dd if=/dev/urandom of="$dir/original" bs=1M count=16 conv=fsync status=none
    cp --reflink=always -- "$dir/original" "$dir/clone"
    stat -c '%d:%i %n' "$dir/original" "$dir/clone"
    filefrag -sv "$dir/original" "$dir/clone"
)
```

Buck2 的 deferred materializer 对已有的本地文件使用 `LocalCopy`，普通文件走 `fs_util::copy`。Linux 7.0 上同一 XFS 的 `copy_file_range` 可以进入 clone 路径，也可能回退到实际复制。Buck2 没有已核实的全局 reflink 配置项。对当前 Buck2 用一个真实的大二进制目标测 `--out`。下面挑单文件目标，`outdir` 留在与 `buck-out` 同一个挂载。先 build 得到现有产物，再跟踪客户端导出，最后用 FIEMAP 验证落盘。若要验证规则本身的 LocalCopy，则选一个实际执行 `ctx.actions.copy_file` 的目标，跟踪其 Buck2 daemon 或在新隔离目录下用 `strace -f` 启动首次构建，再查源文件与规则输出。 [Buck2 LocalCopy](https://github.com/facebook/buck2/blob/main/app/buck2_execute_impl/src/materializers/io.rs#L156) · [Buck2 build 参数](https://buck2.build/docs/users/commands/build/) · [Linux 7.0 copy_file_range](https://github.com/torvalds/linux/blob/v7.0/fs/read_write.c#L1463) · [Linux reflink](https://man7.org/linux/man-pages/man2/FICLONE.2const.html)

```bash
sudo apt install strace
cd /srv/work/z8user/example
buck2 --version
target=//app:binary
src=$(buck2 build -M all --show-full-simple-output "$target") || exit 1
test -f "$src" || exit 1
outdir=$(mktemp -d /srv/work/z8user/.buck2-reflink.XXXXXX)
findmnt -T "$src" -o SOURCE,TARGET,FSTYPE
findmnt -T "$outdir" -o SOURCE,TARGET,FSTYPE
strace -f -y -e trace=ioctl,copy_file_range,sendfile,splice \
    -o "$outdir/trace.log" buck2 build "$target" --out "$outdir/export"
grep -E 'FICLONE|copy_file_range|sendfile|splice' "$outdir/trace.log"
filefrag -sv "$src" "$outdir/export"
# 当显式导出需要保证 reflink 时，使用已物化的 Buck2 产物。
cp --reflink=always --preserve=mode -- "$src" "$outdir/explicit"
filefrag -sv "$src" "$outdir/explicit"
```

`FICLONE` 或 `copy_file_range` 是路径线索。以两份文件的 `shared` 和物理区段匹配作为省空间的证据，`du` 会分别计两份逻辑拥有的块。工作流里只有需要第二份实体文件时才显式 reflink 导出；能直接使用 Buck2 返回的产物路径时可省掉导出。项目规则允许产物引用时，`ctx.actions.symlink_file` 可表达引用，发布二进制需要独立文件、RPATH 或旁边资源时再按规则要求使用 copy。 [Buck2 AnalysisActions](https://buck2.build/docs/api/build/AnalysisActions/)

## Linux worker

1. 从 [bb-deployments](https://github.com/buildbarn/bb-deployments) 取固定 SHA。先用原版 hardlinking 示例（P4618 上独立试验目录）验证 scheduler、worker 与 runner，再在当前版本集成 tiered CAS。按 `docker compose -f docker-compose.yml -f /path/to/compose.loopback.override.yaml config` 检查仅 18980 loopback，scheduler 端口不向宿主公布。
2. 用相同 `-f` 参数执行 `up -d frontend storage-0 storage-1 scheduler runner-installer worker-hardlinking-ubuntu22-04 runner-hardlinking-ubuntu22-04`。`buck2-linux-worker.buckconfig` 与 `linux-worker-executor.bzl.example` 对应 `hardlinking`，镜像 digest/平台值跟实际 scheduler 一致。`buck2 build --remote-only --config-file /path/to/buck2-linux-worker.buckconfig //app:target` 证明任务进入 worker。
3. `compose.worker.yaml` 加入 scheduler、runner、worker，worker 通过 Docker 内网向同一个 `cache:8980` 读写 CS/CMS/AC。入口将 `hardlinking` 的 Execute 请求转发给 scheduler。Linux 使用 `buck2-shared-worker.buckconfig` 与既有 `linux-worker-executor.bzl.example`。在 `/opt/z8-kit/buildbarn` 执行 `docker compose -p z8-tiered -f compose.tiered.yaml -f compose.worker.yaml config`。先创建 `/srv/buildbarn/tiered/worker`、`/srv/buildbarn/tiered/runner-bin`，再 `sudo systemctl enable --now z8-buildbarn-worker.service`。测试 RE 在独立 checkout 的真实目标以及按需下载。若当前镜像、runner 或 toolchain 校验失败，停 worker service 并保留本地执行和缓存。I7 按 [CPU 分核手册](../host/CPU-PLACEMENT.md#生成并安装) 把实际执行构建的 runner 放进构建侧 cgroup。
4. 先限制 worker 为 8–12 个物理核、约 32 GiB 的 cgroup 预算，避免推理 staging 被抢占。真正的上限用混合负载验证，按实测节点绑定。

[上游 Docker Compose](https://github.com/buildbarn/bb-deployments/tree/main/docker-compose) · [Buck2 Buildbarn 样例](https://github.com/facebook/buck2/tree/main/examples/remote_execution/buildbarn)
