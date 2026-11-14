#!/usr/bin/env bash
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -r -- "$tmp"' EXIT
export Z8_FIXTURE="$tmp"
export PATH="$tmp/bin:$PATH"
export Z8_PMEM_DEVICE_WAIT=0 Z8_MEMMAP_ON_MEMORY=1 Z8_ENABLE_DEMOTION=1
export Z8_DAX0_UUID=00000000-0000-0000-0000-000000000001
export Z8_DAX1_UUID=00000000-0000-0000-0000-000000000002
fs0=00000000-0000-0000-0000-000000000003
fs1=00000000-0000-0000-0000-000000000004
mkdir -p "$tmp"/{bin,dev,sys/module/memory_hotplug/parameters,sys/kernel/mm/numa}

# Only the disposable script copies know the fixture paths.
for script in pmem-device-wait pmem-kmem pmem-dax-stripe; do
    sed -e 's/ -b / -f /g' -e "s@/sys/@$tmp/sys/@g" -e "s@/dev/@$tmp/dev/@g" \
        "z8-kit/host/$script.sh" > "$tmp/$script.sh"
done
for device in dax0.0 dax1.0; do
    path="$tmp/sys/bus/dax/devices/$device"
    mkdir -p "$path"
    ln -s /drivers/device_dax "$path/driver"
    printf '0\n' > "$path/memmap_on_memory"
done
printf '0\n' > "$tmp/sys/kernel/mm/numa/demotion_enabled"
touch "$tmp/dev/pmem0"
cat > "$tmp/fsdax.json" <<EOF
[
  {"uuid":"$fs0","mode":"fsdax","blockdev":"pmem0"},
  {"uuid":"$fs1","mode":"fsdax","blockdev":"pmem1.1"}
]
EOF
cat > "$tmp/devdax.json" <<EOF
[
  {"uuid":"$Z8_DAX0_UUID","mode":"devdax","daxregion":{"devices":[{"chardev":"dax0.0"}]}},
  {"uuid":"$Z8_DAX1_UUID","mode":"devdax","daxregion":{"devices":[{"chardev":"dax1.0"}]}}
]
EOF
cat > "$tmp/bin/ndctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${3:-} == --device-dax ]]; then
    cat "$Z8_FIXTURE/devdax.json"
elif [[ -f "$Z8_FIXTURE/enumerating" ]]; then
    jq '.[0]' "$Z8_FIXTURE/fsdax.json"
else
    cat "$Z8_FIXTURE/fsdax.json"
fi
EOF
cat > "$tmp/bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
rm -f -- "$Z8_FIXTURE/enumerating"
touch "$Z8_FIXTURE/dev/pmem1.1"
ln -sfn /drivers/device_dax "$Z8_FIXTURE/sys/bus/dax/devices/dax1.0/driver"
EOF
cat > "$tmp/bin/daxctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
    list)
        cat "$Z8_FIXTURE/$4.json"
        ;;
    reconfigure-device|online-memory)
        device=${@: -1}
        for dax in dax0.0 dax1.0; do
            test "$(cat "$Z8_FIXTURE/sys/bus/dax/devices/$dax/memmap_on_memory")" = 1
        done
        printf '%s %s\n' "$1" "$device" >> "$Z8_FIXTURE/actions"
        ln -sfn /drivers/kmem "$Z8_FIXTURE/sys/bus/dax/devices/$device/driver"
        printf '[{"chardev":"%s","mode":"system-ram","online_memblocks":2,"total_memblocks":2,"movable":true}]\n' \
            "$device" > "$Z8_FIXTURE/$device.json"
        ;;
    *) exit 2 ;;
esac
EOF
printf '#!/usr/bin/env bash\necho 16500\n' > "$tmp/bin/blockdev"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/numactl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/udevadm"
cat > "$tmp/bin/dmsetup" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    info) test -f "$Z8_FIXTURE/dm-table" ;;
    table) cat "$Z8_FIXTURE/dm-table" ;;
    create)
        mkdir -p "$Z8_FIXTURE/dev/mapper"
        touch "$Z8_FIXTURE/dev/mapper/z8-pmem-model"
        printf '0 32768 striped 2 4096 259:0 0 259:1 0\n' > "$Z8_FIXTURE/dm-table"
        ;;
    remove) rm -- "$Z8_FIXTURE/dm-table" "$Z8_FIXTURE/dev/mapper/z8-pmem-model" ;;
    *) exit 2 ;;
esac
EOF
cat > "$tmp/bin/lsblk" <<'EOF'
#!/usr/bin/env bash
case "${3##*/}" in
    pmem0) echo '259:0' ;;
    pmem1.1) echo '259:1' ;;
    z8-pmem-model) echo '252:0' ;;
    *) exit 2 ;;
