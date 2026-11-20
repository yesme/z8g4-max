#!/usr/bin/env bash
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -r -- "$tmp"' EXIT
export PATH="$tmp/bin:$PATH" Z8_STORAGE_CONFIG="$tmp/config" Z8_TEST="$tmp"
mkdir -p "$tmp"/{bin,config,dev,sys,lock,logs}
# Use regular files and a separate deterministic clock for each simulated disk.
# shellcheck disable=SC2016
sed -e "s|/usr/local/sbin/z8-cold|$tmp/bin/z8-cold|" -e "s|/dev/mapper/|$tmp/dev/|g" \
    -e "s|/run/lock/|$tmp/lock/|" -e "s|/sys/class/block/|$tmp/sys/|" \
    -e 's|\$EUID == 0|1 == 1|' -e 's|-b "\$device"|-e "$device"|' \
    -e 's|/proc/uptime|"$Z8_TEST/clock-$slot"|' -e 's/^        sleep 5$/        test-tick "$slot"/' \
    z8-kit/storage/cas-aging.sh > "$tmp/cas-aging.sh"
echo 'Z8_OPTANE=/dev/null' > "$tmp/config/storage.env"
for slot in {0..3}; do
    echo 100 > "$tmp/clock-$slot"
    for name in "hc620-$slot" "z8-cold-sata$slot-"{0..7}; do
        touch "$tmp/dev/$name"
        mkdir "$tmp/sys/$name"
        echo '0 0 0 0 0 0 2048 0' > "$tmp/sys/$name/stat"
    done
done
cat > "$tmp/bin/z8-cold" <<'EOF'
#!/usr/bin/env bash
[[ $* == i4-list ]] || exit 2
# Eligibility must be checked under the same lock that excludes reset/disable.
if flock -n "$Z8_TEST/lock/z8-cold-scan.lock" true; then exit 3; fi
printf '%s\n' sata{0..3}-{0..7}
[[ ! -e "$Z8_TEST/ineligible" ]]
EOF
cat > "$tmp/bin/dmsetup" <<'EOF'
#!/usr/bin/env bash
case $1 in
    info) echo 0 ;;
    status)
        slot=${2#hc620-}
        free=92
        if [[ -e "$Z8_TEST/ready-$slot" ]] && (( $(< "$Z8_TEST/clock-$slot") < $(< "$Z8_TEST/ready-$slot") )); then free=41; fi
        echo "0 1 zoned a b $free/92 cache" ;;
    *) exit 2 ;;
esac
EOF
cat > "$tmp/bin/test-tick" <<'EOF'
#!/usr/bin/env bash
p="$Z8_TEST/clock-$1"
echo "$(( $(< "$p") + 5 ))" > "$p"
EOF
cat > "$tmp/bin/blockdev" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == --getsize64 ]] && echo 1747514818560
EOF
cat > "$tmp/bin/nvme" <<'EOF'
#!/usr/bin/env bash
echo 'temperature : 40 C'
EOF
cat > "$tmp/bin/blkdiscard" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$Z8_TEST/discards"
[[ ! -e "$Z8_TEST/no-discard" ]]
EOF
cat > "$tmp/bin/fio" <<'EOF'
#!/usr/bin/env bash
set -eu
echo "$*" >> "$Z8_TEST/fio"
if [[ "$*" == *--direct=1\ * ]]; then exit 0; fi
[[ ! -e "$Z8_TEST/discards" ]] || { echo 'Discard before completion' >&2; exit 1; }
[[ "$*" =~ /(seed|baseline|interleaved)-sata([0-3])\.json ]]
phase=${BASH_REMATCH[1]} slot=${BASH_REMATCH[2]}
clock="$Z8_TEST/clock-$slot"
case $phase in
    seed) front=110; tail=5 ;;
    baseline) front=90; tail=10 ;;
    interleaved) front=60; tail=90 ;;
