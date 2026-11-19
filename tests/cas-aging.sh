#!/usr/bin/env bash
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -r -- "$tmp"' EXIT
export PATH="$tmp/bin:$PATH" Z8_STORAGE_CONFIG="$tmp/config" Z8_TEST="$tmp"
mkdir -p "$tmp"/{bin,config,dev,sys,lock,logs}
# shellcheck disable=SC2016
sed -e "s|/usr/local/sbin/z8-cold|$tmp/bin/z8-cold|" -e "s|/dev/mapper/|$tmp/dev/|g" \
    -e "s|/run/lock/|$tmp/lock/|" -e "s|/sys/class/block/|$tmp/sys/|" \
    -e 's|\$EUID == 0|1 == 1|' -e 's|-b "\$device"|-e "$device"|' \
    z8-kit/storage/cas-aging.sh > "$tmp/cas-aging.sh"
echo 'Z8_OPTANE=/dev/null' > "$tmp/config/storage.env"
echo '{"active":[]}' > "$tmp/config/cold-layout.json"
for slot in {0..3}; do
    for name in "hc620-$slot" "z8-cold-sata$slot-"{0..7}; do
        touch "$tmp/dev/$name"
        mkdir "$tmp/sys/$name"
        echo '0 0 0 0 0 0 2048 0' > "$tmp/sys/$name/stat"
    done
done
cat > "$tmp/bin/z8-cold" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == list ]] && printf '%s\n' sata{0..3}-{0..7}
EOF
cat > "$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo inactive
EOF
cat > "$tmp/bin/dmsetup" <<'EOF'
#!/usr/bin/env bash
case $1 in
    info) echo 0 ;;
    # Free cache zones drop while a writer runs.
    status) if [[ -e "$Z8_TEST/writing" ]]; then echo '0 1 zoned a b 41/92 cache'; else echo '0 1 zoned a b 92/92 cache'; fi ;;
    *) exit 2 ;;
esac
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
# The interleaved phase takes twice as long as the baseline and spans one 5 s sample of a busy cache.
cat > "$tmp/bin/fio" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$Z8_TEST/fio"
touch "$Z8_TEST/writing"
# The sequential mode writes directly and is judged on wall-clock time only, so it need not take any.
if [[ "$*" == *--flow=4* ]]; then sleep 8; elif [[ "$*" != *--direct=1\ * ]]; then sleep 4; fi
rm -f "$Z8_TEST/writing"
EOF
chmod +x "$tmp"/bin/*

# The plan needs neither root nor devices.
[[ $(bash z8-kit/storage/cas-aging.sh plan | wc -l) == 128 ]]
if bash "$tmp/cas-aging.sh" interleaved "$tmp/logs" <<< no >/dev/null 2>&1; then
    echo 'Ran without the confirmation' >&2
    exit 1
fi
[[ ! -e "$tmp/fio" && ! -e "$tmp/discards" ]]

# Half the sequential rate fails the default gate and passes a lower one.
if output=$(bash "$tmp/cas-aging.sh" interleaved "$tmp/logs" <<< EMPTY-COLD 2>&1); then
    echo 'Accepted interleaved appends at half the sequential rate' >&2
    exit 1
fi
grep -q 'FAIL: 24 interleaved appends ran below 0.70' <<< "$output"
logs=("$tmp"/logs/cas-interleaved.*)
summary="${logs[0]}/interleaved-summary.tsv"
[[ $(wc -l < "$summary") == 5 ]]
awk -F '\t' 'NR > 1 && !($4 > 0.40 && $4 < 0.70 && $6 == 41) {exit 1}' "$summary"
# Every shard is discarded before and after: blocks 8-12, 87.5 GiB from 140 GiB.
[[ $(wc -l < "$tmp/discards") == 64 ]]
[[ $(sort -u "$tmp/discards" | wc -l) == 32 ]]
grep -qx -- "--offset 150323855360 --length 93952409600 $tmp/dev/z8-cold-sata3-7" "$tmp/discards"
# Four disks, two phases. The baseline is one stream at a time, the other 24 weighted appends.
[[ $(wc -l < "$tmp/fio") == 8 && $(grep -c -- '--direct=0 ' "$tmp/fio") == 8 ]]
[[ $(grep -c -- '--flow=4' "$tmp/fio") == 4 ]]
while read -r line; do
    names=$(grep -o -- '--name=' <<< "$line" | wc -l)
    if [[ "$line" == *--flow=* ]]; then
        [[ $names == 24 && "$line" != *--stonewall* ]]
        [[ $(grep -o -- '--flow=[421]' <<< "$line" | sort | uniq -c | awk '{print $1}' | xargs) == '8 8 8' ]]
    else
        [[ $names == 8 && $(grep -o -- '--stonewall' <<< "$line" | wc -l) == 8 ]]
    fi
done < "$tmp/fio"
rm -r "$tmp/fio" "$tmp/discards" "${logs[0]}"
output=$(Z8_INTERLEAVED_MIN_RATIO=0.40 bash "$tmp/cas-aging.sh" interleaved "$tmp/logs" <<< EMPTY-COLD 2>&1)
grep -q 'PASS: 24 interleaved appends per disk kept at least 0.40' <<< "$output"

# The sequential mode seeds and overwrites sataN-0 three times, then hands those 128 GiB back.
rm -r "$tmp/fio" "$tmp/discards"
output=$(bash "$tmp/cas-aging.sh" sequential "$tmp/logs" <<< EMPTY-COLD 2>&1)
grep -q 'PASS: aggregate steady overwrite >= 150 MB/s' <<< "$output"
[[ $(wc -l < "$tmp/fio") == 4 && $(grep -c -- '--direct=1 ' "$tmp/fio") == 4 ]]
[[ $(grep -o -- "--filename=$tmp/dev/z8-cold-sata[0-3]-0" "$tmp/fio" | wc -l) == 16 ]]
[[ $(cat "$tmp/discards") == "$(printf -- "--length 137438953472 $tmp/dev/z8-cold-sata%s-0\n" 0 1 2 3)" ]]
# A device that refuses the discard leaves the verdict as it is and says what is left behind.
touch "$tmp/no-discard"
output=$(bash "$tmp/cas-aging.sh" sequential "$tmp/logs" <<< EMPTY-COLD 2>&1)
grep -q 'PASS: aggregate steady overwrite >= 150 MB/s' <<< "$output"
[[ $(grep -c 'still holds the test data' <<< "$output") == 4 ]]
echo 'Cold aging tests passed: interleaved plan, discards, rate gate and the sequential mode.'
