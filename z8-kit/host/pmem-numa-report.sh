#!/usr/bin/env bash
set -euo pipefail
pid=${1:-}
[[ -z "$pid" || "$pid" =~ ^[0-9]+$ ]] || { echo 'Expected a numeric PID' >&2; exit 2; }

show() {
    printf '\n%s\n' "$*"
    if command -v "$1" >/dev/null; then
        "$@" || printf 'Command exited with status %s\n' "$?"
    fi
}

show date -Is
show numactl --hardware
show lscpu -e=CPU,NODE,SOCKET,CORE,ONLINE
show ipmctl show -region
show ndctl list -RNu
show daxctl list -RDu
show lsblk -o NAME,PATH,TYPE,SIZE,MODEL,FSTYPE,MOUNTPOINTS
show findmnt -t xfs,ext4,zfs
show swapon --show
show nvidia-smi topo -m
show nvidia-smi nvlink -s

printf '\n[Memory tiers and NUMA migration]\n'
for path in /sys/devices/virtual/memory_tiering/memory_tier*/nodelist \
            /sys/kernel/mm/numa/demotion_enabled /proc/sys/kernel/numa_balancing; do
    [[ -r "$path" ]] && printf '%s %s\n' "$path" "$(cat "$path")"
done
awk '/^(pgdemote_|pgpromote_|pgmajfault|numa_|nr_foll_pin_|nr_mlock|nr_unevictable|pswp|allocstall_|kswapd_(low|high)_wmark_hit_quickly)/' /proc/vmstat

# One socket can run short while the machine-wide sums look fine.
printf '\n[Zone watermarks per node, in pages]\n'
awk '/^Node / { sub(",", "", $2); zone = "node" $2 " " $4 }
     $1 == "pages" && $2 == "free" { free = $3 }
     NF == 2 && $1 ~ /^(min|low|high|promo)$/ { mark[$1] = $2 }
     NF == 2 && $1 == "managed" && $2 > 0 {
         print zone, "free=" free, "min=" mark["min"], "low=" mark["low"], "high=" mark["high"],
               "promo=" mark["promo"], "managed=" $2 }' /proc/zoneinfo
printf '\n[Allocation, demotion and promotion counters per node]\n'
(cd /sys/devices/system/node && grep -HE '^(numa_(hit|miss|foreign|local|other)|pgdemote_|pgpromote_)' node[0-9]*/vmstat) || true
for resource in memory io cpu; do
    [[ ! -r "/proc/pressure/$resource" ]] || show cat "/proc/pressure/$resource"
done

if [[ -n "$pid" ]]; then
    [[ -r "/proc/$pid/status" ]] || { echo "Cannot inspect PID $pid" >&2; exit 1; }
    show numastat -p "$pid"
    awk '/^(VmRSS|VmLck|VmPin|Mems_allowed_list|Cpus_allowed_list):/' "/proc/$pid/status"
    cg=$(awk -F: '$1 == "0" { print $3 }' "/proc/$pid/cgroup")
    if [[ "$cg" == /* && "$cg" != *..* ]]; then
        for name in memory.numa_stat memory.events memory.swap.current memory.pressure; do
            path="/sys/fs/cgroup$cg/$name"
            [[ ! -r "$path" ]] || show cat "$path"
        done
    fi
fi