esac
echo "$(( $(< "$clock") + front ))" > "$clock"
echo "$(( $(< "$clock") + tail ))" > "$Z8_TEST/ready-$slot"
EOF
chmod +x "$tmp"/bin/*

# A failed guard may even have printed a full inventory. Neither entry point can write.
touch "$tmp/ineligible"
for mode in sequential interleaved; do
    if bash "$tmp/cas-aging.sh" "$mode" "$tmp/logs" <<< EMPTY-COLD; then exit 1; fi
done
rm "$tmp/ineligible"
if bash "$tmp/cas-aging.sh" interleaved "$tmp/logs" <<< no; then exit 1; fi
[[ ! -e "$tmp/fio" && ! -e "$tmp/discards" ]]

# Faster foreground, slower drain: 90/60 passes but (90+10)/(60+90) fails 70%.
if output=$(bash "$tmp/cas-aging.sh" interleaved "$tmp/logs" <<< EMPTY-COLD 2>&1); then exit 1; fi
grep -q 'FAIL: drained 24-way overwrite below 0.70' <<< "$output"
logs=("$tmp"/logs/cas-interleaved.*)
summary="${logs[0]}/interleaved-summary.tsv"
[[ $(wc -l < "$summary") == 5 ]]
awk -F '\t' 'NR > 1 && !($2==90 && $3==10 && $4==100 && $5==60 && $6==90 && $7==150 &&
    $10>0.666 && $10<0.667) {exit 1}' "$summary"
[[ $(wc -l < "$tmp/fio") == 12 && $(grep -c -- '--flow=4' "$tmp/fio") == 4 ]]
while read -r line; do
    [[ $(grep -o -- '--name=' <<< "$line" | wc -l) == 24 ]]
    if [[ "$line" == *--flow=* ]]; then
        [[ "$line" != *--stonewall* ]]
        [[ $(grep -o -- '--flow=[421]' <<< "$line" | sort | uniq -c | awk '{print $1}' | xargs) == '8 8 8' ]]
    else
        [[ $(grep -o -- '--stonewall' <<< "$line" | wc -l) == 24 ]]
    fi
done < "$tmp/fio"
# Exactly the 96 touched windows are discarded once, after the last phase.
bash "$tmp/cas-aging.sh" plan | awk -F '\t' '$1=="seed" {print "--offset " $5 " --length " $6 " " $4}' | sort > "$tmp/expected"
sort "$tmp/discards" | diff - "$tmp/expected"
rm "$tmp/fio" "$tmp/discards"
output=$(Z8_INTERLEAVED_MIN_RATIO=0.65 bash "$tmp/cas-aging.sh" interleaved "$tmp/logs" <<< EMPTY-COLD 2>&1)
grep -q 'PASS: drained 24-way overwrite' <<< "$output"
rm "$tmp/fio" "$tmp/discards"

# A nonempty plateau must fail and retain diagnostic data without discarding.
if output=$(Z8_RECLAIM_TIMEOUT_SECONDS=15 bash "$tmp/cas-aging.sh" interleaved "$tmp/logs" <<< EMPTY-COLD 2>&1); then exit 1; fi
grep -q 'interleaved sata0 reclaim timed out (41/92' <<< "$output"
[[ ! -e "$tmp/discards" ]]
rm "$tmp/fio"

# Reallocated sequential budget, with the original four passes and sustained rate gate.
output=$(bash "$tmp/cas-aging.sh" sequential "$tmp/logs" <<< EMPTY-COLD 2>&1)
grep -q 'PASS: aggregate steady overwrite >= 150 MB/s' <<< "$output"
[[ $(grep -c -- '--size=72G' "$tmp/fio") == 4 ]]
[[ $(cat "$tmp/discards") == "$(printf -- "--length 77309411328 $tmp/dev/z8-cold-sata%s-0\n" 0 1 2 3)" ]]
touch "$tmp/no-discard"
output=$(bash "$tmp/cas-aging.sh" sequential "$tmp/logs" <<< EMPTY-COLD 2>&1)
[[ $(grep -c 'still holds the test data' <<< "$output") == 4 ]]
echo 'Cold aging tests passed.'
