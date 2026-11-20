#!/usr/bin/env bash
set -euo pipefail

# Under a bind policy a page lands on the socket whose CPU touches it first, and llama.cpp reads all
# host experts from its main thread. Left alone, that fills one DDR4 node before the other. This moves
# the main thread between the two sockets every 0.2 s until /health reports the model as loaded, then
# gives every thread its original CPUs back and prints where the memory ended up.
rotate_load() {
    local pid=$1 port=18000 allowed range cpu socket_of list ready=0 started=$SECONDS
    local -a ranges sockets=() cpus=()
    shift
    while (( $# > 1 )); do
        # The tuner appends its own port to the command; the last one wins.
        if [[ "$1" == --port ]]; then port=$2; fi
        shift
    done
    command -v curl > /dev/null || { echo 'Not rotating the loader: curl is missing.'; return 0; }
    allowed=$(taskset -pc "$pid" 2> /dev/null) || return 0
    allowed=${allowed##*: }
    while IFS=, read -r cpu socket_of; do
        [[ "$cpu" =~ ^[0-9]+$ ]] && cpus[cpu]=$socket_of
    done < <(lscpu --online --parse=CPU,SOCKET)
    IFS=, read -ra ranges <<< "$allowed"
    for range in "${ranges[@]}"; do
        for (( cpu = ${range%-*}; cpu <= ${range#*-}; cpu++ )); do
            socket_of=${cpus[cpu]:-}
            [[ -n "$socket_of" ]] || { echo "Not rotating the loader: CPU $cpu is not online."; return 0; }
            sockets[socket_of]+=${sockets[socket_of]:+,}$cpu
        done
    done
    (( ${#sockets[@]} == 2 )) || {
        echo "Not rotating the loader: CPUs $allowed are on ${#sockets[@]} socket(s)."
        return 0
    }
    until (( ready )); do
        (( SECONDS - started < 1800 )) || { echo 'The model is still loading after 30 min; the loader stays where it is.'; break; }
        for list in "${sockets[@]}"; do
            # Fails once the server has exited.
            taskset -pc "$list" "$pid" > /dev/null 2>&1 || return 0
            sleep 0.2
            # Polling after every move gives both sockets the same share of the time.
            if curl --silent --fail --max-time 1 --output /dev/null "http://127.0.0.1:$port/health"; then
                ready=1
                break
            fi
        done
    done
    # Threads created during the load inherited one socket's CPUs.
    taskset -a -pc "$allowed" "$pid" > /dev/null 2>&1 || return 0
    echo "Loader rotation ended after $((SECONDS - started)) s. Memory of the server per NUMA node, in MiB:"
    numastat -p "$pid" | awk '$1 == "Node" || $1 == "Total"' || true
}
# Internal: run COMMAND under this process ID with the rotation beside it.
if [[ ${1:-} == --rotate-load ]]; then
    shift
    rotate_load $$ "$@" >&2 &
    exec "$@"
fi

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
threads=${Z8_INFER_THREADS:-12}
threads_batch=${Z8_INFER_THREADS_BATCH:-$threads}
batch=${BATCH_SIZE:-512}
# Microbatches above 32 tokens only read the expert cache, so reading a prompt keeps the experts of
# generation in it and uploads each expert once per microbatch.
ubatch=${UBATCH_SIZE:-512}
# Once the cache is full, the CPU computes this share of the misses from host memory instead of
# waiting for an upload. Reading the host experts scales with threads up to the memory bandwidth.
cpu_share=${MOE_CACHE_CPU_SHARE:-0.9}
cache_mib=${MOE_CACHE_MIB:-36864}
# Where the 123 GiB of routed experts live on the host. The Engram is read by row from its mapping
# on the PMem volume in every mode.
#   tiered  ordinary memory: DDR4 first, and the kernel moves copies that are not read, such as
#           experts held in the GPU cache or an idle model, to PMem. Uploads are not pinned.
#   pinned  CUDA pinned memory: fastest uploads, but 123 GiB of DDR4 stay taken while it runs.
#   pmem    mapped from the DAX file: no DDR4, every upload is copied from PMem by one thread.
# The kernel promotes a page back from PMem only under a policy that carries the NUMA balancing
# flag, which Linux accepts for a bind but not for interleaving. Demotion ignores the policy, so
# tiered binds to the DDR4 nodes; interleaving is kept where the host memory cannot move.
# The bind fills the DDR4 node of the loading thread first, so tiered also rotates that thread
# between the sockets while the model loads. LOAD_ROTATE=0 leaves it alone.
expert_memory=${EXPERT_MEMORY:-tiered}
rotate=()
case "$expert_memory" in
    tiered)
        placement=(--load-mode dio --no-host) policy=(--balancing --membind="$Z8_DRAM_INTERLEAVE")
        case ${LOAD_ROTATE:-1} in
            1) rotate=(bash "$(realpath -e -- "${BASH_SOURCE[0]}")" --rotate-load) ;;
            0) ;;
            *) echo 'LOAD_ROTATE must be 0 or 1' >&2; exit 2 ;;
        esac
        ;;
    pinned) placement=(--load-mode dio) policy=(--interleave="$Z8_DRAM_INTERLEAVE") ;;
    pmem) placement=(--load-mode mmap) policy=(--interleave="$Z8_DRAM_INTERLEAVE") ;;
    *) echo 'EXPERT_MEMORY must be tiered, pinned or pmem' >&2; exit 2 ;;
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

server=("${rotate[@]}" numactl "${policy[@]}" "$LLAMA_BUILD/bin/llama-server"
    --host 127.0.0.1 --port 18000 -m "$model" --alias deepseek-v4.1-flash-1017
    "${placement[@]}" --lazy-mode on --split-mode layer --tensor-split '1,1,1,1'
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
    --plan)
        # Simulated allocation from the file headers: for each card the model, context (KV and expert
        # cache) and compute buffers in MiB. Nothing is loaded.
        exec "$LLAMA_BUILD/bin/llama-fit-params" -m "$model" --fit off --fit-print on \
            "${placement[@]}" --lazy-mode on --split-mode layer --tensor-split '1,1,1,1' \
            --n-gpu-layers all --cpu-moe --moe-cache-mib "$cache_mib" --moe-cache-cpu-share "$cpu_share" \
            --batch-size "$batch" --ubatch-size "$ubatch" --ctx-size "$((slots * slot_ctx))" \
            -ctk "$kv_type" -ctv "$kv_type" "$kv_offload" "${attention[@]}"
        ;;
    --fit-cache)
        # Run while the server is loaded and has read a near-full context: the cache is split evenly,
        # so the card with the least free memory decides how much every card can still take.
        margin=${VRAM_MARGIN_MIB:-1024}
        [[ "$margin" =~ ^[0-9]{1,5}$ ]] || { echo 'Expected VRAM_MARGIN_MIB in MiB' >&2; exit 2; }
        cards=0 room=
        while IFS=', ' read -r uuid total free; do
            (( total - free >= cache_mib / 4 )) || {
                echo "No server with a $cache_mib MiB cache is loaded on $uuid" >&2; exit 1;
            }
            printf '%s: %s MiB free\n' "$uuid" "$free"
            if [[ -z "$room" ]] || (( free < room )); then room=$free; fi
            cards=$((cards + 1))
        done < <(nvidia-smi --id="$CUDA_VISIBLE_DEVICES" --query-gpu=uuid,memory.total,memory.free \
            --format=csv,noheader,nounits)
        (( cards == 4 )) || { echo 'Expected four cards from nvidia-smi' >&2; exit 1; }
        printf 'MOE_CACHE_MIB=%s keeps %s MiB free on the fullest card\n' \
            "$(( (cache_mib + cards * (room - margin)) / 64 * 64 ))" "$margin"
        ;;
    *) echo 'Usage: serve-llama.sh [--plan | --fit-cache | --tune [TUNER_OPTIONS]]' >&2; exit 2 ;;
esac
