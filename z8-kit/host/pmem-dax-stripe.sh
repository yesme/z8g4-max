#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 3 || ( $1 != show && $1 != create ) ]]; then
    echo "Usage: bash $0 show|create FSDAX_NAMESPACE_UUID0 FSDAX_NAMESPACE_UUID1" >&2
    exit 2
fi
mode=$1
shift
chunk_sectors=4096  # 2 MiB
devices=()
size=0
namespace_json=$(ndctl list --namespaces)
for uuid in "$@"; do
    [[ "$uuid" =~ ^[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$ ]] || {
        echo "Pass the namespace UUID reported by ndctl, not a filesystem UUID" >&2
        exit 2
    }
    name=$(jq -er --arg id "$uuid" '
        [(if type == "array" then .[] else . end)
          | select(.uuid == $id and .mode == "fsdax") | .blockdev]
        | if length == 1 and .[0] != null then .[0] else error("Missing fsdax namespace") end
    ' <<< "$namespace_json")
    device="/dev/$name"
    [[ "$device" =~ ^/dev/pmem[0-9]+(\.[0-9]+)?$ && -b "$device" ]] || {
        echo "Expected a whole PMem namespace, got $device" >&2
        exit 2
    }
    current=$(blockdev --getsz "$device")
    if (( size == 0 || current < size )); then
        size=$current
    fi
    devices+=("$device")
done
[[ ${devices[0]} != "${devices[1]}" ]] || { echo 'The namespaces must be distinct' >&2; exit 2; }
size=$((size / chunk_sectors * chunk_sectors))
(( size > 0 )) || { echo 'Namespaces are too small' >&2; exit 2; }
table="0 $((2 * size)) striped 2 $chunk_sectors ${devices[0]} 0 ${devices[1]} 0"
printf '%s\n' "$table"
[[ "$mode" == create ]] || exit 0
for device in "${devices[@]}"; do
    if findmnt -rn -S "$device" >/dev/null; then
        echo "Unmount $device first" >&2
        exit 1
    fi
    if [[ -n $(ls -A "/sys/class/block/${device##*/}/holders") ]]; then
        echo "$device already belongs to an active mapped device" >&2
        exit 1
    fi
done
exec dmsetup create z8-pmem-model --table "$table"
