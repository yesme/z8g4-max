# Buck2 与 Buildbarn

## P4618 热层与 HC620 冷层

工作树、`buck-out` 和 materializer DB 在 P4618 XFS。Buildbarn 的 512 GiB 热 CS、64 GiB CMS、216 GiB AC 及各自索引和持久状态也在该卷。HC620 RAIDZ1 的 `/data/buildbarn` 存权威 CS 块文件，P4800X p9 的 `/srv/bbindex` 存冷索引、状态和容量记录。新上传写权威冷 CS，首次冷读回填热 CS。I4 持续写未过线时走全 XFS 回退。 [Buildbarn 读缓存](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/readcaching/read_caching_blob_access.go)

`z8data/buildbarn` 本地设置 `compression=zle`，继承 `primarycache=all`。 [冷 CAS 配置](../storage/README.md#冷-cas-压缩)

### 冷 CS 几何与容量

冷块文件长度取 `z8data/buildbarn` 的 `refreservation`，首装为初始可用量的 55% 向下取整，预计 **41 TiB**。预留配置和后续池用量独立。冷 CS 共 94 块（22 old、66 current、3 new、3 spare），按 41 TiB 算每块约 **447 GiB**，扣 spare 后活跃块最多约 **39.69 TiB**。块尾空隙、尚未写入的区间和重复副本会减少有效容量。冷库排除快照。池的 10% 余量见[容量分配](../storage/README.md#容量分配与余量)。 [Buildbarn 块划分](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/configuration/new_blob_access.go#L199)

冷索引取 p9 XFS 首次可用空间，向下取整到 GiB 再减 8 GiB 留给持久状态和开销。预计约 **520 GiB**，实际以 `/srv/bbindex/cold-layout.json` 为准。对约 41 TiB 冷库相当于约 12.7 GiB/TiB。上游同版本服务端示例是 12.5 GiB/TiB，有公开部署用 16 GiB/TiB。这些是部署配置，本站压缩后的独立 chunk 尺寸分布仍待实际构建获取。 [Buildbarn 同版部署示例](https://github.com/buildbarn/bb-deployments/blob/7cd419f6526ea5d1f25b0803dee32d64f26fbdec/docker-compose/config/storage.jsonnet#L16-L44) · [公开 Bazel 配置](https://github.com/brunostjohn/homelab/blob/5aa1bd23b04cc47c888177d5fe4ea2c39db14724/k8s/bazel-cache/config.yml#L190-L209)

固定版每个索引槽 66 B，实际槽数向下取到质数。当前 CS 每个独立 chunk digest 占一个索引项，同一个 digest 可跨 RE 实例共享。小文件和 RE 目录消息可以直接成为单个 chunk。大对象的分块粒度与 Zstd 编码后实际占用的字节数是两项独立参数。按目标装载率计算的索引字节数为 `活跃块字节 × 66 / (压缩后每个独立 chunk 的平均字节数 × 目标装载率)`。 [索引槽格式](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/block_device_backed_location_record_array.go#L12) · [质数槽数](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/lossymap/configuration.go) · [CS 的键和编码](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/configuration/cs_blob_access_creator.go)

| 平均编码 chunk | 覆盖 39.69 TiB 所需索引（50% 装载） | 520 GiB 索引的覆盖量（50% 装载） |
|---:|---:|---:|
| 16 KiB | 327 GiB | 63.0 TiB |
| 10 KiB | 524 GiB | 39.4 TiB |
| 8 KiB | 655 GiB | 31.5 TiB |
| 5 KiB | 1,048 GiB | 19.7 TiB |

520 GiB 约有 **84.6 亿槽**。50% 是控制探测冲突的预算。平均编码大小约 10 KiB 时，索引大致覆盖活跃容量。5 KiB 时，更早出现淘汰和 lookup miss。达到探测上限时 `Put` 仍可能成功返回，之后同一个 digest 可能 miss，影响缓存命中或后续对象获取。 [碰撞与弃项](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/lossymap/hash_map.go#L132-L206)

XFS 上的索引以 `ftruncate` 创建为稀疏文件，`mmap` 用于读取。散布的键用写系统调用更新，分配以文件系统块为单位，所以实际磁盘占用可能很早就接近逻辑长度。用 `stat -c 'bytes=%s allocated_512B_blocks=%b' /srv/bbindex/key_location_map` 看两者。保留 XFS，将索引、几何和 checkpoint 放在同一文件系统；裸块设备路径同样需要 mmap，还要另找持久状态目录。 [普通文件后端](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blockdevice/new_block_device_from_file_unix.go#L25-L46) · [mmap 与 pwrite](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blockdevice/memory_mapped_block_device_unix.go#L24-L81) · [裸块设备后端](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blockdevice/new_block_device_from_device_linux.go#L25-L47)

max 热层的 512 GiB 配 8 GiB 索引，边缘的 256 GiB 配 4 GiB，全 XFS 回退的 64 GiB 配 1 GiB。统一按每 TiB 16 GiB 配置。以编码后均值 10 KiB、50% 装载率推算，max 旧 1 GiB 索引只覆盖约 78 GiB；这是假定物件分布下的设计点，实际碰撞与读取命中率随工作负载变化。P4618 的 512 GiB 热层、64 GiB CMS、216 GiB AC 和三库合计 16 GiB 索引共约 **808 GiB**。加 128 GiB worker 输入缓存是 **936 GiB**，标称 6.4 TB P4618 约余 **4.91 TiB** 给系统、工作树和 `buck-out`，另扣文件系统元数据。 [Buildbarn 清单格式](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/chunk/mapping.go)

平时排查提前 miss 可在 max 查本机随 `bb-storage` 提供的计数。优先看 `TooManyAttempts` 和 `put_too_many_iterations_total` 持续增加，两者分别捕获探测深度和插入总迭代耗尽。CS 标签汇总 max 的冷热两张表。blob 尺寸直方图使用 digest 的未压缩字节数，且同类型本地 backend 汇总，冷索引占用需按压缩后独立 chunk 计算。 [计数定义](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/lossymap/hash_map.go) · [对象尺寸指标](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/metrics_blob_access.go)

```bash
curl -fsS http://127.0.0.1:9980/metrics |
  awk '/^buildbarn_lossymap_hash_map_put_iterations_count\{/ && /name="KeyLocationMap:cs"/ && /outcome="TooManyAttempts"/ || /^buildbarn_lossymap_hash_map_(put_too_many_iterations|get_too_many_attempts)_total\{/ && /name="KeyLocationMap:cs"/'
```

冷块文件、索引、持久状态与 `/srv/bbindex/cold-layout.json` 使用同一套几何。改变块文件或索引长度需要先停 worker 和 storage，再成套退役可重建的缓存。索引槽数参与哈希取模，直接扩展旧索引会改变查找位置。热 CS 和回退 CS 改索引长度时，也把对应块文件、索引和持久状态作为一组重建。v2.18 的分区变更按新建池处理，旧库使用的 P4618 冷索引和旧 layout 一并退役。保留需要的源数据、工作树和构建配置。 [索引寻址](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/lossymap/hash_map.go)

`LocalBlobAccess` 在新块内递增分配偏移，旧块轮转后复用偏移。并发写可交错，文件覆写触发 ZFS CoW。淘汰只归还 Buildbarn allocator 的偏移，下一次覆写时旧 ZFS 块才有机会释放。 [Buildbarn 逻辑块分配](https://github.com/buildbarn/bb-storage/blob/ca3d8b4/pkg/blobstore/local/block_device_backed_block_allocator.go#L176-L187)

首次用 `sudo docker compose -f compose.tiered.yaml config --images` 核镜像引用，用 `config` 核绑定。两个 Linux cache 配置以及 scheduler、worker、runner-installer 都固定到原 11 月 2 日标签的 GHCR 镜像索引 digest，标签供查版本。各索引包含 `linux/amd64`。首次启动需看日志确认 schema、文件/目录权限、GetCapabilities 和 CAS/AC 读写。`docker compose -p z8-tiered -f compose.tiered.yaml logs --tail 100` 与 `ss -ltn` 可复核。 [Buildbarn GHCR 包](https://github.com/buildbarn/bb-storage/pkgs/container/bb-storage) · [Docker digest 引用](https://docs.docker.com/reference/cli/docker/image/pull/#pull-an-image-by-digest-immutable-identifier)

```bash
cd /opt/z8-kit/buildbarn
sudo docker compose -p z8-tiered -f compose.tiered.yaml config
sudo docker compose -p z8-tiered -f compose.tiered.yaml pull cache
sudo systemctl start z8-buildbarn.service
sudo docker compose -p z8-tiered -f compose.tiered.yaml ps
sudo docker compose -p z8-tiered -f compose.tiered.yaml logs --tail 100 cache
sudo stat /data/buildbarn/blocks /srv/bbindex/key_location_map
sudo ls -ld /srv/bbindex /srv/buildbarn/tiered/{cs-hot,cms,ac}
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
3. max 首装 72 个活动 action、72 CPU 时间额度和 512 GiB 内存上限，无容器 swap。推理时余 80 个逻辑 CPU，给系统、存储和协调进程留 8 个逻辑 CPU 的时间预算。较高并发用于覆盖取输入和 I/O 等待。按 2–4 GiB/action 算，72 个约用 144–288 GiB。worker 等两路 kmem 上线后启动。512 GiB 是 DDR4 与 kmem 的 memcg 总上限，PMem 的 `ZONE_MOVABLE` 可承接多数匿名页及文件页缓存，页表和其他不可移动内核分配仍需 DDR4。约 520 GiB 的 P4800X 冷索引是稀疏 mmap 文件长度，读到的页按需驻留。I7 用每路 Normal 水位、PSI 和实际吞吐验固定配置。kmem 未能上线时，Z8 的存储可以独立提供服务，Linux 客户端按本地应急流程运行。工具链可随 runner 镜像或项目输入提供。改镜像时同步 worker 和 Buck2 的 digest。异构 Linux worker 使用一致的 CPU 目标基线，避免 `-march=native` 与 `-mtune=native`。 [Linux ZONE_MOVABLE](https://docs.kernel.org/admin-guide/mm/memory-hotplug.html#zone-movable)

[上游 Docker Compose](https://github.com/buildbarn/bb-deployments/tree/main/docker-compose) · [Buck2 Buildbarn 样例](https://github.com/facebook/buck2/tree/main/examples/remote_execution/buildbarn)

[mini 与 Mac 的上线命令](EDGE.md)

## 全 XFS 回退

适用于 I4 冷库持续写达不到目标或冷池故障时。停 tiered 服务，改用 P4618 上独立的 64 GiB CAS（1 GiB 索引）和同一 scheduler。I4 已启用的存储单元继续自动导入池、挂载 `/data/other`。按 [I5.1 软件与目录准备](../storage/README.md#i51-软件目录与单元准备) 安装 Docker 和复制配置。回退使用下面的新状态目录，跳过 I5 的 p9 挂载和 tiered 服务启动。完成 [构建侧 cgroup](../host/CPU-PLACEMENT.md#生成并安装)。确认两路 kmem 已上线。使用新存储目录，Buck2 首轮会重新填充缓存。

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
