#include <cuda_runtime.h>
#include <sys/mman.h>

#include <chrono>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <string_view>
#include <thread>
#include <vector>

void require_cuda(cudaError_t status) {
    if (status != cudaSuccess) {
        std::cerr << cudaGetErrorString(status) << '\n';
        std::exit(1);
    }
}

int main(int argc, char** argv) {
    if (argc < 3 || argc > 4) {
        std::cerr << "Usage: pinned-copy MiB_per_GPU repetitions [both|h2d|d2h]\n";
        return 2;
    }
    const std::string_view direction = argc == 4 ? argv[3] : "both";
    if (direction != "both" && direction != "h2d" && direction != "d2h") {
        std::cerr << "Direction must be both, h2d or d2h\n";
        return 2;
    }
    char* end = nullptr;
    const auto mib = std::strtoul(argv[1], &end, 10);
    if (*end != '\0' || mib == 0 || mib > 4096) {
        std::cerr << "MiB_per_GPU must be 1..4096\n";
        return 2;
    }
    const auto repeats = std::strtoul(argv[2], &end, 10);
    if (*end != '\0' || repeats == 0 || repeats > 100000) {
        std::cerr << "Repetitions must be 1..100000\n";
        return 2;
    }
    const size_t bytes = mib * (1UL << 20);
    int count = 0;
    require_cuda(cudaGetDeviceCount(&count));
    if (count < 1 || count > 4) {
        std::cerr << "Expose one to four V100 GPUs with CUDA_VISIBLE_DEVICES\n";
        return 2;
    }
    std::vector<void*> host(count), gpu(count);
    for (int i = 0; i < count; ++i) {
        cudaDeviceProp info{};
        require_cuda(cudaGetDeviceProperties(&info, i));
        if (info.major != 7 || info.minor != 0) {
            std::cerr << "Device " << i << " is not sm_70\n";
            return 2;
        }
        require_cuda(cudaSetDevice(i));
        host[i] = mmap(nullptr, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (host[i] == MAP_FAILED) {
            std::cerr << "mmap failed\n";
            return 1;
        }
        // Fault in the anonymous pages under the caller's NUMA policy before CUDA registers them.
        auto* pages = static_cast<volatile unsigned char*>(host[i]);
        for (size_t offset = 0; offset < bytes; offset += 4096) {
            pages[offset] = 42;
        }
        require_cuda(cudaHostRegister(host[i], bytes, cudaHostRegisterPortable));
        require_cuda(cudaMalloc(&gpu[i], bytes));
        require_cuda(cudaMemcpy(gpu[i], host[i], bytes, cudaMemcpyHostToDevice));
    }
    auto copy = [&](cudaMemcpyKind kind, const char* name) {
        const auto start = std::chrono::steady_clock::now();
        std::vector<std::thread> threads;
        for (int i = 0; i < count; ++i) {
            threads.emplace_back([&, i] {
                require_cuda(cudaSetDevice(i));
                const bool h2d = kind == cudaMemcpyHostToDevice;
                for (unsigned long n = 0; n < repeats; ++n) {
                    require_cuda(cudaMemcpy(h2d ? gpu[i] : host[i], h2d ? host[i] : gpu[i], bytes, kind));
                }
            });
        }
        for (auto& thread : threads) {
            thread.join();
        }
        const double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
        std::cout << name << " aggregate GB/s: " << std::fixed << std::setprecision(2)
                  << static_cast<double>(bytes) * count * repeats / seconds / 1e9 << '\n';
    };
    if (direction != "d2h") copy(cudaMemcpyHostToDevice, "H2D");
    if (direction != "h2d") copy(cudaMemcpyDeviceToHost, "D2H");
    for (int i = 0; i < count; ++i) {
        require_cuda(cudaSetDevice(i));
        require_cuda(cudaFree(gpu[i]));
        require_cuda(cudaHostUnregister(host[i]));
        munmap(host[i], bytes);
    }
}
