#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

# A cold shard holds 93 Buildbarn blocks of 70 zones. The interleaved test writes where the three new
# blocks of every shard are after eight blocks: past the 128 GiB that the sequential test uses on sataN-0.
zone=$((256 << 20))
block=$((70 * zone))
first_block=8
head_gib=(16 8 4)
test_blocks=5

usage() {
    echo "Usage: sudo bash $0 sequential|interleaved EXISTING_LOG_DIRECTORY" >&2
    echo "       bash $0 plan" >&2
    exit 2
}

# Print name, device, offset, size and flow weight of every fio job of one disk. The interleaved phase
# appends to the three new blocks of all eight shards at once, 4:2:1, like the patched Buildbarn does
# from the first object on. The baseline writes the same amount to the next blocks, one shard at a time.
interleaved_jobs() {
    local phase=$1 slot=$2 shard head device
    for shard in {0..7}; do
        device="/dev/mapper/z8-cold-sata$slot-$shard"
        if [[ "$phase" == baseline ]]; then
            printf '%s\t%s\t%s\t%s\t0\n' "shard$shard" "$device" "$(((first_block + 3) * block))" \
                "$(((head_gib[0] + head_gib[1] + head_gib[2]) << 30))"
            continue
        fi
        for head in 0 1 2; do
            printf '%s\t%s\t%s\t%s\t%s\n' "shard$shard-new$head" "$device" "$(((first_block + head) * block))" \
                "$((head_gib[head] << 30))" "$((4 >> head))"
        done
    done
}

