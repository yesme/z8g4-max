#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 3 || $1 != sequential || $EUID != 0 ]]; then
    echo "Usage: sudo bash $0 sequential EXISTING_LOG_DIRECTORY OPTANE_WHOLE_DISK_BY_ID" >&2
    exit 2
fi
target=/data/buildbarn
pool=z8data
optane=$3
[[ "$optane" == /dev/disk/by-id/nvme-* && -b "$optane" &&
    $(lsblk -dnro TYPE -- "$optane") == disk ]]
[[ $(findmnt -n -M "$target" -o SOURCE,FSTYPE) == 'z8data/buildbarn zfs' ]]
[[ $(zpool list -H -o health "$pool") == ONLINE ]]
[[ $(zpool get -H -o value autotrim "$pool") == on ]]
log_dir=$(realpath -e -- "$2")
[[ -d "$log_dir" && $(findmnt -n -o FSTYPE -T "$log_dir") != zfs ]]
file="$target/i4-cas-aging.bin"
if [[ -e "$file" || -L "$file" ]] || ! (set -o noclobber; : > "$file"); then
    echo "Cannot create $file. If it is a previous test file, verify it and remove it before retrying." >&2
    exit 1
fi
truncate -s 512G -- "$file"
log_dir=$(mktemp -d -- "$log_dir/cas-sequential.XXXXXXXX")
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
    {
        printf '%s %s\n' "$(date -Is)" "$tag"
        nvme smart-log "$optane"
    } >> "$log_dir/optane-smart.log"
}
snapshot start
: > "$log_dir/txgs-periodic.log"
(
    sleeper=
    trap 'if [[ -n "$sleeper" ]]; then kill "$sleeper" 2>/dev/null || true; wait "$sleeper" 2>/dev/null || true; fi; exit 0' TERM
    while true; do
        sleep 60 & sleeper=$!
        wait "$sleeper"
        sleeper=
        snapshot periodic
    done </dev/null >>"$log_dir/monitor.log" 2>&1
) & monitor_pid=$!
zpool iostat -vpy -T u "$pool" 60 > "$log_dir/zpool-iostat.log" & iostat_pid=$!

run_fio() {
    local name=$1 started=$SECONDS
    fio --name="$name" --filename="$file" --allow_file_create=0 \
        --size=512G --rw=write --bs=1M --ioengine=psync \
        --direct=0 --overwrite=1 --fallocate=none --refill_buffers=1 \
        --buffer_compress_percentage=0 --end_fsync=1 \
        --write_bw_log="$log_dir/$name" --log_avg_msec=60000 \
        --percentile_list=50:95:99:99.9 --output-format=json --output="$log_dir/$name.json"
    zpool sync "$pool"
    elapsed=$((SECONDS - started))
    printf '%s %s seconds (including zpool sync)\n' "$name" "$elapsed" | tee -a "$log_dir/timing.log"
    snapshot "$name"
}

run_fio seed
last_seed_txg=$(awk '$1 ~ /^[0-9]+$/ && $12 > 0 { id=$1 } END { if (id == "") exit 1; print id }' "$log_dir/txgs-seed.log")
passed=1
for pass in 1 2 3; do
    run_fio "overwrite-$pass"
    if (( pass >= 2 && elapsed > 3665 )); then
        passed=0
    fi
done
if ! kill -0 "$monitor_pid" "$iostat_pid" 2>/dev/null ||
    [[ ! -s "$log_dir/zpool-iostat.log" || ! -s "$log_dir/txgs-periodic.log" ]]; then
    echo 'Missing periodic monitoring. Check monitor.log and zpool-iostat.log.' | tee -a "$log_dir/timing.log"
    passed=0
fi
if ! awk -v start="$last_seed_txg" '
    $1 ~ /^[0-9]+$/ && $1 > start && $12 > max { max=$12; id=$1 }
    END {
        if (id == "") { print "No completed overwrite TXG recorded"; exit 1 }
        printf "Max completed overwrite TXG %s sync time: %.3f seconds\n", id, max / 1e9
        if (max > 60000000000) exit 1
    }
' "$log_dir"/txgs-{periodic,overwrite-*}.log | tee -a "$log_dir/timing.log"; then
    passed=0
fi
if (( passed )); then
    echo 'PASS: throughput and TXG duration' | tee -a "$log_dir/timing.log"
else
    echo 'FAIL: minimum 150 MB/s, maximum 60 s completed TXG duration, and live monitoring required' | tee -a "$log_dir/timing.log"
    exit 1
fi
