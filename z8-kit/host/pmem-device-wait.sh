#!/usr/bin/env bash
# Sourced by both PMem startup scripts from their own directory.

pmem_wait_devices() {
    local mode=$1 uuid0=${2,,} uuid1=${3,,}
    local uuid_pattern='^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
    local wait_seconds=${Z8_PMEM_DEVICE_WAIT:-90}
    local deadline json names name reason
    local -a options=() found=()

    if [[ ! "$uuid0" =~ $uuid_pattern || ! "$uuid1" =~ $uuid_pattern || "$uuid0" == "$uuid1" ]]; then
        echo 'Specify two distinct ndctl namespace UUIDs' >&2
        return 2
    fi
    if [[ ! "$wait_seconds" =~ ^(0|[1-9][0-9]{0,2})$ ]]; then
        echo 'Z8_PMEM_DEVICE_WAIT must be 0–999 seconds' >&2
        return 2
    fi
    case "$mode" in
        fsdax) ;;
        devdax) options+=(--device-dax) ;;
        *) return 2 ;;
    esac

    deadline=$((SECONDS + wait_seconds))
    while :; do
        json=$(ndctl list --namespaces "${options[@]}") || return 1
        names=$(jq -r --arg first "$uuid0" --arg second "$uuid1" --arg mode "$mode" '
          (if type == "array" then . else [.] end) as $namespaces
          | [$first, $second][] as $id
          | [$namespaces[] | select(.uuid == $id and .mode == $mode)
             | if $mode == "fsdax" then .blockdev else .daxregion.devices[]?.chardev end
             | strings]
          | if length > 1 then error("Multiple devices for namespace " + $id) else .[0] // "-" end
        ' <<< "$json") || return 1
        mapfile -t found <<< "$names"
        reason='both namespaces must be visible in ndctl'
        if (( ${#found[@]} == 2 )) && [[ "${found[0]}" != - && "${found[1]}" != - ]]; then
            if [[ "${found[0]}" == "${found[1]}" ]]; then
                echo "Both $mode namespaces resolve to ${found[0]}" >&2
                return 1
            fi
            reason=
            for name in "${found[@]}"; do
                case "$mode" in
                    fsdax)
                        if [[ ! "$name" =~ ^pmem[0-9]+(\.[0-9]+)?$ ]]; then
                            echo "Invalid fsdax block device name: $name" >&2
                            return 1
                        fi
                        [[ -b "/dev/$name" ]] || reason="/dev/$name block device is missing"
                        ;;
                    devdax)
                        if [[ ! "$name" =~ ^dax[0-9]+\.[0-9]+$ ]]; then
                            echo "Invalid devdax device name: $name" >&2
                            return 1
                        fi
                        [[ -L "/sys/bus/dax/devices/$name/driver" ]] || reason="$name has no DAX driver yet"
                        ;;
                esac
            done
            if [[ -z "$reason" ]]; then
                printf '%s\n' "${found[@]}"
                return 0
            fi
        fi
        if (( SECONDS >= deadline )); then
            echo "$mode timeout after ${wait_seconds}s for $uuid0 and $uuid1: $reason" >&2
            return 1
        fi
        sleep 1
    done
}
