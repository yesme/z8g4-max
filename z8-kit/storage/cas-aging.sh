#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

if [[ $# != 2 || $1 != sequential || $EUID != 0 ]]; then
    echo "Usage: sudo bash $0 sequential EXISTING_LOG_DIRECTORY" >&2
    exit 2
fi
config=${Z8_STORAGE_CONFIG:-/etc/z8-storage}
# shellcheck source=/dev/null
source "$config/storage.env"
devices=()
stats=()
mapfile -t shards < <(/usr/local/sbin/z8-cold list)
[[ ${#shards[@]} -eq 32 && $(jq -er '.active | length' "$config/cold-layout.json") == 0 ]]
[[ $(systemctl show -p ActiveState --value z8-buildbarn.service) =~ ^(inactive|failed)$ ]]
exec 9>/run/lock/z8-cold-scan.lock
flock -n 9
log_dir=$(realpath -e -- "$2")
[[ -d "$log_dir" ]]
for slot in {0..3}; do
    device="/dev/mapper/z8-cold-sata$slot-0"
    [[ -b "$device" && $(dmsetup info -c --noheadings -o open "$device") -eq 0 ]]
    devices+=("$device")
    stats+=("/sys/class/block/$(basename "$(readlink -f "$device")")/stat")
done
read -r -p 'This overwrites the first 128 GiB of each sataN-0. Type EMPTY-COLD to proceed: ' confirmation
[[ "$confirmation" == EMPTY-COLD ]] || exit 1
log_dir=$(mktemp -d -- "$log_dir/cas-sequential.XXXXXXXX")
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

printf 'time\tsata\tfree_cache_zones\ttotal_cache_zones\tbytes_written_since_mapper_start\n' > "$log_dir/watermark.tsv"
snapshot >> "$log_dir/watermark.tsv"
nvme smart-log "$Z8_OPTANE" > "$log_dir/optane-start.log"
monitor=
cleanup() {
    if [[ -n "$monitor" ]]; then
        kill "$monitor" 2>/dev/null || true
        wait "$monitor" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
(
    while sleep 5; do snapshot; done
) >> "$log_dir/watermark.tsv" 2>"$log_dir/monitor.err" & monitor=$!

passed=1
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
snapshot >> "$log_dir/watermark.tsv"
nvme smart-log "$Z8_OPTANE" > "$log_dir/optane-end.log"
kill -0 "$monitor" || passed=0
awk -F '\t' '
    NR == 1 {next}
    !($2 in start) {start[$2] = $5}
    $3*100 <= $4*30 && !($2 in seen) {
        seen[$2] = 1
        printf "sata%s first sampled >=70%% used after %.2f GiB wrote\n", $2, ($5-start[$2])/1073741824
    }
    END {for (i=0; i<4; i++) if (!seen[i]) printf "sata%d never sampled >=70%% cache\n", i}
' "$log_dir/watermark.tsv" | tee "$log_dir/watermark-summary.log"
(( passed )) || { echo 'FAIL: last two passes require 150 MB/s aggregate and live monitoring'; exit 1; }
echo 'PASS: aggregate steady overwrite >= 150 MB/s'
