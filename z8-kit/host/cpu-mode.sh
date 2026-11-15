#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source /etc/z8-infer-cpu.env
case "${1:-}" in
    reserve)
        cpus=${Z8_BUILD_CPUS:?Set Z8_BUILD_CPUS with cpu-layout.py}
        ;;
    restore)
        # The idle mask includes both threads of every inference core.
        cpus=${Z8_IDLE_CPUS:?Set Z8_IDLE_CPUS with cpu-layout.py}
        ;;
    *)
        echo "Usage: $0 reserve|restore" >&2
        exit 2
        ;;
esac

result=0
for slice in system.slice user.slice machine.slice z8build.slice; do
    if ! systemctl set-property --runtime "$slice" "AllowedCPUs=$cpus"; then
        echo "Cannot update $slice" >&2
        result=1
    fi
done
exit "$result"
