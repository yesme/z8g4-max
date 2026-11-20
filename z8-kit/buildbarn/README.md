# Buck2 与 Buildbarn

## P4618 热层与 HC620 冷层

P4618 XFS 存工作树、`buck-out`、materializer DB、Buildbarn 热 CS、CMS、AC 和 32 个冷分片 checkpoint。热 CS 的 26 GiB 索引放在 PMem 模型卷上，经 DAX 直接访问。SATA0–3 上的 dm-zoned 设备承载权威冷 CS，D4800X p5 提供裸索引。上传先写权威冷库，首次冷读回填热 CS。SATA4–6 的 ZFS 专供一般数据。 [Buildbarn 读缓存](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/readcaching/read_caching_blob_access.go)

### 冷 CS 几何与容量

| 组件 | 每分片 | 合计 |
|---|---:|---:|
| 冷数据 dm-linear | 6,510 个 256 MiB 区，1,747,514,818,560 B | 32 片约 50.86 TiB |
| 冷索引 dm-linear | 26.5 GiB，最多约 4.31 亿个 66 B 槽 | 848 GiB，约 16.65 GiB/TiB |
| 分片块 | old 与 current 共 87 块，同盘八片从 14 / 73 到 28 / 59 错开；3 new、3 spare | 每块 17.5 GiB，扣 spare 后约 49.22 TiB |
| 持久状态 | `/srv/buildbarn/tiered/cold/sataN-S/persistent_state` | P4618 上 32 个独立目录 |

