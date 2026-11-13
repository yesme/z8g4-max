#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 2 ]]; then
    echo "Usage: sudo bash $0 check|start /absolute/path/to/pairs.tsv" >&2
    exit 2
fi
action=$1
[[ $action == check || $action == start ]] || { echo 'Expected check or start' >&2; exit 2; }
if (( EUID != 0 )); then
    echo 'Run as root to query and assemble mapped devices.' >&2
    exit 2
fi

declare -a disks=() caches=()
declare -A seen=()
while IFS=$'\t' read -r disk cache extra || [[ -n "${disk:-}" ]]; do
    [[ -z "$disk" || "$disk" == \#* ]] && continue
    [[ -z "$extra" && "$disk" == /dev/disk/by-id/* ]] || exit 2
    for device in "$disk" "$cache"; do
        [[ -z "$device" ]] && continue
        [[ "$device" == /dev/disk/by-id/* ]] || exit 2
        [[ -b "$device" ]] || continue
        resolved=$(readlink -f -- "$device")
        [[ -z ${seen[$resolved]:-} ]] || { echo "Duplicate $resolved" >&2; exit 2; }
        seen[$resolved]=1
    done
    disks+=("$disk")
    caches+=("$cache")
done < "$2"

(( ${#disks[@]} > 0 )) || { echo 'No mapping rows found' >&2; exit 2; }
if [[ $action == start ]]; then
    modprobe dm-zoned
fi
failed=0
for i in "${!disks[@]}"; do
    disk=${disks[i]}
    cache=${caches[i]}
    if [[ ! -b "$disk" || $(lsblk -dnro ZONED -- "$disk") != host-managed ]]; then
        echo "Missing or invalid host-managed disk: $disk" >&2
        failed=1
        continue
    fi
    devices=("$disk")
    if [[ -n "$cache" ]]; then
        if [[ ! -b "$cache" || $(lsblk -dnro ZONED -- "$cache") != none ]]; then
            echo "Missing or invalid conventional cache device: $cache" >&2
            failed=1
            continue
        fi
        devices=("$cache" "$disk")
    fi
    printf '%s %s\n' "$action" "${devices[*]}"
    dmzadm "--$action" "${devices[@]}" || failed=1
done
exit "$failed"
