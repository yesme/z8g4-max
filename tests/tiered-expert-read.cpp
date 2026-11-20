#include "../z8-kit/inference/tiered-expert-read.h"

#include <array>
#include <cassert>
#include <cstdio>
#include <sched.h>
#include <thread>

using Nodes = std::array<unsigned long, 16>;
constexpr unsigned long maxnode = sizeof(Nodes) * CHAR_BIT;
constexpr int binding = MPOL_BIND | MPOL_F_NUMA_BALANCING;

int policy(Nodes & nodes) {
    int mode = 0;
    assert(syscall(SYS_get_mempolicy, &mode, nodes.data(), maxnode, nullptr, 0UL) == 0);
    return mode;
}

int main() {
    assert(!z8_cgroup_anon_by_node().empty());
    const char * expert = "blk.0.ffn_down_exps.weight";
    const auto loader = std::this_thread::get_id();
    unsetenv("Z8_INTERLEAVE_EXPERT_READS");
    z8_read_host_tensor(expert, [&] { assert(std::this_thread::get_id() == loader); });
    setenv("Z8_INTERLEAVE_EXPERT_READS", "1", 1);
    z8_read_host_tensor("blk.0.ffn_down_shexp.weight", [&] { assert(std::this_thread::get_id() == loader); });

    z8_read_host_tensor("blk.0.ffn_down_exps.weight_scale", [&] { assert(std::this_thread::get_id() == loader); });

    Nodes allowed{};
    if (syscall(SYS_get_mempolicy, nullptr, allowed.data(), maxnode, nullptr,
                static_cast<unsigned long>(MPOL_F_MEMS_ALLOWED)) < 0) {
        if (errno != EPERM && errno != ENOSYS) return 1;
        std::puts("Kernel NUMA policy test skipped (syscall unavailable).");
        return 0;
    }
    assert(syscall(SYS_set_mempolicy, binding, allowed.data(), maxnode) == 0);
    cpu_set_t cpus;
    assert(sched_getaffinity(0, sizeof(cpus), &cpus) == 0);
    int calls = 0;
    z8_read_host_tensor(expert, [&] {
        assert(std::this_thread::get_id() != loader);
        Nodes actual{};
        assert(policy(actual) == MPOL_INTERLEAVE && actual == allowed);
        cpu_set_t reader_cpus;
        assert(sched_getaffinity(0, sizeof(reader_cpus), &reader_cpus) == 0);
        assert(CPU_EQUAL(&reader_cpus, &cpus));
        ++calls;
    });
    try {
        z8_read_host_tensor(expert, [] { throw std::system_error(EIO, std::generic_category()); });
        return 1;
    } catch (const std::system_error & error) {
        assert(error.code().value() == EIO);
    }
    Nodes after{};
    assert(calls == 1 && policy(after) == binding && after == allowed);
    assert(syscall(SYS_set_mempolicy, MPOL_DEFAULT, nullptr, 0UL) == 0);
    try {
        z8_read_host_tensor(expert, [] { assert(false && "should reject missing bind before reading"); });
        return 1;
    } catch (const std::runtime_error &) {}
    std::puts("Expert read policy, affinity, synchronous completion and error propagation passed.");
}