if [[ $# == 1 && $1 == plan ]]; then
    for phase in baseline interleaved; do
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
mapfile -t shards < <(/usr/local/sbin/z8-cold list)
[[ ${#shards[@]} -eq 32 && $(jq -er '.active | length' "$config/cold-layout.json") == 0 ]]
[[ $(systemctl show -p ActiveState --value z8-buildbarn.service) =~ ^(inactive|failed)$ ]]
exec 9>/run/lock/z8-cold-scan.lock
flock -n 9 || { echo 'A cold scan or another aging run holds the lock.' >&2; exit 1; }
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
    read -r -p 'This overwrites blocks 8-12 (87.5 GiB) of all 32 cold shards. Type EMPTY-COLD to proceed: ' confirmation
else
    read -r -p 'This overwrites the first 128 GiB of each sataN-0. Type EMPTY-COLD to proceed: ' confirmation
fi
[[ "$confirmation" == EMPTY-COLD ]] || exit 1
log_dir=$(mktemp -d -- "$log_dir/cas-$mode.XXXXXXXX")
echo "Logs: $log_dir"

snapshot() {
    local slot status counters
    local -a fields
    for slot in {0..3}; do
        status=$(dmsetup status "hc620-$slot")
        counters=$(awk '{print $7}' "${stats[slot]}")
        read -ra fields <<< "$status"
        [[ ${fields[5]} =~ ^([0-9]+)/([1-9][0-9]*)$ && ${fields[6]} == cache ]]
        free=${BASH_REMATCH[1]}
        total=${BASH_REMATCH[2]}
        printf '%s\t%s\t%s\t%s\t%s\n' "$(date -Is)" "$slot" "$free" "$total" "$((counters * 512))"
    done
}

monitor=
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
        args=(--ioengine=psync --size=128G --rw=write --direct=1 --bs=1M
              --allow_file_create=0 --overwrite=1 --end_fsync=1 --refill_buffers=1
              --buffer_compress_percentage=0 --write_bw_log="$log_dir/$phase"
              --log_avg_msec=60000 --output-format=json --output="$log_dir/$phase.json")
        for slot in {0..3}; do args+=(--name="sata$slot" --filename="${devices[slot]}"); done
        fio "${args[@]}"
        elapsed=$((SECONDS - started))
        # 512 GiB per pass; time includes all four devices' final flush.
        printf '%s %s s\n' "$phase" "$elapsed" | tee -a "$log_dir/timing.log"
        if [[ "$phase" == overwrite-[23] ]] && (( elapsed * 150000000 > 512 * 1024**3 )); then
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
        blkdiscard --length "$((128 << 30))" "${devices[slot]}" ||
            echo "sata$slot-0 still holds the test data; the first fill will overwrite it."
    done
    (( passed )) || { echo 'FAIL: last two passes require 150 MB/s aggregate and live monitoring'; exit 1; }
    echo 'PASS: aggregate steady overwrite >= 150 MB/s'
}

# Return the test range of every shard to unwritten zones, so that a rerun appends instead of overwriting.
discard_test_blocks() {
    local shard
    for shard in "${shards[@]}"; do
        blkdiscard --offset "$((first_block * block))" --length "$((test_blocks * block))" "/dev/mapper/z8-cold-$shard"
    done
}

# Reclaim keeps emptying the cache after the writers have returned. Wait until it is done or has stopped
# making progress for a minute, so that every phase starts with the cache it would have after idle time.
wait_for_reclaim() {
    local previous='' current quiet=0
    while (( quiet < 12 )); do
        current=$(snapshot | cut -f3,4)
        if ! grep -qvE '^([0-9]+)\s\1$' <<< "$current"; then return; fi
        if [[ "$current" == "$previous" ]]; then quiet=$((quiet + 1)); else quiet=0; fi
        previous=$current
        sleep 5
    done
}

interleaved() {
    local minimum=${Z8_INTERLEAVED_MIN_RATIO:-0.70} passed=1 phase slot pid
    local -a pids
    [[ "$minimum" =~ ^0\.[0-9]+$|^1(\.0+)?$ ]]
    discard_test_blocks
    for phase in baseline interleaved; do
        wait_for_reclaim
        monitor_start "$log_dir/watermark-$phase.tsv"
        pids=()
        for slot in {0..3}; do
            (
                args=(--ioengine=psync --rw=write --direct=0 --bs=256k --allow_file_create=0 --end_fsync=1
                      --refill_buffers=1 --buffer_compress_percentage=0 --flow_sleep=1000
                      --output-format=json --output="$log_dir/$phase-sata$slot.json")
                while IFS=$'\t' read -r name device offset size flow; do
                    args+=(--name="$name" --filename="$device" --offset="$offset" --size="$size")
                    if (( flow )); then args+=(--flow="$flow"); else args+=(--stonewall); fi
                done < <(interleaved_jobs "$phase" "$slot")
                started=$SECONDS
                fio "${args[@]}"
                # Buffered like Buildbarn's writes; the time includes the final flush.
                echo "$((SECONDS - started))" > "$log_dir/$phase-sata$slot.seconds"
            ) & pids+=($!)
        done
        for pid in "${pids[@]}"; do wait "$pid" || passed=0; done
        monitor_stop || passed=0
        snapshot >> "$log_dir/watermark-$phase.tsv"
    done
    nvme smart-log "$Z8_OPTANE" > "$log_dir/optane-end.log"
    wait_for_reclaim
    discard_test_blocks
    (( passed )) || { echo 'FAIL: a writer or the cache sampler stopped early'; exit 1; }

    printf 'sata\tbaseline_MB_s\tinterleaved_MB_s\tratio\tbaseline_min_free_cache_zones\tinterleaved_min_free_cache_zones\n' \
        > "$log_dir/interleaved-summary.tsv"
    for slot in {0..3}; do
        awk -F '\t' -v slot="$slot" -v bytes="$(((head_gib[0] + head_gib[1] + head_gib[2]) * 8 << 30))" \
            -v baseline="$(< "$log_dir/baseline-sata$slot.seconds")" \
            -v interleaved="$(< "$log_dir/interleaved-sata$slot.seconds")" '
            FNR == 1 {file++; next}
            $2 == slot && (!(file in low) || $3 < low[file]) {low[file] = $3}
            END {
                printf "%d\t%.1f\t%.1f\t%.3f\t%d\t%d\n", slot, bytes/baseline/1e6, bytes/interleaved/1e6,
                    baseline/interleaved, low[1], low[2]
            }
        ' "$log_dir/watermark-baseline.tsv" "$log_dir/watermark-interleaved.tsv" >> "$log_dir/interleaved-summary.tsv"
    done
    cat "$log_dir/interleaved-summary.tsv"
    if awk -F '\t' -v minimum="$minimum" 'NR > 1 && $4 < minimum {slow = 1} END {exit !slow}' \
        "$log_dir/interleaved-summary.tsv"; then
        echo "FAIL: 24 interleaved appends ran below $minimum of the sequential rate of the same disk"
        exit 1
    fi
    echo "PASS: 24 interleaved appends per disk kept at least $minimum of the sequential rate"
}

"$mode"
