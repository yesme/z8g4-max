#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
df -h / /var/lib
kit="$(pwd -P)"
checks="$HOME/z8-burnin/cuda-check"
sudo apt update
sudo apt install docker.io numactl
sudo systemctl enable --now docker.service
mkdir -p "$checks"
sudo docker run --rm -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    -v "$kit:/kit:ro" -v "$checks:/out" -w /tmp \
    nvidia/cuda:12.9.1-devel-ubuntu24.04 bash -euc '
        apt-get update
        apt-get install -y build-essential cmake git ca-certificates
        dpkg-query -W libnccl-dev
        git clone --depth 1 --branch v12.9 https://github.com/NVIDIA/cuda-samples.git
        git clone --depth 1 --branch v2.17.7 https://github.com/NVIDIA/nccl-tests.git
        git clone --depth 1 https://github.com/wilicc/gpu-burn.git
        for src in cuda-samples nccl-tests gpu-burn; do
            printf "%s %s\n" "$src" "$(git -C "$src" rev-parse HEAD)"
        done > /out/revisions.txt
        cmake -S cuda-samples/Samples/5_Domain_Specific/p2pBandwidthLatencyTest -B p2p
        cmake --build p2p -j 8
        make -C nccl-tests -j 8 CUDA_HOME=/usr/local/cuda
        make -C gpu-burn -j 8 COMPUTE=70
        nvcc -O3 -std=c++17 -arch=sm_70 -Xcompiler=-pthread \
            /kit/host/pinned-copy.cu -o /out/pinned-copy
        cp p2p/p2pBandwidthLatencyTest nccl-tests/build/all_reduce_perf \
            gpu-burn/gpu_burn gpu-burn/compare.fatbin /out/
        mkdir -p /out/lib
        for library in libcudart.so.12 libcublas.so.12 libcublasLt.so.12 libnvJitLink.so.12; do
            cp -L "/usr/local/cuda/targets/x86_64-linux/lib/$library" /out/lib/
        done
        cp -L /usr/lib/x86_64-linux-gnu/libnccl.so.2 /out/lib/
        chown -R "$HOST_UID:$HOST_GID" /out
    '

printf 'CUDA test tools: %s\n' "$checks"
