#!/usr/bin/env bash
set -euo pipefail

script=z8-kit/storage/z8-storage
tmp=$(mktemp -d)
trap 'rm -r -- "$tmp"' EXIT
export Z8_TEST="$tmp"
export Z8_STORAGE_CONFIG="$tmp/config"
export PATH="$tmp/bin:$PATH"
mkdir -p "$tmp"/{bin,config,dev/disk/by-id,dev/mapper,sys/class/block}

# Only in the test copy, use file fixtures and a substitute sysfs tree.
sed -e 's/ -b / -f /g' -e "s@/dev/@$tmp/dev/@g" \
    -e "s@/sys/class/block/@$tmp/sys/class/block/@g" "$script" > "$tmp/storage"
printf 'Z8_SPECIAL=%s/dev/disk/by-id/nvme-optane-part8\nZ8_POOL_GUID=123456\nZ8_DEVICE_WAIT=1\n' \
    "$tmp" > "$Z8_STORAGE_CONFIG/storage.env"
for i in {0..6}; do
    printf 'hc620-%s\t%s/dev/disk/by-id/ata-disk%s\t%s/dev/disk/by-id/nvme-optane-part%s\n' \
        "$i" "$tmp" "$i" "$tmp" "$((i+1))"
    touch "$tmp/dev/disk/by-id/ata-disk$i" "$tmp/dev/disk/by-id/nvme-optane-part$((i+1))"
done > "$Z8_STORAGE_CONFIG/hybrid.tsv"
touch "$tmp/dev/disk/by-id/nvme-optane-part8"
# p9 is deliberately absent: pool import is independent of the cold index.

for cmd in modprobe udevadm; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/$cmd"
done
printf '#!/usr/bin/env bash\necho host-managed\n' > "$tmp/bin/lsblk"
cat > "$tmp/bin/dmzadm" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == --start ]]
i=${3##*ata-disk}
mapper="dm-$i"
ln -s "$Z8_TEST/dev/$mapper" "$Z8_TEST/dev/mapper/hc620-$i"
touch "$Z8_TEST/dev/$mapper"
mkdir -p "$Z8_TEST/sys/class/block/$mapper/slaves"
touch "$Z8_TEST/sys/class/block/$mapper/slaves/${2##*/}" \
    "$Z8_TEST/sys/class/block/$mapper/slaves/${3##*/}"
MOCK
cat > "$tmp/bin/dmsetup" <<'MOCK'
#!/usr/bin/env bash
name=${@: -1}
case "$1" in
    info) test -L "$Z8_TEST/dev/mapper/$name" ;;
    table)
        test -L "$Z8_TEST/dev/mapper/$name" || exit 1
        if [[ -e "$Z8_TEST/foreign-$name" ]]; then
            if [[ "$2" == --target ]]; then exit 0; fi
            echo '0 1000 linear 8:0 0'
        else
            echo '0 1000 zoned'
        fi
        ;;
    remove) rm -- "$Z8_TEST/dev/mapper/$name" ;;
    *) exit 2 ;;
esac
MOCK
cat > "$tmp/bin/zpool" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
    list)
        [[ -f "$Z8_TEST/imported" ]]
        if [[ "$4" == guid ]]; then echo 123456; else echo z8data; fi
        ;;
    import)
        printf '%s\n' "$@" > "$Z8_TEST/import.args"
        touch "$Z8_TEST/imported"
        ;;
    export) rm -- "$Z8_TEST/imported" ;;
    *) exit 2 ;;
esac
MOCK
chmod +x "$tmp"/bin/*

bash "$tmp/storage" map
bash "$tmp/storage" import
[[ $(grep -c '/dev/mapper/hc620-' "$tmp/import.args") -eq 7 ]]
grep -qx '123456' "$tmp/import.args"
if bash "$tmp/storage" unmap; then echo 'Unmapped a live pool' >&2; exit 1; fi
rm -- "$tmp/dev/disk/by-id/ata-disk3"
bash "$tmp/storage" export
bash "$tmp/storage" unmap
[[ -z $(ls -A "$tmp/dev/mapper") ]]

touch "$tmp/dev/disk/by-id/ata-disk3"
bash "$tmp/storage" map
rm -- "$tmp/dev/disk/by-id/ata-disk3"
bash "$tmp/storage" map
bash "$tmp/storage" import
[[ $(grep -c '/dev/mapper/hc620-' "$tmp/import.args") -eq 6 ]]
if grep -q 'hc620-3' "$tmp/import.args"; then exit 1; fi
bash "$tmp/storage" export
bash "$tmp/storage" unmap
[[ -z $(ls -A "$tmp/dev/mapper") ]]

rm -- "$tmp/dev/disk/by-id/ata-disk2"
if bash "$tmp/storage" map; then echo 'Started with five HDDs' >&2; exit 1; fi
if bash "$tmp/storage" import; then echo 'Imported with five HDDs' >&2; exit 1; fi
# Isolate the special-partition failure with all seven HDDs present.
touch "$tmp/dev/disk/by-id/ata-disk2" "$tmp/dev/disk/by-id/ata-disk3"
bash "$tmp/storage" unmap
rm -- "$tmp/dev/disk/by-id/nvme-optane-part8"
if bash "$tmp/storage" map; then echo 'Started without p8' >&2; exit 1; fi
if bash "$tmp/storage" import; then echo 'Imported without p8' >&2; exit 1; fi
touch "$tmp/dev/disk/by-id/nvme-optane-part8"
bash "$tmp/storage" map
touch "$tmp/foreign-hc620-3"
if bash "$tmp/storage" unmap; then echo 'Unmapped a foreign device' >&2; exit 1; fi
[[ $(ls -A "$tmp/dev/mapper") == hc620-3 ]]
echo 'Mock storage paths passed: 7/6/5 disks, runtime HDD loss, missing p8, and live-pool/foreign mapping guards.'
