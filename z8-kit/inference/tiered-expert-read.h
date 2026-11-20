#pragma once

#include <cstdlib>
#include <fstream>
#include <future>
#include <string>
#include <string_view>
#include <stdexcept>
#include <system_error>

#include <cerrno>
#include <climits>
#include <linux/mempolicy.h>
#include <sys/syscall.h>
#include <unistd.h>

// Only direct reads of routed feed-forward expert weights go through the reader.
// Mapped Engram, CUDA uploads, shared experts and other host tensors keep their normal paths.
template <class Read>
void z8_read_host_tensor(const char * name, Read read) {
    const std::string_view tensor(name);
    constexpr std::string_view suffix = "_exps.weight";
    if (!std::getenv("Z8_INTERLEAVE_EXPERT_READS") || tensor.find(".ffn_") == tensor.npos ||
            tensor.size() < suffix.size() || tensor.substr(tensor.size() - suffix.size()) != suffix) {
        read();
        return;
    }
    std::async(std::launch::async, [&] {
        unsigned long nodes[16] = {};
        constexpr unsigned long maxnode = sizeof(nodes) * CHAR_BIT;
        int mode = 0;
        if (syscall(SYS_get_mempolicy, &mode, nodes, maxnode, nullptr, 0UL) < 0) {
            throw std::system_error(errno, std::generic_category(), "get_mempolicy (expert reader)");
        }
        if (mode != (MPOL_BIND | MPOL_F_NUMA_BALANCING)) {
            throw std::runtime_error("expert reader requires numactl --balancing --membind");
        }
        if (syscall(SYS_set_mempolicy, MPOL_INTERLEAVE, nodes, maxnode) < 0) {
            throw std::system_error(errno, std::generic_category(), "set_mempolicy (expert reader)");
        }
        read();
    }).get();  // Join before the next seek. The temporary policy dies with this thread.
}

inline std::string z8_cgroup_anon_by_node() {
    std::ifstream membership("/proc/self/cgroup");
    std::string line;
    while (std::getline(membership, line)) {
        if (line.compare(0, 4, "0::/") != 0) continue;
        const auto group = line.substr(3);
        std::ifstream stats("/sys/fs/cgroup" + group + "/memory.numa_stat");
        while (std::getline(stats, line)) {
            if (line.compare(0, 5, "anon ") == 0) return group + " " + line;
        }
        break;
    }
    return "unavailable";
}
