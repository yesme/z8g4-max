#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

[[ $# == 1 && $1 == --create && $EUID == 0 ]] || {
    echo "Usage: sudo bash $0 --create" >&2
    exit 2
}
config=${Z8_STORAGE_CONFIG:-/etc/z8-storage}
# shellcheck source=/dev/null
source "$config/storage.env"
optane=$(lsblk -dnro KNAME -- "$Z8_OPTANE")
special=/dev/disk/by-partlabel/z8-special
lba=$(blockdev --getss "$Z8_OPTANE")
[[ "$lba" == 512 || "$lba" == 4096 ]]
[[ $(blockdev --getsize64 "$Z8_OPTANE") == 1500301910016 && -b "$special" &&
    $(lsblk -dnro PKNAME -- "$special") == "$optane" &&
    $(blockdev --getsize64 "$special") == "$((1500301910016 - 1184 * 1024**3 - 1048576 - 16384 - lba))" ]]
systemctl is-active --quiet z8-dmzoned.service
maps=(/dev/mapper/hc620-{4..6})
for slot in {4..6}; do
    /usr/local/sbin/z8-storage check-map "$slot"
done
for device in "${maps[@]}" "$special"; do
    signatures=$(wipefs --noheadings --output TYPE -- "$device")
    [[ -z "$signatures" ]] || {
        echo "Existing signature on $device. Review it before creating a pool." >&2
        exit 1
    }
done
pool_opts=(-f -o ashift=12 -o cachefile=none -o autotrim=on -m none
    -O canmount=off -O compression=zstd-3 -O atime=off -O checksum=on
    -O dedup=off -O copies=1 -O redundant_metadata=all -O xattr=sa
    -O dnodesize=auto -O primarycache=all -O sync=standard -O logbias=latency)
zpool create -n "${pool_opts[@]}" z8data raidz1 "${maps[@]}" special "$special"
read -r -p 'Verify the preview and enter z8data to create the new pool: ' confirmation
[[ "$confirmation" == z8data ]]
zpool create "${pool_opts[@]}" z8data raidz1 "${maps[@]}" special "$special"
available=$(zfs list -Hp -o available z8data)
[[ "$available" =~ ^[1-9][0-9]{0,15}$ ]]
zfs create -o mountpoint=none -o canmount=off -o readonly=on \
    -o refreservation="$((available / 10))" z8data/reserve
zfs create -o mountpoint=legacy -o recordsize=1M -o special_small_blocks=16K z8data/other
guid=$(zpool list -H -o guid z8data)
printf 'Initial available: %s bytes; reservation: %s bytes\nZ8_POOL_GUID=%s\n' "$available" "$((available / 10))" "$guid"
zpool status -gP z8data
zfs get -r compression,recordsize,special_small_blocks,mountpoint,canmount,refreservation z8data
zdb -l "$special" | grep -E 'metaslab_shift:|asize:'
zpool export z8data
