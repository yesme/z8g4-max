#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source /etc/z8-infer-cpu.env
case "${1:-}" in
    reserve)
        cpus=${Z8_BUILD_CPUS:?Set Z8_BUILD_CPUS with cpu-layout.py}
        # Builds keep the inference threads' own CPUs: z8build.slice is an idle group, so it runs
        # there only while those threads sleep. The HT siblings stay empty for everyone.
        build_cpus=${Z8_BUILD_SHARED_CPUS:-$cpus}
        ;;
    restore)
        # The idle mask includes both threads of every inference core.
        cpus=${Z8_IDLE_CPUS:?Set Z8_IDLE_CPUS with cpu-layout.py}
        build_cpus=$cpus
        ;;
    *)
        echo "Usage: $0 reserve|restore" >&2
        exit 2
        ;;
esac

result=0
for slice in system.slice user.slice machine.slice z8build.slice; do
    allowed=$cpus
    [[ "$slice" != z8build.slice ]] || allowed=$build_cpus
    if ! systemctl set-property --runtime "$slice" "AllowedCPUs=$allowed"; then
        echo "Cannot update $slice" >&2
        result=1
    fi
done
exit "$result"
