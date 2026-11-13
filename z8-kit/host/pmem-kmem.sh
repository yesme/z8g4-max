#!/usr/bin/env bash
set -euo pipefail
: "${Z8_DAX0_UUID:?Set the socket 0 devdax namespace UUID}"
: "${Z8_DAX1_UUID:?Set the socket 1 devdax namespace UUID}"
[[ "$Z8_DAX0_UUID" != "$Z8_DAX1_UUID" ]] || exit 2
[[ ${Z8_ENABLE_DEMOTION:-0} =~ ^[01]$ ]] || exit 2
memmap=${Z8_MEMMAP_ON_MEMORY:-0}
[[ "$memmap" =~ ^[01]$ ]] || exit 2
if [[ "$memmap" == 1 ]]; then
    parameter=/sys/module/memory_hotplug/parameters/memmap_on_memory
    if [[ ! -r "$parameter" ]] || [[ $(<"$parameter") != Y ]]; then
        echo 'Boot with memory_hotplug.memmap_on_memory=on before enabling Z8_MEMMAP_ON_MEMORY' >&2
        exit 1
    fi
fi
namespaces=$(ndctl list --namespaces --device-dax)
devices=()
pending=()
for uuid in "$Z8_DAX0_UUID" "$Z8_DAX1_UUID"; do
    name=$(jq -er --arg id "$uuid" '
      [(if type == "array" then .[] else . end)
        | select(.uuid == $id and .mode == "devdax")
        | .daxregion.devices[]? | .chardev]
      | if length == 1 then .[0] else error("Expected one DAX device per namespace") end
    ' <<< "$namespaces")
    [[ "$name" =~ ^dax[0-9]+\.[0-9]+$ && -d "/sys/bus/dax/devices/$name" ]] || exit 2
    devices+=("$name")
done
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
            printf '%s already in system-ram mode\n' "$device"
            ;;
        *) echo "Unexpected driver $driver for $device" >&2; exit 1 ;;
    esac
done
for device in "${pending[@]}"; do
    daxctl reconfigure-device --mode=system-ram "$device"
done
if [[ ${Z8_ENABLE_DEMOTION:-0} == 1 ]]; then
    printf '1\n' > /sys/kernel/mm/numa/demotion_enabled
fi
numactl --hardware
