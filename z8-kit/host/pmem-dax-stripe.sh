#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=z8-kit/host/pmem-device-wait.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/pmem-device-wait.sh"

if [[ $# != 3 || ( $1 != show && $1 != create && $1 != mount && $1 != unmount ) ]]; then
    echo "Usage: bash $0 show|create|mount|unmount FSDAX_NAMESPACE_UUID0 FSDAX_NAMESPACE_UUID1" >&2
    exit 2
fi
mode=$1
shift
target=/srv/pmem-model
mapper=/dev/mapper/z8-pmem-model
if [[ "$mode" == unmount ]] && ! dmsetup info z8-pmem-model >/dev/null 2>&1; then
    if findmnt -rn -M "$target" >/dev/null; then
        echo "An unexpected filesystem is mounted at $target" >&2
        exit 1
    fi
    exit 0
fi
chunk_sectors=4096  # 2 MiB
devices=()
size=0
names=$(pmem_wait_devices fsdax "$@")
while IFS= read -r name; do
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
done <<< "$names"
size=$((size / chunk_sectors * chunk_sectors))
(( size > 0 )) || { echo 'Namespaces are too small' >&2; exit 2; }
table="0 $((2 * size)) striped 2 $chunk_sectors ${devices[0]} 0 ${devices[1]} 0"
printf '%s\n' "$table"
[[ "$mode" != show ]] || exit 0
if dmsetup info z8-pmem-model >/dev/null 2>&1; then
    # dmsetup table prints major:minor rather than the input device paths.
    id0=$(lsblk -dnro MAJ:MIN "${devices[0]}")
    id1=$(lsblk -dnro MAJ:MIN "${devices[1]}")
    expected="0 $((2 * size)) striped 2 $chunk_sectors $id0 0 $id1 0"
    if [[ $(dmsetup table z8-pmem-model) != "$expected" ]]; then
        echo 'Existing z8-pmem-model has a different device table' >&2
        exit 1
    fi
elif [[ "$mode" != unmount ]]; then
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
    dmsetup create z8-pmem-model --table "$table"
else
    echo 'z8-pmem-model disappeared during shutdown' >&2
    exit 1
fi
udevadm settle --timeout=10
test -b "$mapper"
[[ "$mode" != create ]] || exit 0

if mounted=$(findmnt -rn -M "$target" -o MAJ:MIN,FSTYPE,OPTIONS); then
    read -r source_id fstype options <<< "$mounted"
    mapper_id=$(lsblk -dnro MAJ:MIN "$mapper")
    if [[ "$mounted" == *$'\n'* || "$source_id" != "$mapper_id" ||
          "$fstype" != xfs || ",$options," != *,dax=always,* ]]; then
        echo "An unexpected filesystem is mounted at $target" >&2
        exit 1
    fi
    if [[ "$mode" == mount ]]; then
        exit 0
    fi
    umount "$target"
fi
if [[ "$mode" == unmount ]]; then
    exec dmsetup remove z8-pmem-model
fi
exec mount -t xfs -o dax=always,noatime,nodiscard "$mapper" "$target"
