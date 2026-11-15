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
chmod +x "$tmp"/bin/*
export PATH="$tmp/bin:$PATH"
export LLAMA_BUILD="$tmp/build" DS41_GGUF="$tmp/model/model.gguf"
export CUDA_VISIBLE_DEVICES=GPU-0,GPU-1,GPU-2,GPU-3 Z8_DRAM_INTERLEAVE=0,1

default=$(GGML_CUDA_P2P=1 bash "$tmp/serve.sh")
[[ "$default" == 'p2p=unset '* ]]
[[ "$default" == *' --cache-prompt '* && "$default" == *' --parallel 1 --ctx-size 131072 '* ]]
[[ "$default" == *' --threads 4 --threads-batch 4 '* && "$default" == *' -ctk f16 -ctv f16 --kv-offload '* ]]
[[ "$default" != *' --flash-attn '* ]]

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
reject 'positive SLOTS' SLOTS=0
reject 'positive SLOTS' SLOTS=18446744073709551616
reject 'positive SLOT_CTX' SLOT_CTX=-1
reject 'KV_TYPE must be' KV_TYPE=fp8
reject 'KV_OFFLOAD must be' KV_OFFLOAD=2
echo 'llama.cpp launcher tests passed: 128K single-slot default, optional slots, KV placement, and context bounds.'
