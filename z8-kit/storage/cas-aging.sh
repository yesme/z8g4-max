#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

# The three heads of each shard occupy different 17.5 GiB blocks, beyond the sequential burn-in.
zone=$((256 << 20))
block=$((70 * zone))
first_block=8
head_gib=(16 8 4)
sequential_gib=72

usage() {
    echo "Usage: sudo bash $0 sequential|interleaved EXISTING_LOG_DIRECTORY" >&2
    echo "       bash $0 plan" >&2
    exit 2
}

# All three passes use identical byte ranges. Zero weight means one job at a time.
interleaved_jobs() {
    local phase=$1 slot=$2 shard head device weight
    for shard in {0..7}; do
        device="/dev/mapper/z8-cold-sata$slot-$shard"
        for head in 0 1 2; do
            weight=0
            if [[ "$phase" == interleaved ]]; then weight=$((4 >> head)); fi
            printf '%s\t%s\t%s\t%s\t%s\n' "shard$shard-new$head" "$device" "$(((first_block + head) * block))" \
                "$((head_gib[head] << 30))" "$weight"
        done
    done
}

if [[ $# == 1 && $1 == plan ]]; then
    for phase in seed baseline interleaved; do
        for slot in {0..3}; do
            interleaved_jobs "$phase" "$slot" | sed "s/^/$phase\t$slot\t/"
        done
    done
    exit
fi
[[ $# == 2 && $1 =~ ^(sequential|interleaved)$ && $EUID == 0 ]] || usage
mode=$1
config=${Z8_STORAGE_CONFIG:-/etc/z8-storage}
# shellcheck source=/dev/null
source "$config/storage.env"
devices=()
stats=()
exec 9>/run/lock/z8-cold-scan.lock
flock -n 9 || { echo 'A cold scan or another aging run holds the lock.' >&2; exit 1; }
inventory=$(/usr/local/sbin/z8-cold i4-list)
mapfile -t shards <<< "$inventory"
[[ ${#shards[@]} -eq 32 ]]
log_dir=$(realpath -e -- "$2")
[[ -d "$log_dir" ]]
for slot in {0..3}; do
    device="/dev/mapper/z8-cold-sata$slot-0"
    [[ -b "$device" && $(dmsetup info -c --noheadings -o open "$device") -eq 0 ]]
    devices+=("$device")
    stats+=("/sys/class/block/$(basename "$(readlink -f "$device")")/stat")
done
if [[ "$mode" == interleaved ]]; then
    for shard in "${shards[@]}"; do
        device="/dev/mapper/z8-cold-$shard"
        [[ -b "$device" && $(dmsetup info -c --noheadings -o open "$device") -eq 0 ]]
        [[ $(blockdev --getsize64 "$device") -eq $((93 * block)) ]]
    done
    # All eight shards of a disk are written, so count what reaches the whole dm-zoned device.
    for slot in {0..3}; do
        stats[slot]="/sys/class/block/$(basename "$(readlink -f "/dev/mapper/hc620-$slot")")/stat"
    done
    read -r -p 'This seeds, overwrites and discards 28 GiB in blocks 8-10 of each of 32 cold shards. Type EMPTY-COLD to proceed: ' confirmation
else
    read -r -p "This overwrites the first $sequential_gib GiB of each sataN-0. Type EMPTY-COLD to proceed: " confirmation
fi
[[ "$confirmation" == EMPTY-COLD ]] || exit 1
log_dir=$(mktemp -d -- "$log_dir/cas-$mode.XXXXXXXX")
echo "Logs: $log_dir"

cache_counts() {
    local status
    local -a fields
    status=$(dmsetup status "hc620-$1") || return 1
    read -ra fields <<< "$status"
    [[ ${fields[5]:-} =~ ^([0-9]+)/([1-9][0-9]*)$ && ${fields[6]:-} == cache ]] || return 1
    free=${BASH_REMATCH[1]}
    total=${BASH_REMATCH[2]}
    (( free <= total ))
}

snapshot() {
    local slot counters free total
    for slot in {0..3}; do
        cache_counts "$slot" || return 1
        counters=$(awk '{print $7}' "${stats[slot]}")
        printf '%s\t%s\t%s\t%s\t%s\n' "$(date -Is)" "$slot" "$free" "$total" "$((counters * 512))"
    done
}

monitor=
workers=()
monitor_start() {
    printf 'time\tsata\tfree_cache_zones\ttotal_cache_zones\tbytes_written_since_mapper_start\n' > "$1"
    snapshot >> "$1"
    (
        # A sleep that outlives this run must not keep the scan lock.
        exec 9>&-
        while sleep 5; do snapshot; done
    ) >> "$1" 2>>"$log_dir/monitor.err" & monitor=$!
}
# Stop the sampler. A sampler that died on its own leaves the cache watermark unknown.
monitor_stop() {
    local alive=0
    kill -0 "$monitor" 2>/dev/null && alive=1
    kill "$monitor" 2>/dev/null || true
    wait "$monitor" 2>/dev/null || true
    monitor=
    (( alive ))
}
cleanup() {
    local pid
    for pid in "${workers[@]}"; do kill -TERM -- "-$pid" 2>/dev/null || true; done
    for pid in "${workers[@]}"; do wait "$pid" 2>/dev/null || true; done
    if [[ -n "$monitor" ]]; then monitor_stop || true; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
nvme smart-log "$Z8_OPTANE" > "$log_dir/optane-start.log"

sequential() {
    local passed=1 phase started elapsed slot
    local -a args
    monitor_start "$log_dir/watermark.tsv"
    for phase in seed overwrite-1 overwrite-2 overwrite-3; do
        started=$SECONDS
        args=(--ioengine=psync --size="${sequential_gib}G" --rw=write --direct=1 --bs=1M
              --allow_file_create=0 --overwrite=1 --end_fsync=1 --refill_buffers=1
              --buffer_compress_percentage=0 --write_bw_log="$log_dir/$phase"
              --log_avg_msec=60000 --output-format=json --output="$log_dir/$phase.json")
        for slot in {0..3}; do args+=(--name="sata$slot" --filename="${devices[slot]}"); done
        fio "${args[@]}"
        elapsed=$((SECONDS - started))
        # Time includes all four devices' final flush.
        printf '%s %s s\n' "$phase" "$elapsed" | tee -a "$log_dir/timing.log"
        if [[ "$phase" == overwrite-[23] ]] && (( elapsed * 150000000 > 4 * sequential_gib * 1024**3 )); then
            passed=0
        fi
    done
    monitor_stop || passed=0
    snapshot >> "$log_dir/watermark.tsv"
    nvme smart-log "$Z8_OPTANE" > "$log_dir/optane-end.log"
    awk -F '\t' '
        NR == 1 {next}
        !($2 in start) {start[$2] = $5}
        $3*100 <= $4*30 && !($2 in seen) {
            seen[$2] = 1
            printf "sata%s first sampled >=70%% used after %.2f GiB wrote\n", $2, ($5-start[$2])/1073741824
        }
        END {for (i=0; i<4; i++) if (!seen[i]) printf "sata%d never sampled >=70%% cache\n", i}
    ' "$log_dir/watermark.tsv" | tee "$log_dir/watermark-summary.log"
    # Hand the range back as unwritten zones. Left in place, every one of these zones would be read
    # back from the HDD and merged the first time Buildbarn writes to it. The verdict does not depend on it.
    for slot in {0..3}; do
        blkdiscard --length "$((sequential_gib << 30))" "${devices[slot]}" ||
            echo "sata$slot-0 still holds the test data; the first fill will overwrite it."
    done
    (( passed )) || { echo 'FAIL: last two passes require 150 MB/s aggregate and live monitoring'; exit 1; }
    echo 'PASS: aggregate steady overwrite >= 150 MB/s'
}

# The only discarded bytes are the ranges printed by plan, after all three passes.
discard_test_windows() {
    local slot name device offset size flow
    for slot in {0..3}; do
        while IFS=$'\t' read -r name device offset size flow; do
            blkdiscard --offset "$offset" --length "$size" "$device"
        done < <(interleaved_jobs seed "$slot")
    done
}

monotonic_seconds() {
    local uptime
    read -r uptime _ < /proc/uptime
    echo "${uptime%.*}"
}

# Compare all phases at the same per-disk endpoint. A stalled cache is a failed
# measurement; counting the plateau as drained would reward deferred writes.
wait_for_reclaim() {
    local slot=$1 phase=$2 started free total
    started=$(monotonic_seconds)
    while true; do
        cache_counts "$slot"
        if (( free == total )); then return 0; fi
        if (( $(monotonic_seconds) - started >= drain_timeout )); then
            echo "FAIL: $phase sata$slot reclaim timed out ($free/$total cache zones free)" >&2
            return 1
        fi
        sleep 5
    done
}

run_disk() {
    local phase=$1 slot=$2 name device offset size flow started foreground elapsed
    local -a args=(--ioengine=psync --rw=write --direct=0 --bs=256k --allow_file_create=0 --overwrite=1 --end_fsync=1
                   --refill_buffers=1 --buffer_compress_percentage=0 --flow_sleep=1000
                   --output-format=json --output="$log_dir/$phase-sata$slot.json")
    while IFS=$'\t' read -r name device offset size flow; do
        args+=(--name="$name" --filename="$device" --offset="$offset" --size="$size")
        if (( flow )); then args+=(--flow="$flow"); else args+=(--stonewall); fi
    done < <(interleaved_jobs "$phase" "$slot")

    wait_for_reclaim "$slot" "before $phase"
    started=$(monotonic_seconds)
    fio "${args[@]}"
    foreground=$(( $(monotonic_seconds) - started ))
    echo "$phase sata$slot foreground_s=$foreground"
    echo "$foreground" > "$log_dir/$phase-sata$slot.foreground"
    wait_for_reclaim "$slot" "$phase"
    elapsed=$(( $(monotonic_seconds) - started ))
    printf '%s\t%s\t%s\n' "$foreground" "$((elapsed - foreground))" "$elapsed" > "$log_dir/$phase-sata$slot.timing"
    echo "$phase sata$slot reclaim_s=$((elapsed - foreground)) total_s=$elapsed"
}

interleaved() {
    local minimum=${Z8_INTERLEAVED_MIN_RATIO:-0.70} drain_timeout=${Z8_RECLAIM_TIMEOUT_SECONDS:-900}
    local phase slot pid passed=1
    [[ "$minimum" =~ ^0\.[0-9]+$|^1(\.0+)?$ && "$drain_timeout" =~ ^[1-9][0-9]*$ ]]
    for phase in seed baseline interleaved; do
        monitor_start "$log_dir/watermark-$phase.tsv"
        # Each worker and its fio children share a process group so interruption
        # stops writes before releasing the commissioning lock.
        set -m
        for slot in {0..3}; do (set +m; run_disk "$phase" "$slot") & workers+=($!); done
        set +m
        for pid in "${workers[@]}"; do wait "$pid" || passed=0; done
        workers=()
        monitor_stop || passed=0
        snapshot >> "$log_dir/watermark-$phase.tsv"
        (( passed )) || { echo "FAIL: $phase did not complete on all four disks"; return 1; }
    done
    nvme smart-log "$Z8_OPTANE" > "$log_dir/optane-end.log"
    discard_test_windows

    local summary="$log_dir/interleaved-summary.tsv" bf br bt xf xr xt
    printf 'sata\tbaseline_front_s\tbaseline_reclaim_s\tbaseline_total_s\tinterleaved_front_s\tinterleaved_reclaim_s\tinterleaved_total_s\tbaseline_total_MB_s\tinterleaved_total_MB_s\ttotal_ratio\tbaseline_min_free\tinterleaved_min_free\n' > "$summary"
    for slot in {0..3}; do
        read -r bf br bt < "$log_dir/baseline-sata$slot.timing"
        read -r xf xr xt < "$log_dir/interleaved-sata$slot.timing"
        (( bt > 0 && xt > 0 ))
        awk -F '\t' -v slot="$slot" -v bytes="$(((head_gib[0] + head_gib[1] + head_gib[2]) * 8 << 30))" \
            -v bf="$bf" -v br="$br" -v bt="$bt" -v xf="$xf" -v xr="$xr" -v xt="$xt" \
            -v minimum="$minimum" '
            FNR == 1 {file++; next}
            $2 == slot && (!(file in low) || $3 < low[file]) {low[file] = $3}
            END {
                printf "%d\t%d\t%d\t%d\t%d\t%d\t%d\t%.1f\t%.1f\t%.5f\t%d\t%d\n", slot, bf, br, bt,
                    xf, xr, xt, bytes/bt/1e6, bytes/xt/1e6, bt/xt, low[1], low[2]
                if (!(1 in low) || !(2 in low) || bt/xt < minimum) exit 1
            }
        ' "$log_dir/watermark-baseline.tsv" "$log_dir/watermark-interleaved.tsv" >> "$summary" || passed=0
    done
    cat "$summary"
    (( passed )) || { echo "FAIL: drained 24-way overwrite below $minimum of same-window baseline or missing samples"; return 1; }
    echo "PASS: drained 24-way overwrite at least $minimum of same-window baseline on every disk"
}

"$mode"
