#!/usr/bin/env bash
set -euo pipefail

: "${LLAMA_BUILD:?Set the absolute path to the llama.cpp build directory}"
: "${DS41_GGUF:?Set the first 1017 GGUF shard on the PMem model volume}"
: "${CUDA_VISIBLE_DEVICES:?Set the four V100 GPU UUIDs in PCIe order}"
: "${Z8_DRAM_INTERLEAVE:?Set the two DDR4 NUMA node numbers}"
slots=${SLOTS:-1}
[[ "$slots" =~ ^[1-9][0-9]{0,6}$ ]] || { echo 'Expected a positive SLOTS' >&2; exit 2; }
slot_ctx=${SLOT_CTX:-$((131072 / slots))}
[[ "$slot_ctx" =~ ^[1-9][0-9]{0,6}$ ]] || { echo 'Expected a positive SLOT_CTX' >&2; exit 2; }
# Non-unified llama.cpp aligns each slot to 256 tokens. Bound the actual allocation.
slot_ctx=$(((slot_ctx + 255) / 256 * 256))
(( slot_ctx <= 1048576 / slots )) || { echo 'Total context exceeds the 1017 limit of 1048576 tokens' >&2; exit 2; }
threads=${Z8_INFER_THREADS:-4}
threads_batch=${Z8_INFER_THREADS_BATCH:-$threads}
batch=${BATCH_SIZE:-512}
# Microbatches above 32 tokens only read the expert cache, so reading a prompt keeps the experts of
# generation in it and uploads each expert once per microbatch.
ubatch=${UBATCH_SIZE:-512}
cpu_share=${MOE_CACHE_CPU_SHARE:-0}
cache_mib=${MOE_CACHE_MIB:-24576}
# dio and none read the routed experts into pinned DDR4, from where a cache miss uploads at link
# speed. The Engram is read by row from its mapping in every mode. With mmap the experts would be
# the PMem pages of the DAX file, which cannot be pinned.
load_mode=${LOAD_MODE:-dio}
case "$load_mode" in
    dio|none|mmap) ;;
    *) echo 'LOAD_MODE must be dio, none or mmap' >&2; exit 2 ;;
esac
kv_type=${KV_TYPE:-f16}
attention=()
case "$kv_type" in
    f16) ;;
    q8_0|q4_0) attention=(--flash-attn on) ;;
    *) echo 'KV_TYPE must be f16, q8_0 or q4_0' >&2; exit 2 ;;
esac
case ${KV_OFFLOAD:-1} in
    1) kv_offload=--kv-offload ;;
    0) kv_offload=--no-kv-offload ;;
    *) echo 'KV_OFFLOAD must be 0 or 1' >&2; exit 2 ;;
esac
for arg in Z8_INFER_THREADS Z8_INFER_THREADS_BATCH BATCH_SIZE UBATCH_SIZE; do
    case "$arg" in
        Z8_INFER_THREADS) value=$threads ;;
        Z8_INFER_THREADS_BATCH) value=$threads_batch ;;
        BATCH_SIZE) value=$batch ;;
        UBATCH_SIZE) value=$ubatch ;;
    esac
    [[ "$value" =~ ^[1-9][0-9]{0,8}$ ]] || { echo "Expected a positive $arg" >&2; exit 2; }
done
(( ubatch <= batch )) || { echo 'UBATCH_SIZE must not exceed BATCH_SIZE' >&2; exit 2; }
[[ "$cpu_share" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]] || {
    echo 'MOE_CACHE_CPU_SHARE must be between 0 and 1' >&2; exit 2;
}
case ${CACHE_PROMPT:-1} in
    1) cache_prompt=--cache-prompt ;;
    0) cache_prompt=--no-cache-prompt ;;
    *) echo 'CACHE_PROMPT must be 0 or 1' >&2; exit 2 ;;
esac
[[ "$cache_mib" =~ ^[0-9]+$ ]] || { echo 'Expected an integer MOE_CACHE_MIB' >&2; exit 2; }
model=$(realpath -e -- "$DS41_GGUF")
[[ -f "$model" && "$model" == /srv/pmem-model/* ]] || {
    echo 'Place the GGUF on /srv/pmem-model' >&2
    exit 2
}
findmnt -rn -M /srv/pmem-model -t xfs -O dax=always >/dev/null
: "${Z8_CUDA_RUNTIME:=/srv/work/jackywang/cuda-12.9-runtime}"
export LD_LIBRARY_PATH="$Z8_CUDA_RUNTIME${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
case ${Z8_NVLINK_P2P:-0} in
    0) unset GGML_CUDA_P2P ;;
    1) export GGML_CUDA_P2P=1 ;;
    *) echo 'Z8_NVLINK_P2P must be 0 or 1' >&2; exit 2 ;;
esac

server=(numactl --interleave="$Z8_DRAM_INTERLEAVE" "$LLAMA_BUILD/bin/llama-server"
    --host 127.0.0.1 --port 18000 -m "$model" --alias deepseek-v4.1-flash-1017
    --load-mode "$load_mode" --lazy-mode on --split-mode layer --tensor-split '1,1,1,1'
    --n-gpu-layers all --cpu-moe --fit off --no-mmproj
    --moe-cache-mib "$cache_mib" --moe-cache-cpu-share "$cpu_share"
    --threads "$threads" --threads-batch "$threads_batch" --batch-size "$batch" --ubatch-size "$ubatch"
    --parallel "$slots" --ctx-size "$((slots * slot_ctx))" --no-kv-unified
    -ctk "$kv_type" -ctv "$kv_type" "$kv_offload" "${attention[@]}"
    --cont-batching --cache-ram 0 --no-cache-idle-slots "$cache_prompt"
    --spec-type none --reasoning off --jinja --metrics --slots)
case ${1:-} in
    '') exec "${server[@]}" ;;
    --tune)
        # The upstream tuner starts this same command several times with its own cache size and CPU share.
        shift
        exec python3 "$(dirname -- "$LLAMA_BUILD")/scripts/moe-cache-tune.py" "$@" -- "${server[@]}"
        ;;
    *) echo 'Usage: serve-llama.sh [--tune [TUNER_OPTIONS]]' >&2; exit 2 ;;
esac
