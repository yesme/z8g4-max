#!/usr/bin/env bash
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -r -- "$tmp"' EXIT
export Z8_FIXTURE="$tmp" PATH="$tmp/bin:$PATH"
mkdir -p "$tmp"/{bin,dev/disk/by-id,sys/class/block/nvme1n1/holders,sys/class/block/nvme1n1p1/holders}
target="$tmp/dev/disk/by-id/nvme-test"
touch "$target"
sed -e 's/ -b / -f /g' -e "s@/dev/disk/by-id/@$tmp/dev/disk/by-id/@g" \
    -e "s@/sys/@$tmp/sys/@g" z8-kit/storage/partition-optane.sh > "$tmp/partition.sh"

cat > "$tmp/bin/lsblk" <<'EOF'
#!/usr/bin/env bash
column=$2
if [[ $column == -o ]]; then column=$3; fi
case "$column" in
    TYPE) echo disk ;;
    MODEL) echo 'Intel sample' ;;
    SERIAL) echo 'dmz-optane-serial' ;;
    MOUNTPOINTS) if [[ -f "$Z8_FIXTURE/mounted" ]]; then echo /mnt/in-use; fi ;;
    KNAME) printf 'nvme1n1\nnvme1n1p1\n' ;;
    *) echo 'drive preview' ;;
esac
EOF
cat > "$tmp/bin/blockdev" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    --getsize64) cat "$Z8_FIXTURE/capacity" ;;
    --getss) echo 4096 ;;
    *) exit 2 ;;
esac
EOF
cat > "$tmp/bin/sgdisk" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$Z8_FIXTURE/actions"
EOF
cat > "$tmp/bin/zpool" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    list) echo running-pool ;;
    status) printf '\t/dev/nvme1n1p1 ONLINE\n' ;;
    *) exit 2 ;;
esac
EOF
printf '#!/usr/bin/env bash\nexec "$@"\n' > "$tmp/bin/sudo"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/partprobe"
cp "$tmp/bin/partprobe" "$tmp/bin/udevadm"
chmod +x "$tmp"/bin/*

run_partition() {
    bash "$tmp/partition.sh" "$target" "$1" "$2" --create <<< "$3" > "$tmp/output" 2>&1
}
check_refused() {
    local message=$1
    shift
    if run_partition "$@"; then
        cat "$tmp/output" >&2
        exit 1
    fi
    grep -Fq -- "$message" "$tmp/output" || { cat "$tmp/output" >&2; exit 1; }
    if [[ -e "$tmp/actions" ]] && grep -Fq -- '--zap-all' "$tmp/actions"; then
        echo 'Attempted to erase an ineligible device.' >&2
        exit 1
    fi
}

check_refused 'model or serial differs from T4' 'Intel sample' wrong dmz-optane-serial
printf '3200631791616\n' > "$tmp/capacity"
check_refused 'below 1.6 TB' 'Intel sample' dmz-optane-serial dmz-optane-serial
printf '1500301910016\n' > "$tmp/capacity"
touch "$tmp/mounted"
check_refused 'a child is mounted' 'Intel sample' dmz-optane-serial dmz-optane-serial
rm -- "$tmp/mounted"
touch "$tmp/sys/class/block/nvme1n1p1/holders/dm-0"
check_refused 'nvme1n1p1 has a holder' 'Intel sample' dmz-optane-serial dmz-optane-serial
rm -- "$tmp/sys/class/block/nvme1n1p1/holders/dm-0"
mkdir -p "$tmp/sys/module/zfs"
check_refused 'belongs to an imported ZFS pool' 'Intel sample' dmz-optane-serial dmz-optane-serial
rmdir "$tmp/sys/module/zfs"
check_refused 'typed serial did not match' 'Intel sample' dmz-optane-serial wrong
run_partition 'Intel sample' dmz-optane-serial dmz-optane-serial
grep -Fq -- '--zap-all' "$tmp/actions"
grep -Fq -- '--new=8:0:+192G --change-name=8:z8-special --new=9:0:0 --change-name=9:z8-cold-index' "$tmp/actions"
printf 'Optane partition tests passed: identity, capacity, mounts, holders, importing pool and typed confirmation.\n'