esac
EOF
cat > "$tmp/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
[[ "$2" == -M && -f "$Z8_FIXTURE/mounted" ]] || exit 1
cat "$Z8_FIXTURE/mounted"
EOF
cat > "$tmp/bin/mount" <<'EOF'
#!/usr/bin/env bash
test ! -e "$Z8_FIXTURE/mounted" || exit 1
[[ "$*" == *'-t xfs -o dax=always,noatime,nodiscard '* ]] || exit 1
echo '252:0 xfs rw,noatime,dax=always' > "$Z8_FIXTURE/mounted"
EOF
cat > "$tmp/bin/umount" <<'EOF'
#!/usr/bin/env bash
test "$1" = /srv/pmem-model
rm -- "$Z8_FIXTURE/mounted"
EOF
chmod +x "$tmp"/bin/*

expect_failure() {
    local message=$1
    shift
    if "$@" > "$tmp/failure.log" 2>&1; then
        echo "Unexpected success: $*" >&2
        exit 1
    fi
    if ! grep -Fq -- "$message" "$tmp/failure.log"; then
        cat "$tmp/failure.log" >&2
        exit 1
    fi
}

expect_failure 'two distinct' bash "$tmp/pmem-dax-stripe.sh" show "$fs0" "$fs0"
expect_failure 'block device is missing' bash "$tmp/pmem-dax-stripe.sh" show "$fs0" "$fs1"
touch "$tmp/enumerating"
Z8_PMEM_DEVICE_WAIT=2 bash "$tmp/pmem-dax-stripe.sh" show "$fs0" "$fs1" > "$tmp/table"
grep -Fxq "0 32768 striped 2 4096 $tmp/dev/pmem0 0 $tmp/dev/pmem1.1 0" "$tmp/table"
mkdir -p "$tmp/sys/class/block/"{pmem0,pmem1.1}/holders
bash "$tmp/pmem-dax-stripe.sh" create "$fs0" "$fs1"
bash "$tmp/pmem-dax-stripe.sh" mount "$fs0" "$fs1"
bash "$tmp/pmem-dax-stripe.sh" mount "$fs0" "$fs1"
printf '252:1 xfs rw,noatime,dax=always\n' > "$tmp/mounted"
expect_failure 'unexpected filesystem' bash "$tmp/pmem-dax-stripe.sh" mount "$fs0" "$fs1"
expect_failure 'unexpected filesystem' bash "$tmp/pmem-dax-stripe.sh" unmount "$fs0" "$fs1"
printf '252:0 xfs rw,noatime,dax=always\n' > "$tmp/mounted"
bash "$tmp/pmem-dax-stripe.sh" unmount "$fs0" "$fs1"
test ! -e "$tmp/mounted" && test ! -e "$tmp/dm-table"
bash "$tmp/pmem-dax-stripe.sh" unmount "$fs0" "$fs1"
bash "$tmp/pmem-dax-stripe.sh" create "$fs0" "$fs1"
printf '0 32768 striped 2 4096 259:1 0 259:0 0\n' > "$tmp/dm-table"
expect_failure 'different device table' bash "$tmp/pmem-dax-stripe.sh" create "$fs0" "$fs1"

param="$tmp/sys/module/memory_hotplug/parameters/memmap_on_memory"
printf 'N\n' > "$param"
expect_failure 'Boot with memory_hotplug.memmap_on_memory=on' bash "$tmp/pmem-kmem.sh"
printf 'Y\n' > "$param"
rm -- "$tmp/sys/bus/dax/devices/dax1.0/driver"
expect_failure 'has no DAX driver yet' bash "$tmp/pmem-kmem.sh"
test ! -e "$tmp/actions"
test "$(cat "$tmp/sys/kernel/mm/numa/demotion_enabled")" = 0
printf 'force\n' > "$param"
Z8_PMEM_DEVICE_WAIT=2 bash "$tmp/pmem-kmem.sh"
diff -u <(printf 'reconfigure-device dax0.0\nreconfigure-device dax1.0\n') "$tmp/actions"
test "$(cat "$tmp/sys/kernel/mm/numa/demotion_enabled")" = 1
bash "$tmp/pmem-kmem.sh"
test "$(wc -l < "$tmp/actions")" -eq 2
printf '[{"chardev":"dax1.0","mode":"system-ram","online_memblocks":1,"total_memblocks":2}]\n' > "$tmp/dax1.0.json"
bash "$tmp/pmem-kmem.sh"
test "$(tail -n 1 "$tmp/actions")" = 'online-memory dax1.0'
test "$(wc -l < "$tmp/actions")" -eq 3
printf '[{"chardev":"dax1.0","mode":"system-ram","online_memblocks":2,"total_memblocks":2,"movable":false}]\n' > "$tmp/dax1.0.json"
expect_failure 'not all online and movable' bash "$tmp/pmem-kmem.sh"
test "$(wc -l < "$tmp/actions")" -eq 3
echo 'PMem tests passed: late namespaces and driver, timeout, memmap gate, full online, retry and zone validation.'
