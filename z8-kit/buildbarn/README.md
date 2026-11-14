# Buck2 与 Buildbarn

## P4618 热层与 HC620 冷层

`/srv/work/jackywang/<repo>`、`buck-out`、materializer DB 在 P4618 XFS。Buildbarn 的 AC、CMS、CAS 索引、持久状态和可丢的热读缓存也在 P4618，单独目录限额。HC620 RAIDZ1 的 `/data/buildbarn` 存权威 CS 大块文件。`storage/README.md` 安装 ZFS 和 systemd，挂载准备好后再启动 `z8-buildbarn.service`。

`compose.tiered.yaml` 启动 max 的 `bb-storage`。首次从空 ZFS 数据集的可用量取 72% 并向下取整到 TiB，预计 **54 TiB 冷 CS**。P4618 放冷 CS 的索引与状态、512 GiB 热 CS、64 GiB CMS 和 216 GiB AC。新上传写权威冷 CS，第一次冷读回填热 CS。I4 未达到持续写门槛时走全 XFS 回退。 [Buildbarn 读缓存源码](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/readcaching/read_caching_blob_access.go)

冷块文件所在的 ZFS 数据集继承 `compression=zstd-3` 和 `primarycache=all`。 [冷 CAS 配置](../storage/README.md#冷-cas-压缩)

### 冷 CS 几何与容量

七盘 RAIDZ1、4 KiB 扇区下，一个未压缩 1 MiB 记录用 256 个数据扇区和 43 个校验扇区，向上补齐为 300 个扇区。ZFS 的 `available` 用 128 KiB 记录的换算比例，并计入 vdev 实际容量与池预留。首次保存的 `/opt/z8-kit/buildbarn/cold-layout.json` 是启动时的容量依据。守卫拒绝用剩余空间重算已有几何。冷库数据集专用且无快照，留约 28% 给写时复制、池分配与 dm-zoned 回收。 [OpenZFS RAIDZ 分配](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/zfs/vdev_raidz.c#L2305) · [OpenZFS 空间换算](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/zfs/vdev.c#L2078)

冷 CS 使用 22 个 old、66 个 current、3 个 new 和 3 个 spare，共 94 块。54 TiB 块文件的单块约 588 GiB。扣三块 spare 后，活跃块字节上限约 52.28 TiB，未填满的新块、块尾空隙和刷新产生的重复副本会再减少独立对象容量。 [Buildbarn 块划分](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/configuration/new_blob_access.go#L199)

**冷索引定为每 TiB 块文件配 26 GiB，预计 1,404 GiB。** 固定版把索引文件按每槽 66 B 换算成槽数，并向下取到最近的质数。当前 CS 每个独立 chunk digest 占一个索引项。同一 digest 在不同 RE 实例间共享。小文件和 RE 目录消息也能直接成为单个 chunk。256 KiB 是大对象的分块参数，压缩后的 chunk 和小对象可以短得多。公式为 `活跃块字节 × 66 / (压缩后每个独立 chunk 的平均字节数 × 0.50)`。Buildbarn 客户端示例使用 5 KiB 与 50%。这里把 5 KiB 作为规划值，P4618 的余量允许按这个值首装。50% 是装载率预算。 [索引槽格式](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/block_device_backed_location_record_array.go#L12) · [质数槽数](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/lossymap/configuration.go) · [CS 的键和编码](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/configuration/cs_blob_access_creator.go) · [上游估算示例](https://github.com/buildbarn/bb-clientd/blob/main/configs/bb_clientd.jsonnet)

作为量级参照，上游 Docker Compose 示例为 32 GiB CS 配 400 MiB 索引，折合每 TiB 12.5 GiB。原方案的每 TiB 1 GiB 比这个比例小 12.5 倍。 [Buildbarn Docker Compose 配置](https://github.com/buildbarn/bb-deployments/blob/main/docker-compose/config/storage.jsonnet)

| 平均编码 chunk | 覆盖 52.28 TiB 所需索引（50% 装载） | 旧 54 GiB 索引到 50% 时对应的数据量 |
|---:|---:|---:|
| 128 KiB | 54 GiB | 52.4 TiB |
| 32 KiB | 216 GiB | 13.1 TiB |
| 16 KiB | 431 GiB | 6.5 TiB |
| 8 KiB | 863 GiB | 3.3 TiB |
| 5 KiB | 1,380 GiB | 2.0 TiB |
| 4 KiB | 1,725 GiB | 1.6 TiB |

1,404 GiB 约有 228 亿槽。5 KiB 时满库预计占 49.1%，4 KiB 时约 61.4%。索引按新旧位置处理碰撞，旧条目可能被挤出。达到探测上限时 `Put` 仍可返回成功，随后按 digest 查找可能 miss，即使数据块还在。索引和块文件都由 `ftruncate` 建为稀疏文件再 `mmap`，只触及所需页面。索引条目散写到整个文件，底层以文件系统块分配，活跃键只占少数槽时也可能分配大量磁盘空间。热页由系统页缓存管理。P4618 按整个索引文件预算。 [碰撞与弃项](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/lossymap/hash_map.go) · [文件创建](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blockdevice/new_block_device_from_file_unix.go#L38) · [读取映射与写入路径](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blockdevice/memory_mapped_block_device_unix.go)

连同 512 GiB 热 CS、CMS、AC 和各自索引，P4618 文件预算约 **2,205 GiB**。加 128 GiB worker 输入缓存后约 **2.28 TiB**，标称 6.4 TB 的 P4618 还余约 **3.54 TiB** 给系统、工作树和 `buck-out`，未扣 XFS 元数据。CMS 容量另按多 chunk 对象的清单估计，每个 SHA-256 清单项 36 B。I4 的 512 GiB 覆写验回收链和写入门槛。 [Buildbarn 清单格式](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/chunk/mapping.go)

平时排查提前 miss 可在 max 查本机随 `bb-storage` 提供的计数。优先看 `TooManyAttempts` 和 `put_too_many_iterations_total` 持续增加，两者分别捕获探测深度和插入总迭代耗尽。CS 标签汇总 max 的冷热两张表。blob 尺寸直方图使用 digest 的未压缩字节数，且同类型本地 backend 汇总，冷索引占用需按压缩后独立 chunk 计算。 [计数定义](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/lossymap/hash_map.go) · [对象尺寸指标](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/metrics_blob_access.go)

```bash
curl -fsS http://127.0.0.1:9980/metrics |
  awk '/^buildbarn_lossymap_hash_map_put_iterations_count\{/ && /name="KeyLocationMap:cs"/ && /outcome="TooManyAttempts"/ || /^buildbarn_lossymap_hash_map_(put_too_many_iterations|get_too_many_attempts)_total\{/ && /name="KeyLocationMap:cs"/'
```

已初始化的 `cold-layout.json` 沿用保存的 `indexGib`。旧版只有 `tib` 的文件继续对应原来每 TiB 1 GiB 的索引。槽数参与哈希取模，直接放大原文件会使旧键按错误地址查找。已经存过数据时，要采用新比例，先停 worker 和存储，将冷块文件、P4618 的 `cs`、`cs-hot`、`cms`、`ac` 与旧 layout 作为一组退役。核对这些路径仅含可重建缓存，释放旧冷块占用后按 I5 新建空目录。源代码、工作树和 worker 目录无需迁动。 [索引寻址实现](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/lossymap/hash_map.go)

镜像里的 `LocalBlobAccess` 在新块内递增分配偏移，旧块轮转后复用偏移。并发写可交错，文件覆写会触发 ZFS CoW。淘汰动作只把逻辑块归还给 Buildbarn 自己的 allocator，文件对应范围仍存在于 ZFS，下一次覆写后旧物理块才有机会释放。冷 CAS 是可重建数据，给这份 dataset 配快照策略时将它排除，避免把轮转后的历史 extent 长期留在池内。现有布局继续用 HC620 放权威冷块，P4618 放热块和元数据。 [固定镜像的块分配实现](https://github.com/buildbarn/bb-storage/blob/ca3d8b4/pkg/blobstore/local/block_device_backed_block_allocator.go) · [backend 配置定义](https://github.com/buildbarn/bb-storage/blob/main/pkg/proto/configuration/blobstore/blobstore.proto)

首次用 `sudo docker compose -f compose.tiered.yaml config --images` 核镜像引用，用 `config` 核绑定。两个 Linux cache 配置以及 scheduler、worker、runner-installer 都固定到原 11 月 2 日标签的 GHCR 镜像索引 digest，标签供查版本。各索引包含 `linux/amd64`。首次启动需看日志确认 schema、文件/目录权限、GetCapabilities 和 CAS/AC 读写。`docker compose -p z8-tiered -f compose.tiered.yaml logs --tail 100` 与 `ss -ltn` 可复核。 [Buildbarn GHCR 包](https://github.com/buildbarn/bb-storage/pkgs/container/bb-storage) · [Docker digest 引用](https://docs.docker.com/reference/cli/docker/image/pull/#pull-an-image-by-digest-immutable-identifier)

```bash
cd /opt/z8-kit/buildbarn
sudo docker compose -p z8-tiered -f compose.tiered.yaml config
sudo docker compose -p z8-tiered -f compose.tiered.yaml pull cache
sudo systemctl start z8-buildbarn.service
sudo docker compose -p z8-tiered -f compose.tiered.yaml ps
sudo docker compose -p z8-tiered -f compose.tiered.yaml logs --tail 100 cache
sudo stat /data/buildbarn/blocks /srv/buildbarn/tiered/cs/key_location_map
sudo ls -ld /srv/buildbarn/tiered/{cs,cs-hot,cms,ac}
```

容器启动后用 `stat`、`du -h` 和 `zfs list` 核块文件逻辑尺寸与实际分配。已配置的容量和索引几何随空库一起确定。后续改几何时按上面的空库流程处理。

全闪存 `compose.yaml` 用于冷库回退。切换时先停 tiered service，两个配置都监听 8980，各用自己的索引与状态目录。

## Buck2 客户端

**max 提供权威 AC/CAS 和唯一调度器。** Linux、Darwin 客户端都用本机端口 8980。mini 与 Mac 的读缓存、worker 和 SSH 隧道按 [边缘节点手册](EDGE.md) 安装。 [Buildbarn 本地块存储](https://github.com/buildbarn/bb-storage/blob/main/README.md)

Linux 项目在已注册的 execution platform 中接入 `linux-worker-executor.bzl.example`，约束须匹配真实工具链和 runner 镜像。使用 `hardlinking` 实例，客户端上传输入、worker 写入结果。max 的 worker 停机但存储在线时，max 可用 `buck2-linux.buckconfig` 在本机执行，并把结果写入独立的 `linux-x86_64` 实例。离线应急用项目原生 execution platform，加 `--local-only --no-remote-cache`。 [Buck2 RE 配置](https://buck2.build/docs/users/remote_execution/) · [CommandExecutorConfig](https://buck2.build/docs/api/build/CommandExecutorConfig/) · [Buck2 延迟物化](https://buck2.build/docs/users/advanced/deferred_materialization/)

Buck2 自带 Deferred Materialization，RE 产物在本地 action 需要时才拉。可合并 `buck2-deferred.buckconfig.example`，让 materializer 用 SQLite 持久化本地状态。普通 shell 对任意文件路径读取不会触发该机制。显式需要的目标先经 Buck2 构建/运行。开源 RE 后端的 TTL 刷新有限，冷 CAS 淘汰后可能需要重构；保持 completeness checking，并测试延迟拉取后再旋转冷块。 [Buck2 Deferred Materialization](https://buck2.build/docs/users/advanced/deferred_materialization/)

### 验证 Linux 缓存

I4 的覆盖脚本已验 dm-zoned 回收，I5 只走真实 Buck2 路径。在工作树 A 远程构建产生新 digest 的目标，确认 worker 写入结果；从干净工作树 B 读取同一产物，首次取回填热层。仅需核一次实际物化和热层读，AC hit 单独不足以证明下载。用 `zpool iostat -v z8data 2` 和 `iostat -xz 2` 核实际设备活动。 [I4 持续写与覆盖](../storage/README.md#5-i4-验证实际写入scrub-与缺盘)

在 Linux 工作树 A 和同一提交的干净工作树 B 各执行一次下列命令，替换项目目标标签。分别保存两次的 log，检查缓存查询、AC 命中和 worker 的实际执行记录。

```bash
cfg=/opt/z8-kit/buildbarn/buck2-shared-worker.buckconfig
target=//app:target
buck2 build --remote-only --config-file "$cfg" "$target"
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

1. I5 先启用本机 CAS，再启用 Linux worker。
2. `compose.worker.yaml` 加入 scheduler、runner、worker，worker 通过 Docker 内网向同一个 `cache:8980` 读写 CS/CMS/AC。Linux 使用 `buck2-shared-worker.buckconfig` 与既有 `linux-worker-executor.bzl.example`。在 `/opt/z8-kit/buildbarn` 执行 `docker compose -p z8-tiered -f compose.tiered.yaml -f compose.worker.yaml config`，再 `sudo systemctl enable --now z8-buildbarn-worker.service`。服务预建 XFS 上的 `worker/build`、`worker/cache` 与 `runner-bin`，共用 `/run/z8-bb-runner` 上的 socket。runner 启动时清理自己的残留 socket，worker 等 socket 出现再启动。固定镜像的 worker、runner-installer 和 runner 都以 UID 0 启动。用隔离 checkout 验实际 RE、按需下载、worker 停启后 CAS 持续服务。启服务前配置 [构建侧 cgroup](../host/CPU-PLACEMENT.md#生成并安装)。 [Compose v2.40.3 按服务监控](https://github.com/docker/compose/blob/v2.40.3/pkg/compose/up.go#L177)
3. max 首装 72 个活动 action、72 CPU 时间额度和 512 GiB 内存上限，无容器 swap。推理时余 80 个逻辑 CPU，给系统、存储和协调进程留 8 个逻辑 CPU 的时间预算。HT 共享每核执行资源；较高并发用于吸收编译、链接和 I/O 等待的差异。按 2–4 GiB/action 算，72 个约用 144–288 GiB。512 GiB 是总上限，DDR4 紧张时由约 1 TiB 的 kmem 承接，worker 等两路 kmem 上线后启动。kmem 与 DDR4 都计入 memcg，局部节点耗尽和单动作超限仍可能造成失败。I7 验固定配置是否可上线，仅在发生重大故障或性能问题时改配置。kmem 未能上线时，Z8 的存储可以独立提供服务，Linux 客户端按本地应急流程运行。工具链可随 runner 镜像或项目输入提供；改镜像时同步 worker 和 Buck2 的 digest。异构 Linux worker 使用一致的 CPU 目标基线，避免 `-march=native` 与 `-mtune=native`。

[上游 Docker Compose](https://github.com/buildbarn/bb-deployments/tree/main/docker-compose) · [Buck2 Buildbarn 样例](https://github.com/facebook/buck2/tree/main/examples/remote_execution/buildbarn)

[mini 与 Mac 的上线命令](EDGE.md)

## 全 XFS 回退

适用于 I4 冷库持续写达不到目标或冷池故障时。停 tiered 服务，改用 P4618 上独立的 64 GiB CAS 和同一 scheduler。按 [I5 准备过程](../storage/README.md#6-i5-交给-buildbarn) 安装 Docker 和复制配置，并完成 [构建侧 cgroup](../host/CPU-PLACEMENT.md#生成并安装)。确认两路 kmem 已上线。使用新存储目录，Buck2 首轮会重新填充缓存。

```bash
sudo systemctl disable --now z8-buildbarn-worker.service z8-buildbarn.service
cd /opt/z8-kit/buildbarn
export BB_DATA_DIR=/srv/buildbarn/cache-xfs
sudo install -d -m 0750 "$BB_DATA_DIR"/{cs,cms,ac}/persistent_state
sudo install -d -m 0750 "$BB_DATA_DIR"/{worker/build,worker/cache,runner-bin}
sudo install -d -m 0750 /run/z8-bb-runner
test "$(findmnt -n -T "$BB_DATA_DIR" -o FSTYPE)" = xfs || exit 1
systemctl is-active --quiet z8-pmem-kmem.service || exit 1
sudo env BB_DATA_DIR="$BB_DATA_DIR" docker compose -p z8-xfs \
    -f compose.yaml -f compose.fallback-farm.yaml -f compose.worker.yaml \
    -f compose.cpu-layout.yaml up -d
ss -ltn 'sport = :8980'
```

使用同一个农场 buckconfig 验远程执行。该回退为手工恢复；重启后需重建 `/run/z8-bb-runner` 再执行。回到 tiered 前用同一组 Compose 文件、项目名和目录环境执行 `down`，再启两项原 systemd 服务。
