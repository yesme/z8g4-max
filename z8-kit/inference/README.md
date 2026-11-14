# DeepSeek-V4.1-Flash-1017 推理部署

主机运行 Xubuntu 26.04.1，按 [显卡驱动安装步骤](../host/INSTALL.md#安装并锁定-nvidia-显卡驱动) 装 NVIDIA 驱动。CUDA 12.x 工具链在容器内构建，后面所写的 Ubuntu 24.04 是该构建环境的镜像基底。容器里的 `nvidia-smi` 必须能看到 V100；如用 NVIDIA Container Toolkit，先验证设备映射与库注入。共享内存和 memlock 按实际 profile 需要开，模型目录只读挂载；1Cat 的 loopback 配置在宿主或使用 host 网络的测试容器内工作。把服务先以前台进程运行便于验错。

F10 固定 NUMA 开、SNC 关。以下 `--interleave=0,1` 中的 `0,1` 是示例。用 `numactl -H` 和 [T3 拓扑报告](../host/PMEM.md#核对双路-numa-拓扑) 填两个 DDR4 节点号。模型启动后，用实际推理 worker PID 的 `numastat -p` 和 `/proc/<PID>/numa_maps` 核对页分布。

## 先挂 PMem，再准备文件

模型、Engram、DSpark 和 tokenizer 从第一次下载起就放到 PMem。以下通用启动命令用名义 516 GiB、块设备约 508 GiB 的 App Direct 条带卷。先启 [PMem 模型卷](../host/PMEM.md#i4-在正式系统复用-pmem)，再以 `z8user` 登录准备目录。若容器启动，模型卷用相同绝对路径 bind mount，权重目录只读，启用持久 KV 的试验才给专用缓存目录写权限。

要在组条带前验证 1017 的 NUMA 本地性，按两个本地卷的清单下载分片，使用相同 `DS41_GGUF` / `DS41_ENGRAM` 参数指向实体文件和链接所在目录，前台运行并核两处挂载。 [两个本地卷的文件布局](../host/PMEM.md#两个本地卷的-1017-文件布局)

```bash
PMEM=/srv/pmem-model
findmnt -rn -M "$PMEM" -t ext4 -O dax=always || exit 1
sudo install -d -m 0750 -o z8user -g "$(id -gn z8user)" \
    "$PMEM/ds41-1cat" "$PMEM/ds41-xolotl" "$PMEM/ds41-llamacpp"
df -h "$PMEM"
```

llama.cpp 和本页固定的 Xolotl 先共用同一套 ISTA IQ2_XXS 主体和 IQ4_NL Engram，约 249 GB（232 GiB）。1Cat #1277 的独立四分片参考套装另占约 249 GB。若两套都下载，在约 508 GiB 块设备上先扣除模型后余约 44 GiB，再扣文件系统开销、预留块并核算 draft、缓存和临时文件。若另试 Xolotl raw Engram 参考套装，先安排轮换。用 `df -h` 检查实际可用量，下载和重组的临时文件也放 PMem。保留模型 revision、文件名与 SHA256。 [ISTA 模型文件](https://huggingface.co/ISTA-DASLab/DeepSeek-V4.1-Flash-1017-GSQ-RCO-GGUF) · [1Cat 参考文件大小](https://github.com/1CatAI/1Cat-vLLM/blob/main/benchmarks/deepseek_v41/HANDOFF.md) · [Buster raw Engram 样例](https://github.com/Indras-Mirror/Xolotl/issues/2)

## llama.cpp v1.0.0 首选多会话服务候选

v1.0.0 于 2026-11-13 发布，包含后端专家缓存、LRFU/ClassLRU 和 CPU miss 分流。运行时给它设缓存预算，热点随实际路由变化，命中则从 GPU 缓存取专家。缓存开启后可把稳定工作阶段的一部分 miss 分给 CPU，其余通过 PCIe 上传给 GPU。`--moe-cache-mib` 是四卡合计预算。v1.0.0 源码对 `ubatch > 32` 跳过专家缓存接纳和 CPU miss 分流，大 batch 仍可复用已驻留的专家。分别测长 prompt prefill、工具返回后的 prefill 和持续 decode。 [v1.0.0 发布说明](https://github.com/ggml-org/llama.cpp/releases/tag/v1.0.0) · [专家缓存文档](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/docs/moe-cache.md) · [缓存分流实现](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/src/llama-moe-cache.cpp#L684)

在 CUDA 12.9 与兼容 GCC 的构建环境运行。用 `nvidia-smi -L` 取四块 V100 的 UUID，按硬件验机记录的 PCIe 顺序设置 `CUDA_VISIBLE_DEVICES`。记录 v1.0.0 对应 commit 和 `nvcc --version`。

```bash
git clone --branch v1.0.0 --depth 1 https://github.com/ggml-org/llama.cpp.git
git -C llama.cpp rev-parse HEAD
nvcc --version
cmake -S llama.cpp -B llama.cpp/build -G Ninja \
    -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES=70-real
cmake --build llama.cpp/build --target llama-cli llama-server -j 8
export CUDA_VISIBLE_DEVICES=GPU-REPLACE0,GPU-REPLACE1,GPU-REPLACE2,GPU-REPLACE3
llama.cpp/build/bin/llama-server --list-devices
```

先给下载命令加 `--dry-run`，应列出五个主体文件和一个 Engram 文件。以下变量供两种引擎共用。链接在首次下载后创建一次。 [ISTA 分片链接约定](https://huggingface.co/ISTA-DASLab/DeepSeek-V4.1-Flash-1017-GSQ-RCO-GGUF#llamacpp)

```bash
PMEM=/srv/pmem-model
findmnt -rn -M "$PMEM" -t ext4 -O dax=always || exit 1
DS41_MODEL_DIR="$PMEM/ds41-llamacpp"
DS41_STEM=DeepSeek-V4.1-Flash-1017-GSQ-RCO-IQ2_XXS
DS41_GGUF="$DS41_MODEL_DIR/$DS41_STEM-00001-of-00006.gguf"
DS41_ENGRAM="$DS41_MODEL_DIR/DeepSeek-V4.1-Flash-Engram-IQ4_NL.gguf"
hf download ISTA-DASLab/DeepSeek-V4.1-Flash-1017-GSQ-RCO-GGUF \
    --revision 65d53bc8be65123e255ff02f3ded958b6dbf54fd \
    --include "$DS41_STEM-*-of-00006.gguf" "${DS41_ENGRAM##*/}" \
    --local-dir "$DS41_MODEL_DIR"
test -s "$DS41_GGUF" && test -s "$DS41_ENGRAM" || exit 1
ln -s -- "${DS41_ENGRAM##*/}" "$DS41_MODEL_DIR/$DS41_STEM-00006-of-00006.gguf"
```

先让 dense/attention 分层上四卡，把 routed experts 留在 host，测 cache-off。`-t/-tb` 以分给推理的 12 个逻辑 CPU 为起点，运行时纳入 [CPU 分核服务](../host/CPU-PLACEMENT.md#启停本地模型)。

```bash
findmnt -rn -M /srv/pmem-model -t ext4 -O dax=always || exit 1
slots=${SLOTS:-1}
slot_ctx=${SLOT_CTX:-4096}
numactl --interleave=0,1 llama.cpp/build/bin/llama-server --host 127.0.0.1 --port 18000 \
    -m "$DS41_GGUF" --alias deepseek-v4.1-flash-1017 \
    --load-mode mmap --lazy-mode on --split-mode layer --tensor-split 1,1,1,1 \
    --n-gpu-layers all --cpu-moe --fit off --no-mmproj \
    --moe-cache-mib "${MOE_CACHE_MIB:-0}" --moe-cache-cpu-share "${MOE_CPU_SHARE:-0}" \
    --threads 12 --threads-batch 12 --batch-size 512 --ubatch-size "${UBATCH_SIZE:-128}" \
    --parallel "$slots" --ctx-size "$((slots * slot_ctx))" --no-kv-unified \
    --cont-batching --cache-ram 0 --no-cache-idle-slots --no-cache-prompt \
    --spec-type none --reasoning off --jinja --metrics --slots
```

如果 cache-off 已显存不足，先查四卡分配并降低 `--n-gpu-layers`。cache-off 跑通后固定层分布，先设 `MOE_CACHE_MIB=8192 MOE_CPU_SHARE=0`，再单独扫 CPU share `0.5 / 0.9`。有足够逐卡余量才试 `16384 / 24576` MiB 总缓存。看每卡缓存分配、预填充和 decode 峰值、PCIe 带宽及正常退出时输出的 cache hit / CPU miss / host upload 统计。活跃 KV 先保留引擎默认布局，模型和 Engram 留 PMem。`mmap` 下经 fsdax 映射的页直接访问 PMem，CPU backend 也可能分配或重排部分张量到 DRAM。用引擎日志、`/proc/<PID>/smaps`、`VmPin`/`VmLck` 与 `numastat -p` 核对。可另测 `--load-mode none` 给冷专家更多 DDR4/pinned 容量，运行前先停重构建，确认 Engram 仍按需映射和 DDR4 余量。约 129 GiB 主体全进 DDR4 时，扣掉 16 GiB ARC、32 GiB 构建预算后，名义只剩约 15 GiB 给其他分配。 [缓存与 host buffer](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/docs/moe-cache.md) · [权重 loader](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/src/llama-model-loader.cpp)

开专家缓存后，用同一模型和请求重启分别跑 `UBATCH_SIZE=32` 与 `128`，在 32 档扫 `MOE_CPU_SHARE=0 / 0.5 / 0.9`。记录长 prefill、工具回传 TTFT、decode 稳态与 cache admission / CPU miss / upload 计数。32 档让长 prompt 的实际 microbatch 进入两条优化路径，128 档仍可利用已驻留专家及短 microbatch，能否更快看实测。 [缓存分流实现](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/src/llama-moe-cache.cpp#L684)

固定专家策略后设 `SLOTS=2`，先测 4K/slot（总 8192），再设 `SLOT_CTX=8192` 测 8K/slot（总 16384）。核启动日志的 `n_ctx_slot`，在探针加 `--parallel-pairs`，两路同时运行时查 `/slots` 和 `/metrics`。验证两路持续流式、不同项目标记与工具闭环后，把 `--no-cache-prompt` 改成 `--cache-prompt`，测 `A→A`、`A→B→A` 和相同前缀配不同后缀的实际复用 token 数。槽位按 prompt 相似度匹配，可另测 host prompt cache 和 slot 保存恢复。比较各路和合计吞吐、工具追加后的 TTFT 及取消后恢复。拿四卡 Xolotl 用同一权重与任务作单会话对照，先在两边关闭 thinking（Xolotl 请求体加 `"reasoning_effort": "none"`）。 [llama-server 参数与接口](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/tools/server/README.md) · [Xolotl 请求参数](https://github.com/Indras-Mirror/Xolotl/blob/db25febda3e2869333d72eca6b17296142916a9b/tools/v41/serve/serve_ds41.py#L60)

要验证重启后复用，在已挂载的 PMem 卷上为运行账户准备权限 `0700` 的 `/srv/pmem-model/kv/llama`，另起一轮加 `--slot-save-path /srv/pmem-model/kv/llama/`。对空闲 slot 调 `POST /slots/<id>?action=save`，JSON 指定 `{"filename":"prefix.bin"}`。同版服务重启后对目标 slot 调 `action=restore`，重发同前缀配新后缀，核 API 返回的恢复量和下一次 prompt 的 `cache_n`。这是显式文件快照，运行时活跃 KV 和 host prompt cache 仍各用引擎自己的内存分配。 [slot 缓存保存与恢复接口](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/tools/server/README.md)

## 1Cat 性能试配

1. 克隆 `https://github.com/1CatAI/1Cat-vLLM.git`，先取发布 `v1.5.2` 作候选，固定 `git rev-parse HEAD`。确认 checkout 有 `benchmarks/deepseek_v41/serve-ds41-phase2.yaml` 和同目录下的 `v41k/build.py`，并包含 #1277。若版本中缺路径，从上游选定一个含 #1277 的 SHA。用该版本的源码安装说明和 `docker/Dockerfile`，选择 12.8 / Python 3.12 / SM70。普通 vLLM wheel 和 1Cat 此前的 release wheel 都需检查支持范围。
2. 在 checkout 创建 `.venv`，设置 `TORCH_CUDA_ARCH_LIST=7.0` 与 `CMAKE_CUDA_ARCHITECTURES=70`，按同版源构建文档执行可编辑 CUDA build。核验 `torch.version.cuda`、`torch.cuda.get_arch_list()` 与 SM70 扩展。运行 `.venv/bin/python benchmarks/deepseek_v41/v41k/build.py`。从同版本 docs 确认 `v41k.so` 默认位置或显式设置 `VLLM_V41K_LIB`。
3. `$GGUF_FIRST` 和 `$ENGRAM_GGUF` 指向本节下载目录里的四分片及独立 Engram。`$TOKENIZER_DIR` 指向 `/srv/pmem-model/ds41-1cat/base`，放固定 revision 的 1017 官方 tokenizer/config 文件。配置生成需 PyYAML。先给下载命令加 `--dry-run` 确认文件清单与容量。 [ISTA 四分片 revision](https://huggingface.co/ISTA-DASLab/DeepSeek-V4.1-Flash-1017-GSQ-RCO-GGUF/tree/0d8f49fb15df73789a9c237a1b8b7b088423dbc0)

```bash
PMEM=/srv/pmem-model
findmnt -rn -M "$PMEM" -t ext4 -O dax=always || exit 1
hf download ISTA-DASLab/DeepSeek-V4.1-Flash-1017-GSQ-RCO-GGUF \
    --revision 0d8f49fb15df73789a9c237a1b8b7b088423dbc0 \
    --include '*IQ2_XXS*of-00004.gguf' '*Engram-IQ4_NL.gguf' \
    --local-dir "$PMEM/ds41-1cat"
```

```bash
kit=$(realpath /path/to/z8-kit)
repo=$(realpath /path/to/1Cat-vLLM)
findmnt -rn -M /srv/pmem-model -t ext4 -O dax=always || exit 1
"$repo/.venv/bin/python" "$kit/inference/configure.py" 1cat \
    --upstream "$repo/benchmarks/deepseek_v41/serve-ds41-phase2.yaml" \
    --model "$GGUF_FIRST" --engram "$ENGRAM_GGUF" --tokenizer "$TOKENIZER_DIR" \
    --output "$PWD/1cat-4x16.yaml"
export CUDA_VISIBLE_DEVICES=GPU-REPLACE0,GPU-REPLACE1,GPU-REPLACE2,GPU-REPLACE3
read -rsp 'Local API key: ' VLLM_API_KEY
echo
export VLLM_API_KEY
numactl --interleave=0,1 bash "$kit/inference/serve-1cat.sh" "$repo" "$PWD/1cat-4x16.yaml"
```

1Cat 要对实际 CUDA worker 核 `numastat -p`，并用 `VmLck`/`VmPin` 和引擎日志查 pinned 分配。GGUF 与 Engram 留在 fsdax 上，cold expert staging 按实际 DDR4 缓冲和 PCIe 流量计算，另查 PMem 读取。 [运行时内存策略](../host/CPU-PLACEMENT.md#运行时的-numa-内存策略) · [PMem、pinned memory 与 H→D 测试](../host/PMEM.md#量-upi-与-pinned-memory)

过 4K 单会话后按计划分步恢复图、长上下文和 DSpark。把与 phase3 匹配的 draft safetensors 目录准备在 `/srv/pmem-model/ds41-1cat/dspark-v41`。在上一条生成命令中改用同 checkout 的 `serve-ds41-phase3.yaml`，追加 `--draft /srv/pmem-model/ds41-1cat/dspark-v41`，给 `--output` 新文件名。脚本把它填入 `speculative-config.model`，沿用配方的量化、加载方式及 DSpark5 宽度。该引擎要求 draft 宽度满足 checkpoint block size。检查日志确认 drafter 加载和接受率。原配方只有一个活动请求，先测同会话恢复。 [1Cat phase3 配方](https://github.com/1CatAI/1Cat-vLLM/blob/main/benchmarks/deepseek_v41/serve-ds41-phase3.yaml) · [1Cat DSpark 参数校验](https://github.com/1CatAI/1Cat-vLLM/blob/main/vllm/config/speculative.py#L1006) · [#1277 handoff](https://github.com/1CatAI/1Cat-vLLM/blob/main/benchmarks/deepseek_v41/HANDOFF.md)

1Cat #1277 的 packed KV 将压缩 latents 放在共享 memfd，热环与索引留 GPU。本版查到的配方没有文件型 KV backing 路径。先记录单会话 packed KV 的各 rank 位置和大小。若要让未 pin 的主机 KV 用到约 1 TiB 的 kmem，针对这块 memfd 映射在引擎内部做 NUMA 分配或迁移实验，保留同进程的专家 pinned arena 在 DDR4。先确认这块映射的 CUDA 注册方式，再决定能否尝试；Linux 对 movable 页的长期 pin 会尝试迁移或返回错误。用 `/proc/<PID>/maps`、`/proc/<PID>/numa_maps`、`VmLck`/`VmPin`、memcg 和引擎日志联合核对。 [1Cat KV 实现说明](https://github.com/1CatAI/1Cat-vLLM/blob/main/benchmarks/deepseek_v41/HANDOFF.md#G4-kv) · [Linux 7.0 长期 pin 路径](https://github.com/torvalds/linux/blob/v7.0/mm/gup.c#L2247)

## Niko1221/Strata 平台与 1017 兼容性

Strata 上游已提供独立的 1017 安装和 API。官方 CUDA 目标从 Ampere 起，V100 的 `sm_70` 需要可验证的移植或支持该架构的版本。先通过官方 Terminal 安装说明取得固定版本，从 CLI 的 plan 核模型、计算卡、空间和预计内存，再决定是否下载。P620 只负责显示。

```bash
strata launch --family deepseek41 --model ist-das-2.00bpw \
    --context 8k --parallel 1 --access local --port 18001 --plan
```

如果当前 build 的 CUDA 能力检查接受 V100 且引擎确认包含 SM70 kernel，去掉 `--plan` 启动，跑 `curl http://127.0.0.1:18001/v1/models` 和下文的探针。随后用同一模型和同一上下文测 `--parallel 2`。如果报 compute capability、missing kernel image 或 build guard 拒绝，在这台机上把 Xolotl Buster 作为 Strata 系 1017 的实跑路线。保留原版 Strata 的计划输出、版本与失败点，避免重复下载约 257 GB。 [Strata Terminal 安装及参数](https://github.com/Niko1221/Strata/blob/main/docs/TERMINAL_LAUNCH.md) · [Strata 1017 模型与显卡](https://github.com/Niko1221/Strata/blob/main/docs/DEEPSEEK41.md) · [CUDA 构建约束](https://github.com/Niko1221/Strata/blob/main/CMakeLists.txt)

## Xolotl Buster 性能与并发试配

I6 先验本节的原生启动。I7 改由 [CPU 分核服务](../host/CPU-PLACEMENT.md#启停本地模型) 启停本地模型，服务切换时自动让出与归还 CPU。1Cat 的 CUDA worker 继承 service cgroup；Xolotl 用配套补丁让 Buster 的实际引擎也继承该 cgroup。

在 CUDA 12.x / GCC 兼容用户空间执行。固定到下面的 commit。把 `--model` 指向上节第一个分片，把 `--engram` 显式指向真实的 IQ4_NL Engram GGUF。该版本的 dense loader 识别 upstream 命名，独立 Engram loader 识别相应张量，读取时走 `pread`。`$XOL_TOKENIZER_DIR` 指向 PMem 上 1017 对应的 tokenizer 文件目录，实测时核两个引擎的 token 与模板。已用该量化与路由生成 rank 时给配置生成器追加 `--rank "$RANK_BIN"`，无 rank 时上游按 layer/expert 顺序初始化，可跑通基线并记录这一条件。若单独复现旧 Buster 配方，模型换成该配方的主体，`--engram` 传两路 raw 目录并用其配套 rank。 [Xolotl upstream GGUF 支持](https://github.com/Indras-Mirror/Xolotl/blob/db25febda3e2869333d72eca6b17296142916a9b/docs/xolotl/CHANGELOG.md#upstream-llamacpp-and-unsloth-deepseek-v41-ggufs-82-84-85) · [Engram loader](https://github.com/Indras-Mirror/Xolotl/blob/db25febda3e2869333d72eca6b17296142916a9b/tools/v41/engine/ds41_engram.cpp#L263)

Buster 脚本使用 user systemd bus、`flock` 和 `MemoryMax=140G`，遇到内存上限先查实际工作集与 cgroup。生成的 profile 带 `STRATA_ENGRAM_RAWDEV=0`，使用普通用户的文件读取路径。DAX 上的 `pread` 可绕开普通页缓存，排查 PMD fault 时看采用 `mmap` 的引擎。 [Buster 启动脚本](https://github.com/Indras-Mirror/Xolotl/blob/db25febda3e2869333d72eca6b17296142916a9b/tools/buster/buster-engine.sh)

```bash
kit=$(realpath /path/to/z8-kit)
findmnt -rn -M /srv/pmem-model -t ext4 -O dax=always || exit 1
XOL_DIR=/srv/pmem-model/ds41-xolotl
XOL_TOKENIZER_DIR="$XOL_DIR/tokenizer"
hf download IndrasMirror/DeepSeek-V4.1-Flash-GSQ-Uncensored \
    --revision 0ae18f838e103fb03d952fa8ed73c7aa9c34002f \
    --include 'tokenizer/*' --local-dir "$XOL_DIR"
test -s "$XOL_TOKENIZER_DIR/vocab.json" || exit 1
git clone https://github.com/Indras-Mirror/Xolotl.git
cd Xolotl
git switch --detach db25febda3e2869333d72eca6b17296142916a9b
git rev-parse HEAD
bash tools/xolotl/fetch-llama.sh
bash tools/buster/cmake-buster.sh "$PWD/build-buster"
ninja -C build-buster -j 8 ds41_generate test_cuda_cc_policy test_ds41_pipeline test_ds41_geometry
DS41_TEST_GGUF="$DS41_GGUF" ctest --test-dir build-buster \
    -R 'test_cuda_cc_policy|test_ds41_pipeline|test_ds41_geometry' --output-on-failure

python3 "$kit/inference/configure.py" xolotl --repo "$PWD" \
    --model "$DS41_GGUF" --engram "$DS41_ENGRAM" \
    --tokenizer "$XOL_TOKENIZER_DIR" --gpu "$BUSTER_PCI_INDICES" \
    --output "$PWD/local-1017.json"
python3 -m venv .venv-serve
.venv-serve/bin/pip install jinja2 regex
export STRATA_BUILD_DIR="$PWD/build-buster"
.venv-serve/bin/python tools/v41/serve/serve_ds41.py --help
numactl --interleave=0,1 .venv-serve/bin/python tools/v41/serve/serve_ds41.py \
    --engine strata --config local-1017.json --port 8150
```

`BUSTER_PCI_INDICES` 填按 checkout 实际识别的 V100 编号，如 `1,2`，用进程日志和 GPU UUID 复核。对 Buster 的 `ds41_generate` PID 核 `numastat -p`。初始只用 loopback，先用 `ss -ltnp` 验监听。四卡用 layer split 和 `--parallel 1`。本版本 DS41 native engine 在 layer split 下关闭 batch slots，仍有多 stage 的内存会话缓存，可串行测 `A→A` 与 `A→B→A`，观察复用日志。要测 DSpark，把兼容 sidecar 下载到同一 PMem 目录，生成命令追加 `--draft "$DSPARK_GGUF" --draft-tokens 1`，脚本填 `STRATA_SERVE_DSPARK`。核日志、末卡余量和接受率，再增深度。 [Xolotl DS41 源码](https://github.com/Indras-Mirror/Xolotl/blob/db25febda3e2869333d72eca6b17296142916a9b/tools/v41/engine/ds41_generate.cpp#L615)

### 持久 KV 前缀试验

Xolotl #99 支持单 stage 的原生 checkpoint。四卡 layer split 的 `Ds41ConversationServe` 当前使用内存会话缓存，源码的持久化条件是 `pipe.n_stages() == 1 && pool_on`。要测 PMem 持久缓存，用一张 V100、短上下文起步；先确认单 stage 能加载并跑完完整模型。创建用户私有目录后，用同一条生成命令替换为 `--gpu "$SINGLE_V100_INDEX" --prefix-cache "$PMEM/kv/xolotl-single-stage" --output "$PWD/xolotl-1gpu-pmem-kv.json"`。脚本设 `STRATA_PREFIX_CACHE_DIR`、16 GiB 磁盘预算、20 GiB 卷余量和 2 GiB 临时快照预算。先在超过 2,048 token 的合成前缀上等引擎日志出现快照保存及目录文件，再真正重启引擎，改变后缀，核 `persistent prefix restored`、恢复 token 数和 TTFT。单 stage 通过后，可单独试 `--parallel 2` 并测队列与有效 slots。 [Xolotl 持久前缀文档](https://github.com/Indras-Mirror/Xolotl/blob/main/docs/PERSISTENT_PREFIX_CACHE.md) · [DS41 的单 stage 条件](https://github.com/Indras-Mirror/Xolotl/blob/main/tools/v41/engine/ds41_generate.cpp#L1809)

```bash
PMEM=/srv/pmem-model
findmnt -rn -M "$PMEM" -t ext4 -O dax=always || exit 1
sudo install -d -m 0700 -o z8user -g "$(id -gn z8user)" "$PMEM/kv"
install -d -m 0700 "$PMEM/kv/xolotl-single-stage"
```

活跃 KV 继续用 native 布局。要做四卡 checkpoint 落 PMem，需为多 stage 保存和恢复实现并验完整的 ring、index、compressor 和 Engram 历史状态，再测精确复用、取消和不同用户隔离。

### 单独扫描 host arena

这版 DS41 把相同的 `--arena-gib` 预算交给每个 stage。生成脚本四卡默认每 stage 24 GiB，双卡和单卡默认每 stage 48 GiB。四卡固定切层和 4K 请求，按 `--arena-gib 24 → 25 → 26 → 27` 复跑，对应合计上限 96 → 100 → 104 → 108 GiB。按各 stage 的实际占用核 pinned RSS、每节点余量、cgroup 峰值、PMem 读量、TTFT 和 decode。实际达到 108 GiB 时，扣去 16 GiB ARC 与 32 GiB 构建预算后，DDR4 名义剩 36 GiB。单会话通过后再并发编译。148 GiB 只作为单卡隔离诊断档，先停构建，并核 Buster wrapper 的 `MemoryMax=140G` 和各 DRAM 节点余量。 [Xolotl stage 初始化](https://github.com/Indras-Mirror/Xolotl/blob/main/tools/v41/engine/ds41_pipeline.cpp#L382) · [Xolotl arena 上限](https://github.com/Indras-Mirror/Xolotl/blob/main/tools/v41/engine/ds41_moe.cpp#L2377)

## 统一验证

默认串行发请求，生成预算为 256 token。只在配置了多槽或专门测排队时加 `--parallel-pairs`。若返回只有 reasoning，按探针报出的 `finish_reason` 核 thinking 和生成预算。

```bash
export DS41_API_KEY="$VLLM_API_KEY"   # 仅在服务设置了鉴权时
python3 inference/probe.py --base http://127.0.0.1:18000/v1 --usage \
    --model deepseek-v4.1-flash-1017 --prompt-file /path/to/synthetic-context.txt \
    --repeats 5 --tools
```

`--prompt-file` 可以换成不含密钥的固定文档，日志只写延迟和计数。用 `--max-tokens` 留足生成空间。先跑短文本和工具，再测长文、冷/热会话、真正的 harness 与并发构建。看 llama.cpp 的 `usage.prompt_tokens_details.cached_tokens` 或 `timings.cache_n` 核前缀命中，`timings.prompt_n` / `prompt_ms` 核实 prefill。`A→B→A` 探针重发相同 A 请求，另用真实 harness 回传工具结果测增量 prefill。1Cat 上游 session cache 要求续上前一序列，另用其 `session_test.py` 验证真实续写以及日志中的命中。探针的项目标记用于发现串话，租户隔离和长上下文召回还要单独测。 [llama-server timings / usage](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/tools/server/README.md#timings-and-context-usage)

用 Xolotl 对照关闭 thinking 的 llama.cpp 时，探针加 `--base http://127.0.0.1:8150/v1 --reasoning-effort none`。能返回原生 `timings` 的服务会在探针 JSON 中显示 `server_timings`。
