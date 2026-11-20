#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source /etc/z8-infer-cpu.env
case "${1:-}" in
    reserve)
        cpus=${Z8_BUILD_CPUS:?Set Z8_BUILD_CPUS with cpu-layout.py}
        # Builds keep the inference threads' own CPUs and become an idle group for that time, so they
        # run there only while those threads sleep. The HT siblings stay empty for everyone. Without
        # a shared set, builds keep the general CPUs and their normal weight.
        build_cpus=${Z8_BUILD_SHARED_CPUS:-$cpus}
        build_weight=idle
        [[ "$build_cpus" != "$cpus" ]] || build_weight=100
        ;;
    restore)
        # The idle mask includes both threads of every inference core.
        cpus=${Z8_IDLE_CPUS:?Set Z8_IDLE_CPUS with cpu-layout.py}
        build_cpus=$cpus
        # The weight that cpu-layout.py writes into z8build.slice.
        build_weight=100
        ;;
    *)
        echo "Usage: $0 reserve|restore" >&2
        exit 2
        ;;
esac

result=0
for slice in system.slice user.slice machine.slice z8build.slice; do
    properties=("AllowedCPUs=$cpus")
    [[ "$slice" != z8build.slice ]] || properties=("AllowedCPUs=$build_cpus" "CPUWeight=$build_weight")
    if ! systemctl set-property --runtime "$slice" "${properties[@]}"; then
        echo "Cannot update $slice" >&2
        result=1
    fi
done
exit "$result"
