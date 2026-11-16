#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

declare -A minima
summary() {
    printf '\nMinimum free cache zones (sampled every 5 s):\n'
    for slot in {0..3}; do
        printf 'SATA%s %s\n' "$slot" "${minima[$slot]:-unavailable}"
    done
}
trap summary EXIT
trap 'exit 0' INT TERM

while :; do
    timestamp=$(date -Is)
    observed=0
    for slot in {0..3}; do
        if ! line=$(dmsetup status "hc620-$slot" 2>/dev/null); then continue; fi
        read -ra fields <<< "$line"
        if [[ ${fields[2]:-} != zoned || ${fields[6]:-} != cache ||
            ! ${fields[5]:-} =~ ^([0-9]+)/([1-9][0-9]*)$ ]]; then
            printf 'Unexpected dm-zoned status for SATA%s: %s\n' "$slot" "$line" >&2
            exit 1
        fi
        free=${BASH_REMATCH[1]}
        total=${BASH_REMATCH[2]}
        if (( free < ${minima[$slot]:-$total} )); then minima[$slot]=$free
        else minima[$slot]=${minima[$slot]:-$total}
        fi
        printf '%s SATA%s free=%s/%s used_pct=%s\n' "$timestamp" "$slot" "$free" "$total" "$((100 * (total - free) / total))"
        observed=1
    done
    (( observed )) || { echo 'No cold dm-zoned mappers are ready.' >&2; exit 1; }
    sleep 5
done
