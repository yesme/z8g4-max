#!/usr/bin/env bash
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -r -- "$tmp"' EXIT
mkdir "$tmp/bin" "$tmp/model"
touch "$tmp/model/model.gguf"
sed "s@/srv/pmem-model@$tmp/model@g" z8-kit/inference/serve-llama.sh > "$tmp/serve.sh"
cat > "$tmp/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *"-t xfs -O dax=always" ]]
EOF
cat > "$tmp/bin/numactl" <<'EOF'
#!/usr/bin/env bash
printf 'p2p=%s ' "${GGML_CUDA_P2P:-unset}"
printf '%s ' "$@"
EOF
cat > "$tmp/bin/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == '--id=GPU-0,GPU-1,GPU-2,GPU-3 --query-gpu=uuid,memory.total,memory.free --format=csv,noheader,nounits' ]]
printf 'GPU-%s, 16160, %s\n' 0 2400 1 2300 2 2500 3 "${Z8_TEST_FREE:-1900}"
EOF
cat > "$tmp/bin/python3" <<'EOF'
#!/usr/bin/env bash
printf 'tuner '
printf '%s ' "$@"
EOF
chmod +x "$tmp"/bin/*
export PATH="$tmp/bin:$PATH"
export LLAMA_BUILD="$tmp/build" DS41_GGUF="$tmp/model/model.gguf"
export CUDA_VISIBLE_DEVICES=GPU-0,GPU-1,GPU-2,GPU-3 Z8_DRAM_INTERLEAVE=0,1

default=$(GGML_CUDA_P2P=1 bash "$tmp/serve.sh")
[[ "$default" == "p2p=unset --balancing --membind=0,1 $tmp/build/bin/llama-server "* ]]
[[ "$default" == *' --cache-prompt '* && "$default" == *' --parallel 1 --ctx-size 131072 '* ]]
[[ "$default" == *' --threads 12 --threads-batch 12 '* && "$default" == *' -ctk f16 -ctv f16 --kv-offload '* ]]
[[ "$default" != *' --flash-attn '* ]]
[[ "$default" == *' --moe-cache-mib 36864 --moe-cache-cpu-share 0.9 '* ]]
[[ "$default" == *' --batch-size 512 --ubatch-size 512 '* && "$default" == *' --load-mode dio --no-host --lazy-mode on '* ]]
# Only the movable placement needs promotion; the other two keep interleaving.
[[ $(EXPERT_MEMORY=pinned bash "$tmp/serve.sh") == "p2p=unset --interleave=0,1 $tmp/build/bin/llama-server "*' --load-mode dio --lazy-mode on '* ]]
[[ $(EXPERT_MEMORY=pmem bash "$tmp/serve.sh") == "p2p=unset --interleave=0,1 $tmp/build/bin/llama-server "*' --load-mode mmap --lazy-mode on '* ]]

# The tuner receives the unchanged server command after its own options.
tuner=$(Z8_INFER_THREADS=4 bash "$tmp/serve.sh" --tune --max-mib 16384)
[[ "$tuner" == "tuner $tmp/scripts/moe-cache-tune.py --max-mib 16384 -- numactl --balancing --membind=0,1 $tmp/build/bin/llama-server "* ]]
[[ "$tuner" == *' --threads 4 --threads-batch 4 '* && "$tuner" == *' --load-mode dio --no-host '* ]]

tuned=$(MOE_CACHE_CPU_SHARE=0.25 BATCH_SIZE=1024 UBATCH_SIZE=256 Z8_INFER_THREADS_BATCH=8 bash "$tmp/serve.sh")
[[ "$tuned" == *' --moe-cache-cpu-share 0.25 '* && "$tuned" == *' --threads 12 --threads-batch 8 --batch-size 1024 --ubatch-size 256 '* ]]

dual=$(SLOTS=2 KV_TYPE=q8_0 Z8_NVLINK_P2P=1 bash "$tmp/serve.sh")
[[ "$dual" == 'p2p=1 '* && "$dual" == *' --parallel 2 --ctx-size 131072 '* ]]
[[ "$dual" == *' -ctk q8_0 -ctv q8_0 --kv-offload --flash-attn on '* ]]

host=$(CACHE_PROMPT=0 SLOTS=2 SLOT_CTX=131072 Z8_INFER_THREADS=8 KV_OFFLOAD=0 bash "$tmp/serve.sh")
[[ "$host" == *' --no-cache-prompt '* && "$host" == *' --parallel 2 --ctx-size 262144 '* ]]
[[ "$host" == *' --threads 8 --threads-batch 8 '* && "$host" == *' -ctk f16 -ctv f16 --no-kv-offload '* ]]

aligned=$(SLOTS=1 SLOT_CTX=65537 KV_TYPE=q4_0 bash "$tmp/serve.sh")
[[ "$aligned" == *' --parallel 1 --ctx-size 65792 '* ]]
[[ "$aligned" == *' -ctk q4_0 -ctv q4_0 --kv-offload --flash-attn on '* ]]

reject() {
    local expected=$1
    shift
    if env "$@" bash "$tmp/serve.sh" > "$tmp/invalid.log" 2>&1; then
        printf 'Launcher unexpectedly accepted: %s\n' "$*" >&2
        exit 1
    fi
    grep -Fq "$expected" "$tmp/invalid.log"
}
reject 'Total context exceeds' SLOTS=2 SLOT_CTX=600000
reject 'Total context exceeds' SLOTS=3 SLOT_CTX=349525

# The fullest card has 1900 MiB free: every card can give 1900 - 1024 MiB more to the cache.
fitted=$(bash "$tmp/serve.sh" --fit-cache)
[[ "$fitted" == *'GPU-3: 1900 MiB free'* && "$fitted" == *'MOE_CACHE_MIB=40320 keeps 1024 MiB free'* ]]
[[ $(VRAM_MARGIN_MIB=2048 bash "$tmp/serve.sh" --fit-cache) == *'MOE_CACHE_MIB=36224 keeps 2048 MiB free'* ]]
[[ $(Z8_TEST_FREE=512 bash "$tmp/serve.sh" --fit-cache) == *'MOE_CACHE_MIB=34816 keeps 1024 MiB free'* ]]

# The plan uses the same placement, cache and context as the server.
mkdir "$tmp/build" "$tmp/build/bin"
cat > "$tmp/build/bin/llama-fit-params" <<'EOF'
#!/usr/bin/env bash
printf 'plan '
printf '%s ' "$@"
EOF
chmod +x "$tmp/build/bin/llama-fit-params"
plan=$(SLOT_CTX=65536 KV_TYPE=q8_0 bash "$tmp/serve.sh" --plan)
[[ "$plan" == "plan -m $tmp/model/model.gguf --fit off --fit-print on --load-mode dio --no-host "* ]]
[[ "$plan" == *' --cpu-moe --moe-cache-mib 36864 '* && "$plan" == *' --ubatch-size 512 --ctx-size 65536 -ctk q8_0 -ctv q8_0 --kv-offload --flash-attn on '* ]]
if Z8_TEST_FREE=12000 bash "$tmp/serve.sh" --fit-cache > "$tmp/unloaded.log" 2>&1; then exit 1; fi
grep -Fq 'No server with a 36864 MiB cache is loaded on GPU-3' "$tmp/unloaded.log"
reject 'EXPERT_MEMORY must be' EXPERT_MEMORY=mlock
reject 'positive SLOTS' SLOTS=0
reject 'positive SLOTS' SLOTS=18446744073709551616
reject 'positive SLOT_CTX' SLOT_CTX=-1
reject 'KV_TYPE must be' KV_TYPE=fp8
reject 'KV_OFFLOAD must be' KV_OFFLOAD=2
reject 'between 0 and 1' MOE_CACHE_CPU_SHARE=1.1
reject 'positive BATCH_SIZE' BATCH_SIZE=0
reject 'must not exceed' UBATCH_SIZE=513
reject 'positive Z8_INFER_THREADS_BATCH' Z8_INFER_THREADS_BATCH=-1
echo 'llama.cpp launcher tests passed: 128K single-slot default, expert memory modes, tuner command, memory plan, cache fit, optional slots, KV placement, and context bounds.'
