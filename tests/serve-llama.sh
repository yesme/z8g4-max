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
printf '%s ' "$@"
EOF
chmod +x "$tmp"/bin/*
export PATH="$tmp/bin:$PATH"
export LLAMA_BUILD="$tmp/build" DS41_GGUF="$tmp/model/model.gguf"
export CUDA_VISIBLE_DEVICES=GPU-0,GPU-1,GPU-2,GPU-3 Z8_DRAM_INTERLEAVE=0,1

default=$(bash "$tmp/serve.sh")
[[ "$default" == *' --cache-prompt '* && "$default" == *' --parallel 2 --ctx-size 16384 '* ]]
single=$(CACHE_PROMPT=0 SLOTS=1 SLOT_CTX=16384 Z8_INFER_THREADS=8 bash "$tmp/serve.sh")
[[ "$single" == *' --no-cache-prompt '* && "$single" == *' --parallel 1 --ctx-size 16384 '* ]]
[[ "$single" == *' --threads 8 --threads-batch 8 '* ]]
if SLOTS=2 SLOT_CTX=16384 bash "$tmp/serve.sh" > "$tmp/invalid.log" 2>&1; then
    echo 'Launcher accepted two 16K slots' >&2
    exit 1
fi
grep -Fq 'SLOTS=1 SLOT_CTX=16384' "$tmp/invalid.log"
echo 'llama.cpp launcher tests passed: prefix caching, slot budget and generated threads.'