初始按约 10 KiB 编码均值估算，投入活跃块后索引装载约 38%，约 7.7 KiB 时达 50%。按全部几何算则分别约 40% 和 7.9 KiB。质数取整使实际槽数略少。读取走 mmap，索引关闭块设备预读，66 B 更新走缓冲 pwrite。旧记录以 epoch、块引用与摘要过滤；重建先清零索引，再清对应 checkpoint。 [块计算](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/configuration/new_blob_access.go#L189-L210) · [索引格式](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/block_device_backed_location_record_array.go#L12-L95) · [裸设备打开](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blockdevice/new_block_device_from_device_linux.go#L22-L47)

三个 new block 按 4:2:1 的分配次数推进，分散同一批对象的老化。old 块查到的对象会复制保活，查缺走冷层。每块恰好 70 个区，轮转区边界不跨块。写到一半、空闲回收或随机覆盖仍可能触发 dm-zoned 合并。 [Buildbarn 分配权重](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/old_current_new_location_blob_map.go#L263-L273)

### 冷库只写三个 new 块

**max 的缓存跑带一处补丁的 bb-storage，每片任何时候都只写 3 个 new 块，每盘 24 个追加位置。** 上游的 CS 在 current 块不足时把缺的全部开成可写块，每片最多 68 个，八片同盘是 544 个。dm-zoned 上每个追加位置占一个没写满的缓存区，每盘只有 92 个可用。上游这样做的三种情况：

| 情况 | 上游每片的可写块 | 补丁后 |
|---|---:|---:|
| 空库首次填库，持续到写满前 65 个块 | 68 | 3 |
| 填库中途重启，例如已有 30 个块 | 再开 38 个，共 41 | 3 |
| 第 51 个块校验失败，释放 22 个 old 和 29 个 current | 再开 29 个，共 32 | 3 |

首装 I4 在同一批已写窗口比较逐窗与 24 路覆盖，按含回收时间的吞吐判定。[I4 操作和日志字段](../storage/README.md#冷库连续覆写)

补丁后 current 块随 new 块写满逐个增加。库填满后两种策略给出相同的判断，轮转方式不变。 [上游的增长策略](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/block_list_growth_policy.go#L11-L38) · [上游的理由](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/old_current_new_location_blob_map.go#L86-L92) · [补丁](storage-sequential-fill.patch) · [取舍记录](../../discussion/cold-cas-sequential-fill.md)

代价是首批对象不再均匀撒进 65 个 current 块。同一时期上传的对象落在相邻的块里，一起变成 old，被查到时集中复制保活，每次复制是一次 HDD 随机读。总的复制量不变。库填满后上游也只写 3 个 new 块，所以多出来的只是首次填库那一批。

**同盘八片的 old 错开，把集中的保活摊开。** 片 `sataN-K` 的 old 取 `14 + 2K`，current 取 `87 − old`，每片的总块数和追加位置不变。一批对象在各片同时落进 new 块，在每片要等后面再排进 `current` 个块才变老，所以它在同盘八片里变老的时刻依次相差两次轮转。仿真里一次构建最多要复制这批对象的比例从 57% 降到约 7%，对首批和之后的每一批都有效。 [几种摊平做法的仿真](../../discussion/cold-cas-spread-options.md#错开-old)

- **代价**：`K = 0` 的片 old 只有 14 块，保活窗口最短。隔很久才被查到一次的对象在那片先被淘汰，连带整条 AC 记录失效。
- **以后可以调**：持久状态只记每个块的位置和写入偏移，old 与 current 的划分每次启动时按配置重算。只要每片仍是 93 块，改这组数不需要重建冷库。这一点按源码判断，没有实测。 [持久状态的内容](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/proto/blobstore/local/local.proto) · [启动时的划分](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blobstore/local/old_current_new_location_blob_map.go#L151-L173)

镜像 `z8/bb-storage:ca3d8b4-sequential-fill` 由 `Dockerfile.storage` 在本机构建，只有 `compose.tiered.yaml` 使用。全 XFS 回退和边缘节点没有 dm-zoned，沿用上游镜像。构建步骤：

1. 取固定提交 `ca3d8b49a5`。
2. 套用上游 Bazel 构建给三个 Go 依赖打的补丁，补丁文件取自同一提交的 `patches/`。直接 `go build` 缺了 bytestream 那个会编译失败。 [上游的依赖补丁清单](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/MODULE.bazel#L99-L128)
3. 套用 `storage-sequential-fill.patch`，运行 `storage-sequential-fill_test.go`，通过后才编译。测试用每盘中间那片的 22/65/3 几何核对上表的每一行，确认上游策略仍是表中的行为，并对八种 old 与 current 的划分逐一核对首次填库和重启。

升级 bb-storage 时改 `Dockerfile.storage` 的提交与基础镜像、`compose.tiered.yaml` 的标签。上游 `patches/` 目录有增减时，构建会在套依赖补丁之前停下，对照 `MODULE.bazel` 的 `module_override` 重新核对三行 `dep`。`TestUpstreamFirstFillOpensEveryCurrentBlock` 失败说明上游改了首次填库的行为，先重新评估补丁是否还需要。

P4618 按热 CS **1,638 GiB**、CMS 64 GiB、AC 216 GiB、AC 与 CMS 两份索引合计 8 GiB、worker 输入缓存 128 GiB 预算，合计 **2,054 GiB**。标称 6.4 TB 约余 **3.81 TiB** 给系统、工作树和 `buck-out`，另扣 XFS 元数据。热 CS 的 26 GiB 索引在 PMem 模型卷。边缘的热 CS 保持 256 GiB 配 4 GiB 索引；全 XFS 回退保持 64 GiB 配 1 GiB 索引。

排查过早淘汰时在 max 看 `TooManyAttempts` 和 `put_too_many_iterations_total`。CS 标签汇总冷热层，编码后独立 chunk 大小和 blob 上报的未压缩大小分别计量。 [计数定义](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/lossymap/hash_map.go)

```bash
curl -fsS http://127.0.0.1:9980/metrics |
    awk '/^buildbarn_lossymap_hash_map_put_iterations_count\{/ && /name="KeyLocationMap:cs"/ && /outcome="TooManyAttempts"/ || /^buildbarn_lossymap_hash_map_(put_too_many_iterations|get_too_many_attempts)_total\{/ && /name="KeyLocationMap:cs"/'
```

首次按 [I5 软件与目录准备](../storage/README.md#i51-软件目录与单元准备)装镜像与服务后，执行：

```bash
cd /opt/z8-kit/buildbarn
sudo z8-buildbarn-check
sudo docker compose -p z8-tiered -f compose.tiered.yaml -f /run/z8-cold/compose.json config --quiet
sudo systemctl start z8-buildbarn.service
sudo docker compose -p z8-tiered -f compose.tiered.yaml logs --tail 100 cache
sudo cat /run/z8-cold/cold-layout.json
```

确认 cache 成功打开本轮授权的设备，检查 GetCapabilities、冷 CAS 上传/读取、CMS 拆分和 AC 命中。健康时 32 个分片和 64 个裸设备。少一块冷盘时 24 个分片和 48 个设备，已有对象可能未命中。I4 持续写未过线或全部冷盘不可用时用[全 XFS 回退](#全-xfs-回退)。

### 热 CS 索引的位置

热 CS 的 `key_location_map` 默认在 `/srv/pmem-model/bb-hot-index`，容器内固定为 `/hot-index`。bb-storage 读走 mmap、写走 `pwrite`，放在 XFS DAX 上后读写都直达 PMem，不占页缓存。Linux 7.0 的 XFS 对 DAX 写和缓冲写取同一把独占 `XFS_IOLOCK_EXCL`，迁移不新增锁竞争。每条记录带校验和并按 epoch 过滤，掉电语义不变。AC 和 CMS 的索引仍在各自的 P4618 目录。 [分层依据](../host/TIERING.md#pmem-的三种用途) · [bb-storage 读写路径](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blockdevice/memory_mapped_block_device_unix.go) · [XFS DAX 写](https://github.com/torvalds/linux/blob/v7.0/fs/xfs/xfs_file.c#L950-L1010)

索引重置时 bb-storage 把文件截断再拉长，成为稀疏文件。目录上的 2 MiB extent 提示让后续分配保持对齐，启动守卫会检查该提示和 `dax=always`。`z8-buildbarn.service` 排在 `z8-pmem-model.service` 之后启动，并用 `PartOf=` 跟随它停止和重启：cache 映射着卷上的索引，停模型卷时先停 cache 和 worker，卸载才不会报 busy。对模型卷先 `stop` 再 `start` 后，要手动 `sudo systemctl start z8-buildbarn.service z8-buildbarn-worker.service`；用 `restart` 时两者自动跟着重启。默认路径必须位于已挂载的 PMem XFS DAX 上。模型卷缺席时守卫拒绝启动；按下方步骤显式指定 P4618 的 `cs-hot-index` 才可回退。首次上线后核对索引未进页缓存：

```bash
sudo xfs_io -r -c 'statx -r' /srv/pmem-model/bb-hot-index/key_location_map | grep -E 'stat.attributes|stat.size'
sudo fincore /srv/pmem-model/bb-hot-index/key_location_map
df -h /srv/pmem-model
```

`fincore` 的 `RES` 应为 0。热 CS 的块、索引和 checkpoint 是一套：索引换位置、从旧版本迁移或 PMem 重建后，三者一起退役，守卫拒绝只剩其一或遗留在 `cs-hot` 目录的旧索引。

```bash
sudo systemctl stop z8-buildbarn-worker.service z8-buildbarn.service
sudo mv -T /srv/buildbarn/tiered/cs-hot "/srv/buildbarn/tiered/cs-hot.retired.$(date +%s)"
sudo install -d -m 0755 /srv/buildbarn/tiered/cs-hot/persistent_state
sudo rm -f -- /srv/pmem-model/bb-hot-index/key_location_map
```

取 I5 基线或 PMem 不可用时，把索引放回 P4618。先按上面的命令退役热 CS，再给服务加覆盖并启动。手动运行 `z8-buildbarn-check` 或 `docker compose` 时带同一个变量。

```bash
sudo install -d -m 0755 /srv/buildbarn/tiered/cs-hot-index
sudo systemctl edit z8-buildbarn.service
```

```ini
[Service]
Environment=BB_HOT_INDEX_DIR=/srv/buildbarn/tiered/cs-hot-index
```

回到 PMem 时删除该覆盖和 `cs-hot-index` 里的旧索引，再退役一次热 CS。

### 冷分片恢复与 CMS

按 [存储换盘步骤](../storage/README.md#缺盘停机恢复)停 worker 和 cache，再运行 `z8-cold reset sataN` 重建该盘八片，同时重置各自的索引与 checkpoint。`cold-layout.json` 可从 FIT 恢复，但旧 checkpoint 只可随原数据与索引一起使用。P4618 热 CS 和 AC 可保留。重建冷分片后退役 max CMS，同一清单可能引用多个分片的 chunk，旧 `SplitBlob` 能直接返回已失效清单。

```bash
sudo systemctl stop z8-buildbarn-worker.service z8-buildbarn.service
sudo mv -T /srv/buildbarn/tiered/cms "/srv/buildbarn/tiered/cms.retired.$(date +%s)"
sudo install -d -m 0755 /srv/buildbarn/tiered/cms/persistent_state
```

先让 mini、Mac 按[边缘 CMS 恢复](EDGE.md#权威冷库重建后的边缘-cms)各自清空清单缓存，再恢复服务。只改变分片可用性时，保留已接盘的索引和 checkpoint。max 的启动守卫会在有效分片名单变化时自动退役 CMS；mini 和 Mac 在降级和恢复全量后各自退役一次 CMS 再连接。更换一块盘但分片键集合未变时仍要按上面的步骤手工退役。v2.20 迁移到新热层几何时，像 CMS 一样把旧 `cs-hot` 目录整套退役并重建 `cs-hot/persistent_state`。核对无复用需要后删除退役目录释放空间。

## 调度器的 Buck2 平台兼容

固定版 Buildbarn 只读 `Action.platform`。2026-11-15 的官方 Buck2 发布版 `5b3b13d` 仍把属性写入 `Command.platform`，Docker 对照实测在 `hardlinking` 上返回 `platform {}`。max 只重建调度器。它优先使用 `Action.platform`，空时用当前分块 CAS 的 Command reader 获取旧字段；worker、存储、三台官方 Buck2 与平台约束沿用原配置。同一条 `--remote-only` Linux 工单换用兼容调度器后成功执行，并拉回了结果。由 [I5 软件准备](../storage/README.md#i51-软件目录与单元准备)构建后，`docker compose` 使用本机的 `z8/bb-scheduler:c9ba98c-command-platform`。Go 代理受限时，可向 `docker compose build` 传 `--build-arg GOPROXY=…` 使用你信任的代理。构建时还套用上游 Bazel 构建给 go-grpc-prometheus 打的补丁，补丁取自这个提交所依赖的 bb-storage 模块；不套的话 gRPC 客户端流式调用的完成计数不准，调度本身不受影响。升级固定提交时，上游的 Go 模块补丁清单有变化，构建会在套补丁之前停下。 [上游的依赖补丁清单](https://github.com/buildbarn/bb-remote-execution/blob/c9ba98cf52456c400278f45a9679635daa40dcd2/MODULE.bazel#L94-L116)上游 Buck2 发版支持 Action 平台后，再用官方调度器回归同一 Linux 和 Darwin 工单。 [Buck2 Action 和 Command 源码](https://github.com/facebook/buck2/blob/5b3b13d3eacefe325bf971369197e33c5f4b3968/app/buck2_execute/src/execute/command_executor.rs#L340-L421) · [Buildbarn 删除回退的提交](https://github.com/buildbarn/bb-remote-execution/commit/ca42a43) · [Buck2 issue #1477](https://github.com/facebook/buck2/issues/1477)

## Buck2 客户端

**max 提供权威 AC/CAS 和唯一调度器。** Linux、Darwin 客户端都用本机端口 8980。mini 与 Mac 的读缓存、worker 和 SSH 隧道按 [边缘节点手册](EDGE.md) 安装。 [Buildbarn 本地块存储](https://github.com/buildbarn/bb-storage/blob/main/README.md)

先执行 `buck2 --version`，记录三台的官方版本。需要安装时从官方 2026-11-15 发布页下载对应平台的 `.zst`，x86_64 Linux 选 `buck2-x86_64-unknown-linux-gnu.zst`，M4 选 `buck2-aarch64-apple-darwin.zst`。使用 `zstd -d` 解压，将可执行文件命名为 `buck2` 放入 `~/.local/bin` 并设为 0755。 [官方发布资产](https://github.com/facebook/buck2/releases/tag/2026-11-15)

Linux 项目在已注册的 execution platform 中接入 `linux-worker-executor.bzl.example`，约束须匹配真实工具链和 runner 镜像。使用 `hardlinking` 实例，客户端上传输入、worker 写入结果。max 的 worker 停机但存储在线时，max 本机构建也需上传时，用项目的本地 execution platform。在该工作树的 `.buckconfig.local` 合入 `buck2-linux.buckconfig` 的值，使 `instance_name` 临时为 `linux-x86_64`，确认项目本地规则允许上传，并运行 `buck2 kill` 后执行 `buck2 build --local-only 目标标签`。恢复农场时移除该工作树的本地覆盖，再 `buck2 kill`。离线应急用项目原生 execution platform，加 `--local-only --no-remote-cache`。 [Buck2 RE 配置](https://buck2.build/docs/users/remote_execution/) · [CommandExecutorConfig](https://buck2.build/docs/api/build/CommandExecutorConfig/) · [Buck2 延迟物化](https://buck2.build/docs/users/advanced/deferred_materialization/)

Buck2 自带 Deferred Materialization，RE 产物在本地 action 需要时才拉。可合并 `buck2-deferred.buckconfig.example`，让 materializer 用 SQLite 持久化本地状态。普通 shell 对任意文件路径读取不会触发该机制。显式需要的目标先经 Buck2 构建/运行。开源 RE 后端的 TTL 刷新有限，冷 CAS 淘汰后可能需要重构；保持 completeness checking，并测试延迟拉取后再旋转冷块。 [Buck2 Deferred Materialization](https://buck2.build/docs/users/advanced/deferred_materialization/)

### 装进 daemon 读取的配置

`[buck2_re_client]` 由 daemon 启动时从磁盘配置读取。三台专用构建节点用同一份 `buck2-shared-worker.buckconfig`。先填 `macos_xcode`，同步到各节点，然后在 `z8-kit/buildbarn` 执行。已有其它项目用独立 RE 服务时，可改为把同样内容合并到此项目的 `.buckconfig.local`，并保留它原有配置。

```bash
mkdir -p "$HOME/.buckconfig.d"
install -m 0644 buck2-shared-worker.buckconfig "$HOME/.buckconfig.d/80-z8-farm.buckconfig"
# 切到实际项目目录后重建它的 daemon
buck2 kill
```

[Buck2 daemon 读取无命令行覆盖的配置](https://github.com/facebook/buck2/blob/5b3b13d3eacefe325bf971369197e33c5f4b3968/app/buck2_server/src/daemon/state.rs#L467) · [Buck2 官方 RE 设置](https://buck2.build/docs/users/remote_execution/#re-configuration-in-buckconfig)

### 验证 Linux 缓存

I4 的覆盖脚本已验 dm-zoned 回收，I5 只走真实 Buck2 路径。在工作树 A 远程构建产生新 digest 的目标，确认 worker 写入结果；从干净工作树 B 读取同一产物，首次取回填热层。仅需核一次实际物化和热层读，AC hit 单独不足以证明下载。主方案另开终端用 `bash host/run-step.sh i5-cold-watermark`（从 `z8-kit` 根）采四盘最小空闲 cache 区数，配合 `iostat -xz 2` 核 I/O。全 XFS 回退用 `iostat -xz 2` 观察 P4618。 [I4 持续写与覆盖](../storage/README.md#冷库连续覆写)

在 Linux 工作树 A 和同一提交的干净工作树 B 各执行一次下列命令，替换项目目标标签。分别保存两次的 log，检查缓存查询、AC 命中和 worker 的实际执行记录。

```bash
target=//app:target
buck2 build --remote-only "$target"
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
xfs_info "$(findmnt -n -T /srv/work/jackywang -o TARGET)"
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
(
    set -e
    src=$(buck2 build -M all --show-full-simple-output "$target")
    test -f "$src"
    outdir=$(mktemp -d /srv/work/jackywang/.buck2-reflink.XXXXXX)
    cp --reflink=always --preserve=mode -- "$src" "$outdir/export"
    filefrag -sv "$src" "$outdir/export"
)
```

## Linux worker

1. I5 先启用本机 CAS，再启用 Linux worker。
2. `compose.worker.yaml` 加入 scheduler、runner、worker，cache 保留 TCP 8980 给 Buck2 客户端和边缘隧道，同时监听 `/run/bb-cache/cache.sock`。`z8-buildbarn.service` 维护宿主目录 `/run/z8-bb-cache`，scheduler 和 worker 只读挂入该目录，经这个 UNIX socket 读写 CS/CMS/AC，绕开 veth 和 netfilter。scheduler 的 8982 仍只在 Docker 内网。runner 的 `/tmp` 是计入其内存上限的 32 GiB tmpfs，硬编码写 `/tmp` 的工具不再落到 overlay2。Linux 使用 `buck2-shared-worker.buckconfig` 与既有 `linux-worker-executor.bzl.example`。在 `/opt/z8-kit/buildbarn` 执行 `sudo docker compose -p z8-tiered -f compose.tiered.yaml -f compose.worker.yaml config`，再 `sudo systemctl enable --now z8-buildbarn-worker.service`。服务预建 XFS 上的 `worker/build`、`worker/cache` 与 `runner-bin`，共用 `/run/z8-bb-runner` 上的 socket。runner 启动时清理自己的残留 socket，worker 等 socket 出现再启动。固定镜像的 worker、runner-installer 和 runner 都以 UID 0 启动。用隔离 checkout 验实际 RE、按需下载、worker 停启后 CAS 持续服务。单独维护 Linux runner 时用同一 Compose 项目 `stop worker runner`，让 scheduler 继续服务；停止整套 worker 单元会连 scheduler 一起停，边缘读缓存的 CDC 参数只短期有效。启服务前配置 [构建侧 cgroup](../host/CPU-PLACEMENT.md#生成并安装)。 [Compose v2.40.3 按服务监控](https://github.com/docker/compose/blob/v2.40.3/pkg/compose/up.go#L177)
3. max 首装 72 个活动 action 和 512 GiB 内存上限，无容器 swap，不设 CPU 时间配额。默认推理时余 80 个逻辑 CPU，runner 由 cpuset 和 slice 权重约束。较高并发用于覆盖取输入和 I/O 等待。按 2–4 GiB/action 算，72 个约用 144–288 GiB。I5 用一个代表项目核对吞吐和实际内存，作为固定档依据。worker 等两路 kmem 上线后启动。512 GiB 是 DDR4 与 kmem 的 memcg 总上限，PMem 的 `ZONE_MOVABLE` 可承接多数匿名页及文件页缓存，页表和其他不可移动内核分配仍需 DDR4。D4800X 上 848 GiB 裸索引通过 mmap 按需读入页缓存，页缓存可回收。I7 用每路 Normal 水位、PSI 和实际吞吐验固定配置。kmem 未能上线时，Z8 的存储可以独立提供服务，Linux 客户端按本地应急流程运行。工具链可随 runner 镜像或项目输入提供。改镜像时同步 worker 和 Buck2 的 digest。异构 Linux worker 使用一致的 CPU 目标基线，避免 `-march=native` 与 `-mtune=native`。 [Linux ZONE_MOVABLE](https://docs.kernel.org/admin-guide/mm/memory-hotplug.html#zone-movable)

[上游 Docker Compose](https://github.com/buildbarn/bb-deployments/tree/main/docker-compose) · [Buck2 Buildbarn 样例](https://github.com/facebook/buck2/tree/main/examples/remote_execution/buildbarn)

[mini 与 Mac 的上线命令](EDGE.md)

## I5 基线之后再评估的项

先按上面的配置取一次真实构建的基线（吞吐、每路 `Normal` 水位、`i5-cold-watermark`），下列各项逐个对照，无改善就不留。

- **热 CS 索引的两种位置。** 默认在 PMem DAX。先按[放回 P4618 的步骤](#热-cs-索引的位置)取一轮基线，再切到 PMem，比较两路 `Normal` 水位、`pgdemote_*` 与 `pgpromote_*` 计数和构建吞吐。
- **worker 目录保持在 P4618 XFS，tmpfs 暂不采用。** bb-worker 启动时清空输入缓存，不做 fsync，输入从缓存目录硬链接进构建目录。XFS 延迟分配，构建目录里的输出通常在约 30 秒的回写期限前就上传并删除，不会落到 NAND；真正写盘的只有输入缓存（每个文件一次）和长时间动作的中间文件。换成 tmpfs 只省下硬链接和删除的日志开销，按每次约 10 µs 降到 1–2 µs 估，一个 2,000 个输入的编译动作省十几毫秒。代价是 128 GiB 输入缓存从可丢弃的页缓存变成不可回收的内存，空间用尽时动作直接失败，硬链接还要占 tmpfs 的 inode 配额。判断门槛：输入已在缓存时，按 `ExecutedActionMetadata` 的 `input_fetch_*` 与整个动作的时间戳算准备输入的占比，低于 5% 不再考虑，高于 10% 才做对照。那时用默认内存策略，不把页指定到 kmem 节点，头文件和工具链这类反复读的输入应留在 DDR4；也同时评估 bb-worker 的虚拟构建目录。 [启动时清空缓存](https://github.com/buildbarn/bb-remote-execution/blob/c9ba98cf52/cmd/bb_worker/main.go#L300-L306) · [硬链接取输入](https://github.com/buildbarn/bb-remote-execution/blob/c9ba98cf52/pkg/cas/hardlinking_file_fetcher.go#L157-L170)
- **THP `always`。** DAX 的 2 MiB 映射不看这个开关，缺页路径对 DAX VMA 直接放行，按 [PMem 手册](../host/PMEM.md#模型卷)的 `dax_pmd_fault_done` 核实即可。`always` 只影响匿名页，可能给编译器带来 TLB 收益，也可能让 Go、Node 进程变大，按构建吞吐和内存两项决定。 [Linux 7.0 THP 判定](https://github.com/torvalds/linux/blob/v7.0/mm/huge_memory.c#L103-L133)
- **cache 的内存上限。** 容器进程在 Docker 自己的 cgroup，写在 `z8-buildbarn.service` 上的 `MemoryHigh` 管不到它，要用 Compose 的 `mem_limit`。页缓存可下沉到 kmem，每缓存 1 GiB 约占 4 MiB 不可移动的 `xa_node` 和页表；上限压得过低会让冷索引和热块反复换入。只在 `Normal` 水位确有压力时设一个 100 GiB 量级的护栏。
- **根卷预读 2 MiB 对 128 KiB。** md RAID0 把 `io_opt` 报成 chunk × 盘数即 1 MiB，块层取它的两倍作预读，所以根卷是 2 MiB，单块 NVMe 是 128 KiB。bb-storage 用 mmap 读热 CS、AC 和 CMS 的块文件，不带 `madvise`；每次缺页内核按这个窗口在缺页位置前后各读一半，未命中累计比命中多出 100 次才停。同一时期上传的对象在块里相邻，多读的部分可能正好是下一个要读的，也可能只是白占页缓存，要实测。两轮各做一遍：设预读，重启 cache 让它重新打开文件，清页缓存，再从干净工作树取一次全部命中远程缓存的构建。128 KiB 一轮用 `sudo blockdev --setra 256 "$(findmnt -n -o SOURCE /)"`，2 MiB 一轮用 `--setra 4096`，清页缓存用 `sync; echo 1 | sudo tee /proc/sys/vm/drop_caches`。比较构建墙钟时间、根卷读入的扇区数（`/sys/class/block/<根卷的 md 设备>/stat` 第 3 列的增量）和 [`pmem-numa-report.sh`](../host/pmem-numa-report.sh) 里两路 `Normal` 的 `free`。这个值重启主机后回到 2 MiB，128 KiB 明显更好时再用 udev 规则固定。 [RAID0 的 io_opt](https://github.com/torvalds/linux/blob/v7.0/drivers/md/raid0.c#L391-L392) · [预读取两倍 io_opt](https://github.com/torvalds/linux/blob/v7.0/block/blk-settings.c#L82-L84) · [mmap 缺页的预读](https://github.com/torvalds/linux/blob/v7.0/mm/filemap.c#L3339-L3399) · [打开文件时取预读值](https://github.com/torvalds/linux/blob/v7.0/mm/readahead.c#L142-L146) · [bb-storage 的映射](https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5/pkg/blockdevice/memory_mapped_block_device_unix.go#L27)
- **冷数据片的预读保持默认。** 分块下限 256 KiB，缩小预读会把一次冷读拆成许多小请求；HDD 上寻道占主导，顺带多读的部分近乎免费，页缓存可回收。索引切片仍为 0。
- **D4800X 写缓存保持每盘 24 GiB。** 有缓存设备时新写入一律先落 Optane，再整区拷到顺序区。Buildbarn 按块整段覆写，旧顺序区整区失效后直接释放，每字节只写 Optane 一次、HDD 一次。缓存大小只决定一次突发能吸收多少，稳态吞吐等于回收速率。24 个写头占 24 个区，92 个可用区留有余量；`i5-cold-watermark` 的最小空闲区数长期高于 30% 就不必调整。 [dm-zoned 映射分配](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-metadata.c#L2041-L2076) · [回收分支](https://github.com/torvalds/linux/blob/v7.0/drivers/md/dm-zoned-reclaim.c#L362-L418)

## 全 XFS 回退

适用于 I4 冷库持续写达不到目标或冷盘组不可用时。停 tiered 服务，改用 P4618 上独立的 64 GiB CAS（1 GiB 索引）和同一 scheduler。I4 已启用的存储单元继续自动导入池、挂载 `/data/other`。按 [I5.1 软件与目录准备](../storage/README.md#i51-软件目录与单元准备) 安装 Docker 和复制配置。回退使用下面的新状态目录，跳过 I5 的冷库守卫和 tiered 服务启动。完成 [构建侧 cgroup](../host/CPU-PLACEMENT.md#生成并安装)。确认两路 kmem 已上线。使用新存储目录，Buck2 首轮会重新填充缓存。

```bash
(
    set -e
    sudo systemctl disable --now z8-buildbarn-worker.service z8-buildbarn.service
    cd /opt/z8-kit/buildbarn
    BB_DATA_DIR=/srv/buildbarn/cache-xfs
    sudo install -d -m 0750 "$BB_DATA_DIR"/{cs,cms,ac}/persistent_state
    sudo install -d -m 0750 "$BB_DATA_DIR"/{worker/build,worker/cache,runner-bin}
    sudo install -d -m 0750 /run/z8-bb-runner /run/z8-bb-cache
    test "$(findmnt -n -T "$BB_DATA_DIR" -o FSTYPE)" = xfs
    systemctl is-active --quiet z8-pmem-kmem.service
    sudo env BB_DATA_DIR="$BB_DATA_DIR" docker compose -p z8-xfs \
        -f compose.yaml -f compose.fallback-farm.yaml -f compose.worker.yaml \
        -f compose.cpu-layout.yaml up -d
    ss -ltn 'sport = :8980'
)
```

使用同一个农场 buckconfig 验远程执行。该回退为手工恢复；重启后需重建 `/run/z8-bb-runner` 和 `/run/z8-bb-cache` 再执行。回到 tiered 前用同一组 Compose 文件、项目名和 `BB_DATA_DIR=/srv/buildbarn/cache-xfs` 执行 `down`，再启两项原 systemd 服务。
