# DeepSeek-V4.1-Flash-1017 推理部署

主机运行 Xubuntu 26.04.1，按 [显卡驱动安装步骤](../host/INSTALL.md#安装并锁定-nvidia-显卡驱动) 装 NVIDIA 驱动。CUDA 12.x 工具链在容器内构建，后面所写的 Ubuntu 24.04 是该构建环境的镜像基底。容器里的 `nvidia-smi` 必须能看到 V100；如用 NVIDIA Container Toolkit，先验证设备映射与库注入。共享内存和 memlock 按实际 profile 需要开，模型目录只读挂载；1Cat 的 loopback 配置在宿主或使用 host 网络的测试容器内工作。把服务先以前台进程运行便于验错。

## 先挂 PMem，再准备文件

模型、Engram、DSpark 和 tokenizer 从第一次下载起就放到约 510 GiB 的 App Direct 条带卷。先启 [PMem 模型卷](../host/PMEM.md#i4-在正式系统复用-pmem)，再以 `z8user` 登录准备目录。若容器启动，模型卷用相同绝对路径 bind mount，权重目录只读，启用持久 KV 的试验才给专用缓存目录写权限。

```bash
PMEM=/srv/pmem-model
findmnt -rn -M "$PMEM" -t ext4 -O dax=always || exit 1
sudo install -d -m 0750 -o z8user -g "$(id -gn z8user)" \
    "$PMEM/ds41-1cat" "$PMEM/ds41-xolotl" "$PMEM/ds41-llamacpp"
df -h "$PMEM"
```

目录分别保存对应 checkout 的格式。先列出下载、解包临时空间、DSpark 和缓存预算。1Cat 参考主体和 Engram 合计约 249 GB，Xolotl 一套 Buster 参考主体和两份 raw Engram 合计约 353 GB，两套若都完整保存，合计约 602 GB，超过约 548 GB 的条带名义容量。按实际 revision 复算，空间不足就轮换引擎文件，保留 manifest 与 hash。两版量化只有字节完全相同且 loader 路径约定兼容时才共享文件。使用 Hugging Face CLI 时大文件用 `--local-dir "$PMEM/对应目录"`，并按选用的客户端将下载缓存或重组临时文件也设在 PMem，下载期间看 `df -h`。 [1Cat 参考文件大小](https://github.com/1CatAI/1Cat-vLLM/blob/main/benchmarks/deepseek_v41/HANDOFF.md) · [Xolotl Buster 1017 文件示例](https://github.com/Indras-Mirror/Xolotl/issues/2)

## llama.cpp 完整模型基线

在兼容 GCC 与 CUDA 12.9 的 Ubuntu 24.04 用户空间运行。先验证 `nvcc --version`。选择 ISTA 当期 llama.cpp 布局的一个固定 revision，把所有 IQ2_XXS 分片与独立 IQ4_NL Engram 下载到 `/srv/pmem-model/ds41-llamacpp`，保留原始命名。HF CLI 可以用 `hf download --dry-run` 先看匹配与容量。

```bash
git clone --branch b11870 --depth 1 https://github.com/ggml-org/llama.cpp.git
cmake -S llama.cpp -B llama.cpp/build -G Ninja \
    -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES=70
cmake --build llama.cpp/build --target llama-cli llama-server -j 8
llama.cpp/build/bin/llama-cli --help | grep -E 'n-cpu-moe|gpu-layers|moe-cache-mib'
```

按所用版本 `--help` 核对 flag。先用两块或四块 V100 的 UUID 列表和下列小 batch，确定低 GPU 层能生成连贯输出；逐次升层并查看实际显存/CPU offload。

```bash
export CUDA_VISIBLE_DEVICES=GPU-REPLACE0,GPU-REPLACE1,GPU-REPLACE2,GPU-REPLACE3
# In the model directory, create the published Engram shard link once.
ln -s -- "$(realpath "$ENGRAM_GGUF")" "${GGUF_FIRST%-00001-of-00006.gguf}-00006-of-00006.gguf"
llama.cpp/build/bin/llama-server --host 127.0.0.1 --port 18000 \
    -m "$GGUF_FIRST" --alias deepseek-v4.1-flash-1017 --ctx-size 4096 \
    --parallel 1 --batch-size 512 --ubatch-size 128 --jinja -ngl 8
```

项目 README 的 `-ngl 99` 面向更大显存。开始跑 1017 前也可先用 1Cat 官方有 4×16 GB 记录的 Qwen3.8-27B NVFP4，检查四卡运行时与通信。 [llama.cpp](https://github.com/ggml-org/llama.cpp/releases/tag/b11870) · [ISTA 当前 GGUF 布局](https://huggingface.co/ISTA-DASLab/DeepSeek-V4.1-Flash-1017-GSQ-RCO-GGUF) · [1Cat 4×16 GB 样例](https://github.com/1CatAI/1Cat-vLLM)

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

上面是默认双 DDR4 节点的启动方式。编号按 `numactl -H` 核对为 DDR4，实际页位置用 `numastat -p` 验。已选单 DDR4 节点时，从最后一条去掉 `numactl --interleave=0,1`。 [运行时内存策略](../host/CPU-PLACEMENT.md#运行时的-numa-内存策略)

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

在 CUDA 12.x / GCC 兼容用户空间执行。先看 `docs/BUSTER.md`。把同一量化的 `$BUSTER_GGUF`、两路 raw Engram 目录和 `$RANK_BIN` 放在 `/srv/pmem-model/ds41-xolotl`，保留上游目录结构。`$XOL_TOKENIZER_DIR` 也放在这里，使用上游 GGUF 导出的 BPE 目录，参见 `export_tokenizer.py`。Buster 脚本使用 user systemd bus、`flock` 和 `MemoryMax=140G`，遇到内存上限先查实际工作集与 cgroup，独立 checkout 中修改并记录补丁。生成的 profile 带 `STRATA_ENGRAM_RAWDEV=0`，使用普通用户的文件读取路径。当前 Xolotl Engram 读法使用 `pread`，它在 DAX 文件系统上仍可绕开普通页缓存，PMD fault 仅对实际采用 `mmap` 的引擎路径成立。 [Buster 启动脚本](https://github.com/Indras-Mirror/Xolotl/blob/main/tools/buster/buster-engine.sh) · [Xolotl Engram 读路径](https://github.com/Indras-Mirror/Xolotl/blob/main/tools/v41/engine/ds41_engram.cpp)

```bash
kit=$(realpath /path/to/z8-kit)
findmnt -rn -M /srv/pmem-model -t ext4 -O dax=always || exit 1
git clone https://github.com/Indras-Mirror/Xolotl.git
cd Xolotl
git rev-parse HEAD
bash tools/xolotl/fetch-llama.sh
bash tools/buster/cmake-buster.sh "$PWD/build-buster"
ninja -C build-buster -j 8 ds41_generate test_cuda_cc_policy test_ds41_pipeline test_ds41_geometry
DS41_TEST_GGUF="$BUSTER_GGUF" ctest --test-dir build-buster \
    -R 'test_cuda_cc_policy|test_ds41_pipeline|test_ds41_geometry' --output-on-failure

python3 "$kit/inference/configure.py" xolotl --repo "$PWD" \
    --model "$BUSTER_GGUF" --engram "$ENGRAM_LAYER_1" "$ENGRAM_LAYER_14" \
    --rank "$RANK_BIN" --tokenizer "$XOL_TOKENIZER_DIR" --gpu "$BUSTER_PCI_INDICES" \
    --output "$PWD/local-1017.json"
python3 tools/v41/serve/serve_ds41.py --help
numactl --interleave=0,1 python3 tools/v41/serve/serve_ds41.py \
    --engine strata --config local-1017.json --port 8150
```

`BUSTER_PCI_INDICES` 填按 checkout 实际识别的 V100 编号，如 `1,2`，用进程日志和 GPU UUID 复核。`--interleave=0,1` 只填实际 DDR4 节点，单 DDR4 节点时去掉 `numactl` 前缀。对 Buster 的实际引擎 PID 核 `numastat -p`。初始只用 loopback，先用 `ss -ltnp` 验监听。四卡用 layer split 和 `--parallel 1`。当前 DS41 native engine 在 layer split 下关闭 batch slots，仍有多 stage 的内存会话缓存，可串行测 `A→A` 与 `A→B→A`，观察复用日志。要测 DSpark，把兼容 sidecar 下载到同一 PMem 目录，生成命令追加 `--draft "$DSPARK_GGUF" --draft-tokens 1`，脚本填 `STRATA_SERVE_DSPARK`。核日志、末卡余量和接受率，再增深度。 [Xolotl DS41 源码](https://github.com/Indras-Mirror/Xolotl/blob/main/tools/v41/engine/ds41_generate.cpp)

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

```bash
export DS41_API_KEY="$VLLM_API_KEY"   # 仅在服务设置了鉴权时
python3 inference/probe.py --base http://127.0.0.1:18000/v1 --usage \
    --model deepseek-v4.1-flash-1017 --prompt-file /path/to/synthetic-context.txt \
    --repeats 5 --tools
```

`--prompt-file` 可以换成不含密钥的固定文档，日志只写延迟和计数。用 `--max-tokens` 留足生成空间。先跑短文本和工具，再测长文、冷/热会话、真正的 harness 与并发构建。`A→B→A` 探针发送相同 A 请求，用于测精确前缀的时延代理。1Cat 上游 session cache 要求续上前一序列，另用其 `session_test.py` 验证真实续写以及日志中的命中。探针结果本身无法证明缓存命中、租户隔离或长上下文召回。
