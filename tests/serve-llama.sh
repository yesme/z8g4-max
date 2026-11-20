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
# Stand in for a server that is still loading.
case ${Z8_TEST_WAIT:-} in
    rotation)
        echo $$ > "$Z8_TEST_ROTATE/server.pid"
        for _ in {1..100}; do [[ -e "$Z8_TEST_ROTATE/numastat.args" ]] && break; sleep 0.1; done
        ;;
    brief) sleep 1 ;;
esac
EOF
# The loader rotation only runs in the tests that set Z8_TEST_ROTATE.
cat > "$tmp/bin/taskset" <<'EOF'
#!/usr/bin/env bash
pid=${*: -1}
[[ -n "${Z8_TEST_ROTATE:-}" ]] && kill -0 "$pid" 2>/dev/null || exit 1
echo "$*" >> "$Z8_TEST_ROTATE/taskset.log"
if [[ "$1" == -pc && $# == 2 ]]; then
    if [[ "${LC_ALL:-}" == C ]]; then
        echo "pid $pid's current affinity list: ${Z8_TEST_ALLOWED:-4-9,30-35}"
    else
        echo "pid $pid 的当前亲和力列表：${Z8_TEST_ALLOWED:-4-9,30-35}"
    fi
fi
EOF
cat > "$tmp/bin/lscpu" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == '--online --parse=CPU,SOCKET' ]] || exit 2
echo '# CPU,Socket'
for cpu in {0..51}; do echo "$cpu,$((cpu / 26))"; done
EOF
# The model is loaded at the fourth poll, after two moves to each socket.
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "${*: -1}" >> "$Z8_TEST_ROTATE/curl.log"
(( $(wc -l < "$Z8_TEST_ROTATE/curl.log") > 3 ))
EOF
cat > "$tmp/bin/numastat" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'Per-node process memory usage (in MBs) for PID 1 (llama-server)' \
    '                           Node 0          Node 1           Total' \
    'Heap                         1.00            2.00            3.00' \
    'Total                    62000.00        61000.00       123000.00'
echo "$*" > "$Z8_TEST_ROTATE/numastat.args"
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
[[ "$tuner" == "tuner $tmp/scripts/moe-cache-tune.py --max-mib 16384 -- bash $tmp/serve.sh --rotate-load numactl --balancing --membind=0,1 $tmp/build/bin/llama-server "* ]]
[[ "$tuner" == *' --threads 4 --threads-batch 4 '* && "$tuner" == *' --load-mode dio --no-host '* ]]
# Only the bind needs the loader rotation, and it can be turned off.
[[ $(LOAD_ROTATE=0 bash "$tmp/serve.sh" --tune) == "tuner $tmp/scripts/moe-cache-tune.py -- numactl --balancing --membind=0,1 "* ]]
[[ $(EXPERT_MEMORY=pinned bash "$tmp/serve.sh" --tune) == "tuner $tmp/scripts/moe-cache-tune.py -- numactl --interleave=0,1 "* ]]

# While the model loads, the main thread alternates between the CPUs of the two sockets. The server
# keeps its process ID through the wrapper, and every thread gets the full CPU list back at the end.
rotation="$tmp/rotation"
mkdir "$rotation"
env -u LC_ALL LANG=zh_CN.UTF-8 Z8_TEST_ROTATE="$rotation" Z8_TEST_WAIT=rotation bash "$tmp/serve.sh" > "$rotation/out" 2> "$rotation/err"
for _ in {1..50}; do grep -q '^Total' "$rotation/err" && break; sleep 0.1; done
[[ $(< "$rotation/out") == "p2p=unset --balancing --membind=0,1 $tmp/build/bin/llama-server "* ]]
pid=$(< "$rotation/server.pid")
mapfile -t calls < "$rotation/taskset.log"
(( ${#calls[@]} == 6 ))
[[ "${calls[0]}" == "-pc $pid" && "${calls[5]}" == "-a -pc 4-9,30-35 $pid" ]]
for i in 1 3; do [[ "${calls[i]}" == "-pc 4,5,6,7,8,9 $pid" && "${calls[i + 1]}" == "-pc 30,31,32,33,34,35 $pid" ]]; done
[[ $(sort -u "$rotation/curl.log") == http://127.0.0.1:18000/health && $(< "$rotation/numastat.args") == "-p $pid" ]]
grep -q '^Loader rotation ended after ' "$rotation/err"
grep -q '^Total  *62000.00  *61000.00' "$rotation/err" && ! grep -q '^Heap' "$rotation/err"
# The tuner appends its own port to the command.
rm "$rotation"/*
Z8_TEST_ROTATE="$rotation" Z8_TEST_WAIT=rotation bash "$tmp/serve.sh" --rotate-load numactl --port 18000 x --port 23456 > /dev/null 2> "$rotation/err"
[[ $(sort -u "$rotation/curl.log") == http://127.0.0.1:23456/health ]]
# CPUs on one socket leave nothing to alternate between.
rm "$rotation"/*
Z8_TEST_ROTATE="$rotation" Z8_TEST_ALLOWED=4-9 Z8_TEST_WAIT=brief bash "$tmp/serve.sh" > /dev/null 2> "$rotation/err"
grep -q '^Not rotating the loader: CPUs 4-9 are on 1 socket(s).' "$rotation/err"
[[ $(wc -l < "$rotation/taskset.log") == 1 && ! -e "$rotation/curl.log" ]]

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
reject 'LOAD_ROTATE must be' LOAD_ROTATE=2
reject 'positive SLOTS' SLOTS=0
reject 'positive SLOTS' SLOTS=18446744073709551616
reject 'positive SLOT_CTX' SLOT_CTX=-1
reject 'KV_TYPE must be' KV_TYPE=fp8
reject 'KV_OFFLOAD must be' KV_OFFLOAD=2
reject 'between 0 and 1' MOE_CACHE_CPU_SHARE=1.1
reject 'positive BATCH_SIZE' BATCH_SIZE=0
reject 'must not exceed' UBATCH_SIZE=513
reject 'positive Z8_INFER_THREADS_BATCH' Z8_INFER_THREADS_BATCH=-1
echo 'llama.cpp launcher tests passed: 128K single-slot default, expert memory modes, loader rotation, tuner command, memory plan, cache fit, optional slots, KV placement, and context bounds.'
