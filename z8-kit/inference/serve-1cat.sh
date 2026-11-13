#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 2 ]]; then
    echo "Usage: bash $0 /path/to/1Cat-vLLM /absolute/path/to/profile.yaml" >&2
    exit 2
fi
: "${CUDA_VISIBLE_DEVICES:?Set four verified V100 GPU UUIDs in TP order}"
: "${VLLM_API_KEY:?Set a local API key before launching}"
if [[ ! $CUDA_VISIBLE_DEVICES =~ ^GPU-[a-fA-F0-9-]+(,GPU-[a-fA-F0-9-]+){3}$ ]]; then
    echo 'CUDA_VISIBLE_DEVICES must contain four comma-separated GPU UUIDs.' >&2
    exit 2
fi
repo=$(realpath "$1")
config=$(realpath "$2")
python_bin=${ONECAT_PYTHON:-$repo/.venv/bin/python}
export CUDA_DEVICE_ORDER=PCI_BUS_ID
export VLLM_WORKER_MULTIPROC_METHOD=spawn
export VLLM_NO_USAGE_STATS=1
export OMP_NUM_THREADS=${OMP_NUM_THREADS:-1}
export VLLM_V41_DOWN_ROWS=${VLLM_V41_DOWN_ROWS:-1}
export VLLM_V41_PACKED_KV=${VLLM_V41_PACKED_KV:-0}
export VLLM_V41_SESSION_PREFIX=${VLLM_V41_SESSION_PREFIX:-0}
export VLLM_V41_ASYNC=${VLLM_V41_ASYNC:-0}
cd "$repo"
exec "$python_bin" -m vllm.entrypoints.openai.api_server --config "$config"
