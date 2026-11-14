# Buck2 与 Buildbarn

## P4618 热层与 HC620 冷层

`/srv/work/z8user/<repo>`、`buck-out`、materializer DB 在 P4618 XFS。Buildbarn 的 AC、CMS、CAS 索引、持久状态和可丢的热读缓存也在 P4618，单独目录限额。HC620 RAIDZ1 的 `/data/buildbarn` 存权威 CS 大块文件。`storage/README.md` 安装 ZFS 和 systemd，挂载准备好后再启动 `z8-buildbarn.service`。

`compose.tiered.yaml` 启动一个 `bb-storage`。初始试配为 512 GiB 冷 CS、64 GiB 热 CS，另有 512 MiB 冷 CS 索引、128 MiB 热索引、4 GiB CMS、2 GiB AC。按典型 blob 数、淘汰、索引冲突和稳态带宽扩容。配置中 `readCaching` 热命中在 P4618；首次冷读从 RAIDZ1 读并回填热缓存，新上传直接写慢 CS。`oldBlocks/currentBlocks/newBlocks` 是同一后端的滚动生命周期，无法把 new 固定在 SSD、old 固定在 HDD。若上传是瓶颈，先用 P4800X 的 dm-zoned 写入路径与 P4618 全闪存基线 A/B；SSD write-back 再下刷需独立的缓冲机制和恢复设计。 [Buildbarn block allocator](https://github.com/buildbarn/bb-storage/blob/main/pkg/proto/configuration/blobstore/blobstore.proto) · [readCaching 实现](https://github.com/buildbarn/bb-storage/blob/main/pkg/blobstore/readcaching/read_caching_blob_access.go)

当前 cold block file 由 ZFS 做盘上压缩。Buildbarn 的切块与拼块是本地后端布局，ByteStream zstd 另控制传输。I5 用真实上传和冷读取对比 [冷 CAS 的 `zstd-3`、`lz4` 与 `off`](../storage/README.md#冷-cas-压缩怎么定)。

镜像里的 `LocalBlobAccess` 在新块内递增分配偏移，旧块轮转后复用偏移。并发写可交错，文件覆写会触发 ZFS CoW。淘汰动作只把逻辑块归还给 Buildbarn 自己的 allocator，文件对应范围仍存在于 ZFS，下一次覆写后旧物理块才有机会释放。冷 CAS 是可重建数据，给这份 dataset 配快照策略时将它排除，避免把轮转后的历史 extent 长期留在池内。现有布局继续用 HC620 放权威冷块，P4618 放热块和元数据。 [固定镜像的块分配实现](https://github.com/buildbarn/bb-storage/blob/ca3d8b4/pkg/blobstore/local/block_device_backed_block_allocator.go) · [backend 配置定义](https://github.com/buildbarn/bb-storage/blob/main/pkg/proto/configuration/blobstore/blobstore.proto)

首次用 `docker compose -f compose.tiered.yaml config --images` 核镜像引用，用 `config` 核绑定。两个 Linux cache 配置以及 scheduler、worker、runner-installer 都固定到原 11 月 2 日标签的 GHCR 镜像索引 digest，标签供查版本。各索引包含 `linux/amd64`。首次启动需看日志确认 schema、文件/目录权限、GetCapabilities 和 CAS/AC 读写。`docker compose -p z8-tiered -f compose.tiered.yaml logs --tail 100` 与 `ss -ltn` 可复核。若镜像拒绝热读包装的 schema，可先把 `tiered-cache.jsonnet` 中的 `chunkStorage` 改为其 `slow` backend，用同一冷块与索引跑通，再在当前版 schema 下恢复热读。 [Buildbarn GHCR 包](https://github.com/buildbarn/bb-storage/pkgs/container/bb-storage) · [Docker digest 引用](https://docs.docker.com/reference/cli/docker/image/pull/#pull-an-image-by-digest-immutable-identifier)

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

容器运行后，用 `sudo docker image inspect <Compose 中的镜像引用> --format '{{json .RepoDigests}}'` 核实际 digest。运行期比较 `stat`、`du -h` 和 `zfs list`，区分块文件的逻辑大小与实际分配。冷 CS、热 CS 的容量值在 `tiered-cache.jsonnet`，索引与块的配置生成在 `disk.libsonnet`。先记录淘汰间隔、日上传量和命中率，再决定是否加大冷 CS。块文件容量与其持久索引相互关联，变更时优先另开空状态目录和新冷块路径跑一轮，避免用变更后的几何直接读取旧状态。

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

### 冷 CAS 读写调优

512 GiB 冷 CS 是 `/data/buildbarn/blocks` 的文件尺寸。Buildbarn 将许多小 blob 放入同一个大文件中的新块，旧块按批次回收。当前 `old/current/new/spare = 8/24/3/3`，每个逻辑块约 13.47 GiB，它负责分配和淘汰。`minChunkSizeBytes=256 KiB` 与 `horizonSizeBytes=2 MiB` 是 CAS 切块参数。ZFS 的 `recordsize=1M` 和盘的 256 MiB zone 各自工作。先保留这几组值。P4618 的 64 GiB 热 CS 对重复读取有用，P4618 上的索引、CMS 和 AC 降低小随机 I/O 延迟。冷 CS `Put` 直接走 ZFS → 七组 dm-zoned → HC620，dm-zoned 可先把写入落到 P4800X。读取进入 old 类的块时，Buildbarn 的刷新可能把 blob 再写一遍，用实测区分刷新、上传和热层回填。 [本地块配置](https://github.com/buildbarn/bb-storage/blob/main/pkg/proto/configuration/blobstore/blobstore.proto) · [read-through 源码](https://github.com/buildbarn/bb-storage/blob/main/pkg/blobstore/readcaching/read_caching_blob_access.go) · [旧对象刷新](https://github.com/buildbarn/bb-storage/blob/main/pkg/blobstore/local/flat_blob_access.go)

1. **上传。** 用一组产生新 digest 的真实目标填入冷库，记录客户端发送字节、构建完成时间、上传耗时和 p95。先测短突发，再继续到旧块淘汰及偏移反复复用阶段。若已采集 Buildbarn 指标，用 cold CS 的 `buildbarn_blobstore_block_device_backed_block_allocator_releases_total` 观察淘汰。用 `dmsetup status` 的 `cache` 空闲下降、回升和 HC620 写入识别回收阶段。对齐时间窗口，比较客户端唯一写入量、`zpool iostat` 的 vdev 写入量和 `iostat` 的实体 HDD/Optane 写入量，记录回收后的稳态带宽和 p99。1,120 GiB 是七段 P4800X 的名义合计，ZFS 压缩、cache 元数据和各盘写入分布会改变实际临界点。 [I4 持续写与覆盖](../storage/README.md#5-i4-验证实际写入scrub-与缺盘)
2. **首次冷读。** 上传后先用未构建过该目标的隔离目录消费同一批产物。先选未回填热 CS 的新 digest，在 `iostat` 核 HC620 确实发生读，再记录 p95 和字节数。新上传的数据可能还在 dm-zoned cache，做盘侧冷读时要先等这些数据确实迁到 HDD。第二个隔离目录消费同样内容，核 P4618 热层回填后的延迟和盘读量。使用实际 Buck2 消费动作强制物化，避免把 AC hit 当成传输了内容。再加一轮 1/2/4 个并行构建，分别记录小文件与大产物。这能区分 seek 排队与吞吐上限。
3. **按瓶颈改一项。** 热层命中低且工作集重复时，试 64→128 GiB。冷读慢时，用独立空 dataset 和成对的冷块/索引比较 1 MiB 与 256 KiB `recordsize`，同时看小对象的读放大、冷写和 ZFS 压缩比。写慢时先对比冷库 `zstd-3`/`lz4` 的 CPU 与盘写量，并测同一任务的 P4618 全闪存基线。若长时间写入已由 HC620 持续落盘决定，额外的 SSD 写缓冲只能延长突发吸收期。所有 A/B 保持同一模型负载、Buck2 目标和 CAS 几何，每个新存储实例用自己的元数据。

现有全闪存样例的 CS 是 64 GiB。要比较 512 GiB 冷层进入反复轮转后的表现，另起测试实例，在 P4618 的空测试目录用同一 512 GiB CS 几何、索引大小和请求回放，先核根 XFS 有足够余量。结果能判断是否值得用 P4618 为写密集项目单独开快速缓存实例。 [逻辑和物理 I/O 统计口径](https://openzfs.github.io/openzfs-docs/man/v2.4/8/zpool-iostat.8.html)

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

先用一个大链接产物分别验证 `--out` 和规则 `LocalCopy`。再从第二个 worktree 请求同一产物，记录 AC 命中、实际 CAS 读取量与两份文件的 FIEMAP。两次 gRPC 物化通常各自产生一份文件，即便服务端只有一个 digest。若确实要在多个 worktree 外共享同一套已构建输出，可以从第一个已物化的输出显式 clone 到 P4618 上的交付目录，并用 `cmp`、`filefrag` 核对。保持各 worktree 的 `buck-out` 由各自 daemon 管理。 [Rust 本地复制的系统调用](https://doc.rust-lang.org/std/fs/fn.copy.html) · [Buck2 Deferred Materialization](https://buck2.build/docs/users/advanced/deferred_materialization/)

## Linux worker

1. 从 [bb-deployments](https://github.com/buildbarn/bb-deployments) 取固定 SHA。先用原版 hardlinking 示例（P4618 上独立试验目录）验证 scheduler、worker 与 runner，再在当前版本集成 tiered CAS。按 `docker compose -f docker-compose.yml -f /path/to/compose.loopback.override.yaml config` 检查仅 18980 loopback，scheduler 端口不向宿主公布。
2. 用相同 `-f` 参数执行 `up -d frontend storage-0 storage-1 scheduler runner-installer worker-hardlinking-ubuntu22-04 runner-hardlinking-ubuntu22-04`。`buck2-linux-worker.buckconfig` 与 `linux-worker-executor.bzl.example` 对应 `hardlinking`，镜像 digest/平台值跟实际 scheduler 一致。`buck2 build --remote-only --config-file /path/to/buck2-linux-worker.buckconfig //app:target` 证明任务进入 worker。
3. `compose.worker.yaml` 加入 scheduler、runner、worker，worker 通过 Docker 内网向同一个 `cache:8980` 读写 CS/CMS/AC。Linux 使用 `buck2-shared-worker.buckconfig` 与既有 `linux-worker-executor.bzl.example`。在 `/opt/z8-kit/buildbarn` 执行 `docker compose -p z8-tiered -f compose.tiered.yaml -f compose.worker.yaml config`，再 `sudo systemctl enable --now z8-buildbarn-worker.service`。服务预建 XFS 上的 `worker/build`、`worker/cache` 与 `runner-bin`，共用 `/run/z8-bb-runner` 上的 socket。runner 启动时清理自己的残留 socket，worker 等 socket 出现再启动。固定镜像的 worker、runner-installer 和 runner 都以 UID 0 启动。用隔离 checkout 验实际 RE、按需下载、worker 停启后 CAS 持续服务。I7 把 runner 放进 [构建侧 cgroup](../host/CPU-PLACEMENT.md#生成并安装)。 [Compose v2.40.3 按服务监控](https://github.com/docker/compose/blob/v2.40.3/pkg/compose/up.go#L177)
4. Runner 的 `cpus: 12` 是 CPU 时间额度，`concurrency: 4` 是初始活动 action 数，共用 `mem_limit: 32g`。若主要跑单线程编译且队列持续拥堵，单独把 `shared-worker.jsonnet` 的 `concurrency` 改为 8 重启 worker。同一批任务比较构建墙钟时间、峰值内存、OOM、推理 TTFT 与 decode。8 档仍有 CPU/内存余量再试 12。并行链接或多线程 rustc 要单独验，32 GiB 是硬限额，超出时任务可被 OOM 中止。

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
