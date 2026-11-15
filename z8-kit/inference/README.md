# DeepSeek-V4.1-Flash-1017 推理部署

I6 先启 **llama.cpp v1.0.0**。它用一套 ISTA 1017 权重提供 OpenAI 兼容 API 和两个连续批处理槽。Xolotl Buster 是同一套权重的单用户回退。1Cat 保留为有需求时的专项，原版 Strata 与 upstream vLLM 只保留支持范围的结论。 [llama.cpp v1.0.0](https://github.com/ggml-org/llama.cpp/releases/tag/v1.0.0) · [Xolotl Volta 路径](https://github.com/Indras-Mirror/Xolotl/blob/main/BUSTER.md)

主机 Xubuntu 26.04.1 用 [R580 专有驱动](../host/INSTALL.md#安装并锁定-nvidia-显卡驱动)。llama.cpp 和 Xolotl 的 CUDA 编译用 NVIDIA 的 CUDA 12.9.1／Ubuntu 24.04 容器，编译目标为 Volta `sm_70`。宿主运行 llama-server，由 systemd 直接继承分核。显卡可见列表只填 T5 确认的四张 V100 UUID，按实测 PCIe 顺序排列。

## 先挂 PMem，再准备文件

先启 [PMem 模型卷](../host/PMEM.md#i4-在正式系统复用-pmem)。确认 XFS 的 DAX 挂载和 T3 建立的权重目录。T5 用临时系统用户下载；I6 以 `jackywang` 复用已下载文件，若数字 UID/GID 不同先在正式系统对该目录执行一次 `chown -R`。所有权重和 tokenizer 写到该卷。先下载约 232 GiB 的 ISTA IQ2_XXS + IQ4_NL Engram，一份供 llama.cpp 和 Xolotl 共用。 [ISTA 模型文件](https://huggingface.co/ISTA-DASLab/DeepSeek-V4.1-Flash-1017-GSQ-RCO-GGUF)

```bash
(
    set -e
    PMEM=/srv/pmem-model
    findmnt -rn -M "$PMEM" -t xfs -O dax=always
    xfs_io -r -c extsize "$PMEM/ds41-llamacpp"
    df -h "$PMEM"
)
```

## llama.cpp v1.0.0 主服务

在 `z8-kit` 根目录设置 `kit=$(pwd -P)`。正式系统从 `/srv/work/jackywang` 执行，T5 用 SanDisk 上的临时系统，从 `$HOME/z8-smoke` 执行。以下编译和下载命令在选定的工作目录运行。CUDA 容器用于编译，不需要访问 GPU。先取 CUDA runtime 库，两种引擎共享，R580 的设备驱动库由宿主提供。 [llama.cpp CUDA 构建配置](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/ggml/src/ggml-cuda/CMakeLists.txt)

```bash
sudo apt install docker.io git libgomp1 libssl3t64 numactl
sudo systemctl enable --now docker.service
export Z8_CUDA_RUNTIME="$PWD/cuda-12.9-runtime"
mkdir -p "$Z8_CUDA_RUNTIME"
sudo docker run --rm --user "$(id -u):$(id -g)" \
    -v "$PWD/cuda-12.9-runtime:/runtime" nvidia/cuda:12.9.1-devel-ubuntu24.04 bash -euc '
        for library in libcudart.so.12 libcublas.so.12 libcublasLt.so.12 libnvJitLink.so.12; do
            cp -L "/usr/local/cuda/targets/x86_64-linux/lib/$library" /runtime/
        done
        cp -L /usr/lib/x86_64-linux-gnu/libnccl.so.2 /runtime/
    '
git clone --branch v1.0.0 --depth 1 https://github.com/ggml-org/llama.cpp.git
git -C llama.cpp rev-parse HEAD
sudo docker run --rm -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    -v "$PWD/llama.cpp:/src" -w /src nvidia/cuda:12.9.1-devel-ubuntu24.04 bash -euc '
        apt-get update
        apt-get install -y build-essential cmake ninja-build git libssl-dev ca-certificates
        nvcc --version
        git config --global --add safe.directory /src
        cmake -S . -B build -G Ninja -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release \
            -DGGML_NATIVE=ON -DCMAKE_CUDA_ARCHITECTURES=70-real \
            -DCMAKE_INSTALL_RPATH="\$ORIGIN" -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
        cmake --build build --target llama-server -j 8
        chown -R "$HOST_UID:$HOST_GID" build
    '
export LLAMA_BUILD="$(realpath llama.cpp/build)"
LD_LIBRARY_PATH="$Z8_CUDA_RUNTIME" ldd "$LLAMA_BUILD/bin/llama-server"
LD_LIBRARY_PATH="$Z8_CUDA_RUNTIME" ldd "$LLAMA_BUILD/bin/libggml-cuda.so"
```

内部 llama/ggml 共享库按 `$ORIGIN` 在可执行文件旁查找，NCCL 与 CUDA 库一起从同版容器拷贝。两个 `ldd` 输出均应无 `not found`。 [llama.cpp 发布构建的 RPATH](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/.github/workflows/release.yml#L225-L226)

若尚无 `hf`，装 `pipx`，执行 `pipx install huggingface_hub`，再将 `$HOME/.local/bin` 加入 PATH。先给下载命令加 `--dry-run`，应列出五个主体文件和一个 Engram 文件。以下变量供两种引擎共用。链接在首次下载后创建一次。 [ISTA 分片链接约定](https://huggingface.co/ISTA-DASLab/DeepSeek-V4.1-Flash-1017-GSQ-RCO-GGUF#llamacpp)

```bash
PMEM=/srv/pmem-model
DS41_MODEL_DIR="$PMEM/ds41-llamacpp"
DS41_STEM=DeepSeek-V4.1-Flash-1017-GSQ-RCO-IQ2_XXS
DS41_GGUF="$DS41_MODEL_DIR/$DS41_STEM-00001-of-00006.gguf"
DS41_ENGRAM="$DS41_MODEL_DIR/DeepSeek-V4.1-Flash-Engram-IQ4_NL.gguf"
(
    set -e
    findmnt -rn -M "$PMEM" -t xfs -O dax=always
    # T3 创建目录并设置了 extent 提示。I6 核对当前用户可写，必要时交给 jackywang。
    test -w "$DS41_MODEL_DIR"
    hf download ISTA-DASLab/DeepSeek-V4.1-Flash-1017-GSQ-RCO-GGUF \
        --revision 65d53bc8be65123e255ff02f3ded958b6dbf54fd \
        --include "$DS41_STEM-*-of-00006.gguf" "${DS41_ENGRAM##*/}" \
        --local-dir "$DS41_MODEL_DIR"
    test -s "$DS41_GGUF" && test -s "$DS41_ENGRAM"
    ln -sfn -- "${DS41_ENGRAM##*/}" "$DS41_MODEL_DIR/$DS41_STEM-00006-of-00006.gguf"
)
```

**首装目标为单槽 128K。** 四卡 layer split、f16 GPU KV（`SLOTS=1 SLOT_CTX=131072 KV_TYPE=f16 KV_OFFLOAD=1`）。启动器始终显式给 `--ctx-size`，总和计入每槽的 256-token 对齐并设上限 1,048,576。热点专家用 8192 MiB 合计 GPU 缓存，只在 T5/I3 用正式内核默认参数确认六对都走 NVLink且通过数据校验后，才 `export Z8_NVLINK_P2P=1`。未通过时沿用启动器默认关闭。routed experts 留在 host，可按需从 PMem 的 `mmap` 读取，实际 pinned staging 由引擎分配。CPU miss share 固定 0，microbatch 固定 32，进入 v1.0.0 的缓存接纳范围。默认开启槽内前缀复用，标准 OpenAI 请求即可使用。 [专家缓存参数](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/docs/moe-cache.md) · [32-token 接纳上限](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/src/llama-moe-cache.cpp#L340)

```bash
export LLAMA_BUILD Z8_CUDA_RUNTIME DS41_GGUF
export CUDA_VISIBLE_DEVICES=GPU-REPLACE0,GPU-REPLACE1,GPU-REPLACE2,GPU-REPLACE3
export Z8_DRAM_INTERLEAVE=0,1  # 改成 T3 记录的两个 DDR4 节点。
bash "$kit/inference/serve-llama.sh"
```

### 上下文降档与验收

从表中第一档开始。只在显存不足、每卡余量不足或该 KV 档不能正确运行时进入下一档。前五档保持 KV 在 GPU，需要更长且 64K 已能运行时，可试最后一档恢复 128K。

| 顺序 | 每槽上下文 | KV 类型和位置 | 四卡合计 GPU 专家缓存 |
|---|---:|---|---:|
| 首装 | 128K | `KV_TYPE=f16 KV_OFFLOAD=1` | 8192 MiB |
| 量化 KV | 128K | `KV_TYPE=q8_0 KV_OFFLOAD=1` | 8192 MiB |
| 减专家缓存 | 128K | `KV_TYPE=q8_0 KV_OFFLOAD=1` | 4096 MiB |
| 进一步量化 | 128K | `KV_TYPE=q4_0 KV_OFFLOAD=1` | 4096 MiB |
| 缩上下文 | 64K | `KV_TYPE=q4_0 KV_OFFLOAD=1` | 4096 MiB |
| 主机 KV | 128K | `KV_TYPE=f16 KV_OFFLOAD=0` | 4096 MiB |

用 `SLOT_CTX=65536` 切到 64K，用 `MOE_CACHE_MIB=4096` 减缓存。量化档启动器为 K/V 传同一类型，并显式开启 Flash Attention。v1.0.0 的 DeepSeek 4.1 路径使用同一份 K 张量保存 MLA 数据，量化 V 参数仍受 Flash Attention 校验约束。量化 CUDA 内核和长文本正确性用本机 SM70 构建验收。主机档通过 `--no-kv-offload` 把活跃 KV 放到 CPU 内存并改变注意力调度，单独记录速度，只在可用时采用。 [v1.0.0 上下文与量化校验](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/src/llama-context.cpp#L4109-L4177) · [DeepSeek 4.1 量化缓存路径](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/src/models/deepseek41.cpp#L472-L484) · [后端分配](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/src/llama-kv-cache.cpp#L193-L216)

按 1017 官方配置，长程 K 每行含 512 个 latent 和 128 个 index 值。f16 行大小为 1280 B。按 v1.0.0 的四卡等比分层，三个半速源加一个跨卡副本，以及一个全速源加两个跨卡副本，共约 `(4/2 + 3) × 1280 = 6400 B/token`，128K 单槽约 **800 MiB 长程 KV**。raw 滑窗、compressor state、对齐以及推理图临时缓冲另计，实际按启动日志逐缓冲区核对。1Cat 的 54 KB/token、128K 首次填充 110 秒、前缀命中 0.9–1.7 秒来自其四张 32 GiB V100 配方。 [1017 官方配置](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017/blob/main/config.json) · [llama.cpp 跨设备 KV 副本](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/src/llama-kv-cache-dsv4.cpp#L1169-L1269) · [1Cat 上游记录](https://github.com/1CatAI/1Cat-vLLM/blob/main/benchmarks/deepseek_v41/HANDOFF.md#results)

每个实际尝试的档位都记录每卡峰值显存/余量、近满窗口的首次填充时间、解码速度、同前缀第二请求的首字延迟和 20 轮工具循环结果。先保留能稳定达到 128K 的最低代价档。64K 可用时记录实际限制，业务仍需要 128K 时按 [1Cat 专项](#1cat-长上下文专项)验证。双槽是可选项，使用 `SLOTS=2 SLOT_CTX=65536` 保持 128K 合计预算，并另做同时请求验收。

**前缀复用只做一次正确性验收。** 直接用 I6 探针的标准请求重复 A，再插入 B 后续 A。核 `cached_tokens`、固定答案、两个项目标记与实际工具往返。同槽匹配才有复用机会，若发生缓存相关的输出错误，用 `CACHE_PROMPT=0` 暂停这个路径再复现。活跃 KV 留在引擎，额外的 RAM 缓存、空闲槽迁移和文件快照关闭。 [llama-server 前缀参数](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/tools/server/README.md) · [DeepSeek 4.1 前缀修复](https://github.com/ggml-org/llama.cpp/pull/31292)

## 1Cat 长上下文专项

llama.cpp 按上述阶梯仍达不到项目所需的 128K 时才验证。#1277 报告使用四张 **32 GiB** V100，稳态仍约 26.9 GiB/卡。本机四张各 16 GiB，不能照搬其 512K 结果。先核源码包含 SM70 实现，再用随附 phase2 profile 的 4K、0.75 offload、单活动序列、eager 和无 draft 设置。模型占用按此任务单独安排，首装只下载前面的一套。 [1Cat 完整手册](https://github.com/1CatAI/1Cat-vLLM/blob/main/benchmarks/deepseek_v41/HANDOFF.md)

1. 用 `git clone --branch v1.5.2 --depth 1 https://github.com/1CatAI/1Cat-vLLM.git`，固定到包含 #1277 phase2 配方的发布版。按该 tag 的源码安装流程，使用 CUDA 12.8、Python 3.12 和 SM70。 [v1.5.2 phase2 配方](https://github.com/1CatAI/1Cat-vLLM/blob/v1.5.2/benchmarks/deepseek_v41/serve-ds41-phase2.yaml)
2. 在 checkout 创建 `.venv`，设置 `TORCH_CUDA_ARCH_LIST=7.0` 与 `CMAKE_CUDA_ARCHITECTURES=70`，按同版源构建文档执行可编辑 CUDA build。核验 `torch.version.cuda`、`torch.cuda.get_arch_list()` 与 SM70 扩展。运行 `.venv/bin/python benchmarks/deepseek_v41/v41k/build.py`。从同版本 docs 确认 `v41k.so` 默认位置或显式设置 `VLLM_V41K_LIB`。
3. `$GGUF_FIRST` 和 `$ENGRAM_GGUF` 指向本节下载目录里的四分片及独立 Engram。`$TOKENIZER_DIR` 指向 `/srv/pmem-model/ds41-1cat/base`，放固定 revision 的 1017 官方 tokenizer/config 文件。配置生成需 PyYAML。先给下载命令加 `--dry-run` 确认文件清单与容量。 [ISTA 四分片 revision](https://huggingface.co/ISTA-DASLab/DeepSeek-V4.1-Flash-1017-GSQ-RCO-GGUF/tree/0d8f49fb15df73789a9c237a1b8b7b088423dbc0)

```bash
(
    set -e
    PMEM=/srv/pmem-model
    findmnt -rn -M "$PMEM" -t xfs -O dax=always
    sudo install -d -m 0750 -o jackywang -g "$(id -gn jackywang)" "$PMEM/ds41-1cat"
    hf download ISTA-DASLab/DeepSeek-V4.1-Flash-1017-GSQ-RCO-GGUF \
        --revision 0d8f49fb15df73789a9c237a1b8b7b088423dbc0 \
        --include '*IQ2_XXS*of-00004.gguf' '*Engram-IQ4_NL.gguf' \
        --local-dir "$PMEM/ds41-1cat"
)
```

```bash
(
    set -e
    kit=$(realpath /path/to/z8-kit)
    repo=$(realpath /path/to/1Cat-vLLM)
    findmnt -rn -M /srv/pmem-model -t xfs -O dax=always
    "$repo/.venv/bin/python" "$kit/inference/configure.py" 1cat \
        --upstream "$repo/benchmarks/deepseek_v41/serve-ds41-phase2.yaml" \
        --model "$GGUF_FIRST" --engram "$ENGRAM_GGUF" --tokenizer "$TOKENIZER_DIR" \
        --output "$PWD/1cat-4x16.yaml"
    export CUDA_VISIBLE_DEVICES=GPU-REPLACE0,GPU-REPLACE1,GPU-REPLACE2,GPU-REPLACE3
    read -rsp 'Local API key: ' VLLM_API_KEY
    echo
    export VLLM_API_KEY
    numactl --interleave=0,1 bash "$kit/inference/serve-1cat.sh" "$repo" "$PWD/1cat-4x16.yaml"
)
```

1Cat 要对实际 CUDA worker 核 `numastat -p`，并用 `VmLck`/`VmPin` 和引擎日志查 pinned 分配。GGUF 与 Engram 留在 fsdax 上，cold expert staging 按实际 DDR4 缓冲和 PCIe 流量计算，另查 PMem 读取。 [运行时内存策略](../host/CPU-PLACEMENT.md#运行时的-numa-内存策略) · [PMem、pinned memory 与 H→D 测试](../host/PMEM.md#四卡-pinned-dma-验收)

1Cat 的活跃 packed KV 使用 host memfd 与 GPU 热区。这个版本没有文件型 KV backing。生产采用长上下文前要先过短请求、目标上下文和工具调用，并查各 rank 实际显存。 [1Cat KV 布局](https://github.com/1CatAI/1Cat-vLLM/blob/main/benchmarks/deepseek_v41/HANDOFF.md#G4-kv)

## Strata 和 upstream vLLM

Niko1221/Strata 的 1017 官方包未列 V100 的 SM70 运行支持。本机用 Xolotl Buster 作为有 SM70 构建路径的 Strata 系引擎。upstream vLLM 的 1017 公版配方需要至少 8×80 GB NVIDIA GPU；本机如需 vLLM 路线用上面的 1Cat SM70 fork。 [Strata 1017 文档](https://github.com/Niko1221/Strata/blob/main/docs/DEEPSEEK41.md) · [vLLM 1017 配方](https://github.com/vllm-project/vllm/blob/main/recipes/models/deepseek-ai/DeepSeek-V4.1-Flash.yaml)

## Xolotl Buster 单用户回退

使用主服务已经下载的 GGUF 和 Engram。直接四卡切层 `10,20,30`，每 stage 24 GiB pinned arena 上限、8K 上下文和一个活动请求。按 [CPU 分核服务](../host/CPU-PLACEMENT.md#启停本地模型) 将预留提高到每路 6 核后，再保存回退启动器。此档供短上下文任务使用。

在 CUDA 12.9.1 / GCC 兼容用户空间执行。固定到下面的 commit。把 `--model` 指向主服务的第一个分片，把 `--engram` 显式指向真实的 IQ4_NL Engram GGUF。该版本的 dense loader 识别 upstream 命名，独立 Engram loader 识别相应张量，读取时走 `pread`。`$XOL_TOKENIZER_DIR` 指向 PMem 上 1017 对应的 tokenizer 文件目录，实测时核两个引擎的 token 与模板。使用配方默认 expert 排序。 [Xolotl upstream GGUF 支持](https://github.com/Indras-Mirror/Xolotl/blob/db25febda3e2869333d72eca6b17296142916a9b/docs/xolotl/CHANGELOG.md#upstream-llamacpp-and-unsloth-deepseek-v41-ggufs-82-84-85) · [Engram loader](https://github.com/Indras-Mirror/Xolotl/blob/db25febda3e2869333d72eca6b17296142916a9b/tools/v41/engine/ds41_engram.cpp#L263)

Buster 脚本使用 user systemd bus、`flock` 和 `MemoryMax=140G`，遇到内存上限先查实际工作集与 cgroup。生成的 profile 带 `STRATA_ENGRAM_RAWDEV=0`，使用普通用户的文件读取路径。DAX 上的 `pread` 可绕开普通页缓存，排查 PMD fault 时看采用 `mmap` 的引擎。 [Buster 启动脚本](https://github.com/Indras-Mirror/Xolotl/blob/db25febda3e2869333d72eca6b17296142916a9b/tools/buster/buster-engine.sh)

```bash
(
    set -e
    sudo apt install cmake python3-venv
    findmnt -rn -M /srv/pmem-model -t xfs -O dax=always
    XOL_DIR=/srv/pmem-model/ds41-xolotl
    XOL_TOKENIZER_DIR="$XOL_DIR/tokenizer"
    sudo install -d -m 0750 -o "$(id -u)" -g "$(id -g)" "$XOL_DIR"
    hf download IndrasMirror/DeepSeek-V4.1-Flash-GSQ-Uncensored \
        --revision 0ae18f838e103fb03d952fa8ed73c7aa9c34002f \
        --include 'tokenizer/*' --local-dir "$XOL_DIR"
    test -s "$XOL_TOKENIZER_DIR/vocab.json"
    cd "$(dirname -- "$Z8_CUDA_RUNTIME")"
    git clone https://github.com/Indras-Mirror/Xolotl.git
    cd Xolotl
    git switch --detach db25febda3e2869333d72eca6b17296142916a9b
    git rev-parse HEAD
    sudo docker run --rm -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
        -v "$PWD:$PWD" -w "$PWD" nvidia/cuda:12.9.1-devel-ubuntu24.04 bash -euc '
            apt-get update
            apt-get install -y build-essential cmake ninja-build git python3 libssl-dev ca-certificates
            git config --global --add safe.directory "$PWD"
            bash tools/xolotl/fetch-llama.sh
            bash tools/buster/cmake-buster.sh "$PWD/build-buster"
            ninja -C build-buster -j 8 ds41_generate test_cuda_cc_policy test_ds41_pipeline test_ds41_geometry
            chown -R "$HOST_UID:$HOST_GID" build-buster
        '
    export LD_LIBRARY_PATH="$Z8_CUDA_RUNTIME${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    ldd build-buster/ds41_generate > build-buster/ldd-ds41_generate.log
    cat build-buster/ldd-ds41_generate.log
    if grep -Fq 'not found' build-buster/ldd-ds41_generate.log; then
        printf 'Copy missing runtime libraries from the matching CUDA container first.\n' >&2
        exit 1
    fi
    DS41_TEST_GGUF="$DS41_GGUF" ctest --test-dir build-buster \
        -R 'test_cuda_cc_policy|test_ds41_pipeline|test_ds41_geometry' --output-on-failure

    python3 "$kit/inference/configure.py" xolotl --repo "$PWD" \
        --model "$DS41_GGUF" --engram "$DS41_ENGRAM" \
        --tokenizer "$XOL_TOKENIZER_DIR" --gpu "$BUSTER_PCI_INDICES" \
        --context 8192 --output "$PWD/local-1017.json"
    python3 -m venv .venv-serve
    .venv-serve/bin/pip install jinja2 regex
    export STRATA_BUILD_DIR="$PWD/build-buster"
    .venv-serve/bin/python tools/v41/serve/serve_ds41.py --help
    numactl --interleave="$Z8_DRAM_INTERLEAVE" .venv-serve/bin/python tools/v41/serve/serve_ds41.py \
        --engine strata --config local-1017.json --port 8150
)
```

`BUSTER_PCI_INDICES` 按 checkout 实际识别顺序填写四张 V100 的索引，通过日志和 GPU UUID 复核。四卡 layer split 只处理一个活动请求，可以再利用内存会话缓存。Buster 的持久前缀实现限单 stage，四卡回退保持内存缓存和单槽。 [Xolotl 批处理条件](https://github.com/Indras-Mirror/Xolotl/blob/db25febda3e2869333d72eca6b17296142916a9b/tools/v41/engine/ds41_generate.cpp#L615)

## I6 推理放行

从 `z8-kit` 根对 [上下文档位](#上下文降档与验收)执行下面的探针。默认单槽。先给 `long-prompt.txt` 放代表项目的长文本，把模板开销与输出空间也算进每槽预算。用服务器返回的 `usage.prompt_tokens` 确认请求确实接近该槽上限并留约 1K 给模板差异和输出，不能用文件字节数代替 token 数。从刚启动的服务执行一次，另一个终端同时采四卡显存。

```bash
nvidia-smi --query-gpu=uuid,memory.total,memory.used,memory.free --format=csv --loop-ms=200
```

```bash
bash host/run-step.sh i6-probe --base http://127.0.0.1:18000/v1 --usage \
    --model deepseek-v4.1-flash-1017 --prompt-file ./long-prompt.txt \
    --repeats 1 --timeout 1800 --tools
```

用 `A` 的 `prompt_ms` 和首字延迟记录首次填充，`A-repeat` 记录前缀命中 token 和第二轮首字延迟，再看 B 后续 A 的正确性和生成速度。首次填充可为分钟级，记录实测时间即可。近满窗口要求每张卡至少余 **2 GiB**，SSE 完整、无 OOM/Xid，且真实 harness 连续 **20 轮工具往返**通过。只在实际使用双槽时加 `--parallel-pairs` 验两路项目标记。Xolotl 8K 回退用短文本及 8150 端口，加 `--reasoning-effort none`，删去 `--usage`，按回退档记录。

选定档位后把 OMP 的 `contextWindow` 与实际每槽一致，按[正式服务启停](../host/CPU-PLACEMENT.md#启停本地模型)保存参数。核启动日志的 `n_ctx_seq` / `n_ctx_slot` 和 API 就绪，再进入 [I7](../host/BURN-IN.md#i7-正式安装后的整机混合负载)。 [llama-server timings / usage](https://github.com/ggml-org/llama.cpp/blob/v1.0.0/tools/server/README.md#timings-and-context-usage)
