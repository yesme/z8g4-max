#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 4 || $4 != --create ]]; then
    echo 'Usage: bash storage/partition-optane.sh NVME_BY_ID "T4_MODEL" T4_SERIAL --create' >&2
    exit 2
fi
disk=$1
model=$2
serial=$3

refuse() {
    printf 'Refusing to partition %s: %s\n' "$disk" "$*" >&2
    exit 1
}

[[ "$disk" == /dev/disk/by-id/nvme-* && -b "$disk" ]] || refuse 'use the T4 NVMe whole-disk by-id'
[[ $(lsblk -dnro TYPE -- "$disk") == disk ]] || refuse 'target is not a whole disk'
[[ -n "$model" && -n "$serial" && $(lsblk -dno MODEL -- "$disk") == "$model" &&
    $(lsblk -dno SERIAL -- "$disk") == "$serial" ]] || refuse 'model or serial differs from T4'
bytes=$(sudo blockdev --getsize64 "$disk")
[[ "$bytes" =~ ^[0-9]{13}$ ]] || refuse 'unexpected capacity'
[[ "$bytes" == 1500301910016 ]] || refuse 'expected the 1.5 TB D4800X namespace (1500301910016 bytes)'
mounts=$(lsblk -nr -o MOUNTPOINTS -- "$disk")
[[ -z ${mounts//[[:space:]]/} ]] || refuse 'the disk or a child is mounted'
children=$(lsblk -nr -o KNAME -- "$disk")
shopt -s nullglob
while IFS= read -r child; do
    [[ -d "/sys/class/block/$child/holders" ]] || refuse "cannot verify holders for $child"
    holders=(/sys/class/block/"$child"/holders/*)
    (( ${#holders[@]} == 0 )) || refuse "$child has a holder"
done <<< "$children"
# An imported ZFS pool can hold a device without a mount or a sysfs holder.
if [[ -d /sys/module/zfs ]]; then
    pools=$(sudo zpool list -H -o name)
    if [[ -n "$pools" ]]; then
        vdevs=$(sudo zpool status -LP)
        while IFS= read -r child; do
            if awk -v path="/dev/$child" '$1 == path { found=1 } END { exit !found }' <<< "$vdevs"; then
                refuse "$child belongs to an imported ZFS pool"
            fi
        done <<< "$children"
    fi
fi
logical_bytes=$(sudo blockdev --getss "$disk")
case "$logical_bytes" in
    512|4096) align_sectors=$((1048576 / logical_bytes)) ;;
    *) refuse "unexpected LBA size: $logical_bytes" ;;
esac

lsblk -b -o NAME,MODEL,SERIAL,SIZE,TYPE,FSTYPE,MOUNTPOINTS "$disk"
sudo sgdisk --print "$disk"
read -r -p "To erase this disk and write the nine partitions, enter the recorded serial $serial: " confirmation
[[ "$confirmation" == "$serial" ]] || refuse 'typed serial did not match'

gpt_args=(--clear --set-alignment="$align_sectors")
for i in {1..4}; do
    gpt_args+=(--new="$i:0:+24G" --change-name="$i:dmz-sata$((i-1))")
done
gpt_args+=(--new=5:0:+848G --change-name=5:z8-cold-index)
for i in {6..8}; do
    gpt_args+=(--new="$i:0:+80G" --change-name="$i:dmz-sata$((i-2))")
done
gpt_args+=(--new=9:0:0 --change-name=9:z8-special)
sudo sgdisk --zap-all "$disk"
sudo sgdisk "${gpt_args[@]}" "$disk"
sudo sgdisk --verify "$disk"
sudo partprobe "$disk"
sudo udevadm settle
# GPT uses 128 entries of 128 bytes and one header at the end of the disk.
last_gpt_bytes=$((16384 + logical_bytes))
special_bytes=$((bytes - 1184 * 1024**3 - 1048576 - last_gpt_bytes))
special=/dev/disk/by-partlabel/z8-special
[[ -b "$special" && $(lsblk -dnro PKNAME -- "$special") == $(lsblk -dnro KNAME -- "$disk") &&
    $(sudo blockdev --getsize64 "$special") == "$special_bytes" ]] ||
    refuse "GPT special partition differs from the expected $special_bytes bytes"
printf 'z8-special=%s bytes\n' "$special_bytes"
sudo sgdisk --print "$disk"
lsblk -b -o NAME,START,SIZE,PARTLABEL,FSTYPE,MOUNTPOINTS "$disk"
