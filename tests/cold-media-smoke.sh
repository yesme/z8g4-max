#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

[[ $# == 0 && $EUID == 0 ]] || { echo 'Usage: sudo bash tests/cold-media-smoke.sh'; exit 2; }
[[ ! -d /sys/module/scsi_debug ]] || { echo 'Unload any existing scsi_debug test device first.' >&2; exit 1; }
exec 9>/run/lock/z8-scsi-smoke.lock
flock -n 9

work=$(mktemp -d)
zoned="z8-lab-zoned-$$"
slice="z8-lab-slice-$$"
loop=
loaded=0
cleanup() {
    if (( loaded )); then echo 0 > /sys/module/scsi_debug/parameters/opts || true; fi
    for name in "$slice" "$zoned"; do
        if dmsetup info "$name" >/dev/null 2>&1; then dmsetup remove --noudevsync --retry "$name"; fi
    done
    if [[ -n "$loop" ]]; then losetup -d "$loop"; fi
    if (( loaded )); then modprobe -r scsi_debug; fi
    rm -f -- "$work/cache" "$work/seed" "$work/overwrite"
    rmdir -- "$work"
}
trap cleanup EXIT
modprobe dm-zoned
modprobe scsi_debug add_host=1 dev_size_mb=256 sector_size=4096 zbc=host-managed zone_size_mb=16 zone_nr_conv=1 opts=0
loaded=1
udevadm settle
disks=()
for entry in /sys/class/block/sd*; do
    if [[ -r "$entry/device/model" && $(<"$entry/device/model") =~ ^scsi_debug[[:space:]]*$ ]]; then
        disks+=("/dev/${entry##*/}")
    fi
done
[[ ${#disks[@]} -eq 1 ]]
disk=${disks[0]}
[[ $(lsblk -dnro ZONED -- "$disk") == host-managed &&
    $(blockdev --getsize64 "$disk") == 268435456 && $(blockdev --getss "$disk") == 4096 ]]
[[ $(<"/sys/class/block/${disk##*/}/queue/chunk_sectors") == 32768 ]]
lsblk -o NAME,MODEL,SIZE,ZONED,LOG-SEC "$disk"

truncate -s 96M "$work/cache"
loop=$(losetup --find --show "$work/cache")
dmzadm --format "$loop" "$disk" --label="$zoned" --seq=2
# Use the same zoned target table without waiting for the Live ISO's udev
# cookie. The test has 6 cache + 16 SCSI zones, 2 metadata and 2 reserve.
dmsetup create "$zoned" --noudevsync --table "0 $((18 * 32768)) zoned $loop $disk"
dmsetup mknodes "$zoned"
dmsetup create "$slice" --noudevsync --table "0 32768 linear /dev/mapper/$zoned 0"
dmsetup mknodes "$slice"
device=/dev/mapper/$slice

python3 - "$work" <<'PY'
from pathlib import Path
import sys
room = Path(sys.argv[1])
(room / "seed").write_bytes(b"7" * (16 << 20))
(room / "overwrite").write_bytes(b"Y" * (8 << 20))
PY
dd if="$work/seed" of="$device" bs=1M oflag=direct conv=fsync status=none

cache_free() {
    local status
    status=$(dmsetup status "$zoned")
    [[ "$status" =~ ([0-9]+)/([0-9]+)[[:blank:]]cache ]]
    printf '%s\n' "${BASH_REMATCH[1]}"
}
wait_for_free() {
    local wanted=$1
    for ((i=0; i<45; i++)); do
        if [[ $(cache_free) == "$wanted" ]]; then return; fi
        sleep 1
    done
    dmsetup status "$zoned"
    return 1
}

sleep 12
dmsetup message "$zoned" 0 reclaim
wait_for_free 4
# Locate the seeded sequential zone by its marker before enabling injection.
lba=$(python3 - "$disk" <<'PY'
import os
import sys
with open(sys.argv[1], "rb", buffering=0) as disk:
    found = [i for i in range(1, 16) if os.pread(disk.fileno(), 4096, i << 24) == b"7" * 4096]
assert len(found) == 1, found
print(((found[0] << 24) + (8 << 20)) // 4096)
PY
)
params=/sys/module/scsi_debug/parameters
printf '%s\n' "$lba" > "$params/medium_error_start"
printf '1\n' > "$params/medium_error_count"
printf '2\n' > "$params/opts"
dd if="$work/overwrite" of="$device" bs=1M oflag=direct conv=fsync status=none

sleep 12
dmsetup message "$zoned" 0 reclaim
sleep 3
dmsetup status "$zoned"
[[ $(cache_free) == 3 ]]

# The lab alone calls the production scan function with its disposable device.
result=0
python3 -B - "$device" <<'PY' || result=$?
import errno
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
import mmap
import os
import sys
loader = SourceFileLoader("scanner", "z8-kit/storage/z8-cold-scan")
spec = spec_from_loader(loader.name, loader)
scanner = module_from_spec(spec)
loader.exec_module(scanner)
with mmap.mmap(-1, 4096) as page:
    fd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECT)
    try:
        os.preadv(fd, [page], 8 << 20)
    except OSError as error:
        if error.errno != errno.ENODATA:
            raise
        print(f"Observed kernel ENODATA ({error.errno})")
    else:
        raise SystemExit("Expected an unrecovered read error")
    finally:
        os.close(fd)
sys.exit(1 if scanner.scan_device(sys.argv[1], 16 << 20) == 1 else 2)
PY
[[ "$result" == 1 ]]
# Keep the original physical fault enabled while verifying recovery.
sleep 12
dmsetup message "$zoned" 0 reclaim
wait_for_free 4
python3 - "$device" <<'PY'
import sys
with open(sys.argv[1], "rb", buffering=0) as device:
    expected = b"Y" * (8 << 20) + bytes(4096) + b"7" * ((8 << 20) - 4096)
    assert device.read(16 << 20) == expected
PY
dmsetup status "$zoned"
echo 'PASS: ENODATA, exact 4 KiB repair, neighbors intact, and reclaim resumed.'
