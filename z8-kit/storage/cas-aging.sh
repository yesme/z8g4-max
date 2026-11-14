#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 2 || ( $1 != sequential && $1 != random ) || $EUID != 0 ]]; then
    echo "Usage: sudo bash $0 sequential|random EXISTING_LOG_DIRECTORY" >&2
    exit 2
fi
profile=$1
target=/data/buildbarn
pool=z8data
[[ $(findmnt -n -M "$target" -o SOURCE,FSTYPE) == 'z8data/data/buildbarn zfs' ]]
[[ $(zpool list -H -o health "$pool") == ONLINE ]]
[[ $(zpool get -H -o value autotrim "$pool") == on ]]
log_dir=$(realpath -e -- "$2")
[[ -d "$log_dir" && $(findmnt -n -o FSTYPE -T "$log_dir") != zfs ]]
log_dir=$(mktemp -d -- "$log_dir/cas-$profile.XXXXXXXX")
file="$target/i4-cas-aging.bin"
if [[ -L "$file" ]]; then
    echo "Refusing symlink: $file" >&2
    exit 1
fi
case "$profile" in
    sequential)
        (set -o noclobber; : > "$file")
        truncate -s 512G -- "$file"
        ;;
    random) [[ -f "$file" && $(stat -c %s -- "$file") == 549755813888 ]] ;;
esac
echo "Logs: $log_dir"

history=/sys/module/zfs/parameters/zfs_txg_history
txgs=/proc/spl/kstat/zfs/$pool/txgs
old_history=$(<"$history")
monitor_pid=
iostat_pid=
cleanup() {
    if [[ -n "$monitor_pid" ]]; then
        kill "$monitor_pid" 2>/dev/null || true
        wait "$monitor_pid" 2>/dev/null || true
    fi
    if [[ -n "$iostat_pid" ]]; then
        kill "$iostat_pid" 2>/dev/null || true
        wait "$iostat_pid" 2>/dev/null || true
    fi
    printf '%s\n' "$old_history" > "$history"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s\n' "$((old_history < 4096 ? 4096 : old_history))" > "$history"

snapshot() {
    local tag=$1
    {
        printf '%s %s\n' "$(date -Is)" "$tag"
        dmsetup status --target zoned
    } >> "$log_dir/dmz.log"
    cat "$txgs" >> "$log_dir/txgs-$tag.log"
}
snapshot start
: > "$log_dir/txgs-periodic.log"
(
    while sleep 60; do
        snapshot periodic
    done
) & monitor_pid=$!
zpool iostat -vpy -T u "$pool" 60 > "$log_dir/zpool-iostat.log" & iostat_pid=$!

run_fio() {
    local name=$1 pattern=$2 bytes=$3 started=$SECONDS
    fio --name="$name" --filename="$file" --allow_file_create=0 \
        --size=512G --io_size="$bytes" --rw="$pattern" --bs=1M --ioengine=psync \
        --direct=0 --overwrite=1 --fallocate=none --refill_buffers=1 \
        --buffer_compress_percentage=0 --norandommap=1 --end_fsync=1 \
        --write_bw_log="$log_dir/$name" --log_avg_msec=60000 \
        --percentile_list=50:95:99:99.9 --output-format=json --output="$log_dir/$name.json"
    zpool sync "$pool"
    printf '%s %s seconds (including zpool sync)\n' "$name" "$((SECONDS - started))" | tee -a "$log_dir/timing.log"
    snapshot "$name"
}

if [[ "$profile" == sequential ]]; then
    run_fio seed write 512G
    last_seed_txg=$(awk '$1 ~ /^[0-9]+$/ && $12 > 0 { id=$1 } END { if (id == "") exit 1; print id }' "$log_dir/txgs-seed.log")
    for pass in 1 2 3; do
        run_fio "overwrite-$pass" write 512G
    done
    awk -v start="$last_seed_txg" '
        $1 ~ /^[0-9]+$/ && $1 > start && $12 > max { max=$12; id=$1 }
        END {
            if (id == "") exit 1
            printf "Max completed overwrite TXG %s sync time: %.3f seconds\n", id, max / 1e9
        }
    ' "$log_dir"/txgs-{periodic,overwrite-*}.log | tee -a "$log_dir/timing.log"
else
    run_fio random-overwrite randwrite 1T
fi
