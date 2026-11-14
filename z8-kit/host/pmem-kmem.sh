#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=z8-kit/host/pmem-device-wait.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/pmem-device-wait.sh"
: "${Z8_DAX0_UUID:?Set the socket 0 devdax namespace UUID}"
: "${Z8_DAX1_UUID:?Set the socket 1 devdax namespace UUID}"
[[ ${Z8_ENABLE_DEMOTION:-0} =~ ^[01]$ ]] || exit 2
memmap=${Z8_MEMMAP_ON_MEMORY:-0}
[[ "$memmap" =~ ^[01]$ ]] || exit 2
if [[ "$memmap" == 1 ]]; then
    parameter=/sys/module/memory_hotplug/parameters/memmap_on_memory
    if [[ ! -r "$parameter" ]] || [[ ! $(<"$parameter") =~ ^(Y|force)$ ]]; then
        echo 'Boot with memory_hotplug.memmap_on_memory=on or force before enabling Z8_MEMMAP_ON_MEMORY' >&2
        exit 1
    fi
fi
kmem_state() {
    daxctl list --devices --dev "$1" | jq -er --arg name "$1" '
      [ (if type == "array" then .[] else . end) | select(.chardev == $name) ]
      | if length != 1 then error("Expected one DAX device: " + $name) else .[0] end
      | if .mode != "system-ram" or (.total_memblocks // 0) <= 0
           or (.online_memblocks // -1) < 0 then error("Cannot verify memory blocks: " + $name)
        elif .online_memblocks < .total_memblocks then "pending"
        elif .online_memblocks == .total_memblocks and .movable == true then "ready"
        else error("Memory blocks are not all online and movable: " + $name) end
    '
}

names=$(pmem_wait_devices devdax "$Z8_DAX0_UUID" "$Z8_DAX1_UUID")
mapfile -t devices <<< "$names"
printf 'Both devdax namespaces ready after %ss\n' "$SECONDS"
pending=()
partially_online=()
for device in "${devices[@]}"; do
    sysfs="/sys/bus/dax/devices/$device"
    driver=$(readlink "$sysfs/driver") || {
        echo "$device has no DAX driver" >&2
        exit 1
    }
    case "${driver##*/}" in
        device_dax|device-dax)
            if [[ "$memmap" == 1 ]]; then
                if ! printf '1\n' > "$sysfs/memmap_on_memory"; then
                    echo "Cannot enable memmap_on_memory for $device" >&2
                    exit 1
                fi
            fi
            pending+=("$device")
            ;;
        kmem|dax_kmem)
            if [[ "$memmap" == 1 ]] && [[ $(cat "$sysfs/memmap_on_memory") != 1 ]]; then
                echo "$device is already bound to kmem without memmap_on_memory. Reboot to apply." >&2
                exit 1
            fi
            state=$(kmem_state "$device")
            if [[ "$state" == pending ]]; then
                partially_online+=("$device")
            else
                printf '%s already online as movable system RAM\n' "$device"
            fi
            ;;
        *) echo "Unexpected driver $driver for $device" >&2; exit 1 ;;
    esac
done
for device in "${pending[@]}"; do
    start=$SECONDS
    daxctl reconfigure-device --mode=system-ram "$device"
    [[ $(kmem_state "$device") == ready ]] || { echo "$device is not fully online" >&2; exit 1; }
    printf '%s online after %ss\n' "$device" "$((SECONDS - start))"
done
for device in "${partially_online[@]}"; do
    start=$SECONDS
    daxctl online-memory "$device"
    [[ $(kmem_state "$device") == ready ]] || { echo "$device is not fully online" >&2; exit 1; }
    printf '%s finished onlining after %ss\n' "$device" "$((SECONDS - start))"
done
if [[ ${Z8_ENABLE_DEMOTION:-0} == 1 ]]; then
    printf '1\n' > /sys/kernel/mm/numa/demotion_enabled
fi
numactl --hardware
