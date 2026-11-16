#!/usr/bin/env bash
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -r -- "$tmp"' EXIT
export Z8_TEST="$tmp" Z8_STORAGE_CONFIG="$tmp/config" PATH="$tmp/bin:$PATH"
mkdir -p "$tmp"/{bin,config,dev/disk/by-id,dev/disk/by-partlabel,dev/mapper,sys/class/block,sys/module/zfs}

sed -e 's/ -b / -f /g' -e "s@/dev/@$tmp/dev/@g" -e "s@/sys/@$tmp/sys/@g" \
    z8-kit/storage/z8-storage > "$tmp/storage"
printf 'Z8_OPTANE=%s/dev/disk/by-id/nvme-optane\nZ8_POOL_GUID=123456\nZ8_DEVICE_WAIT=1\n' \
    "$tmp" > "$Z8_STORAGE_CONFIG/storage.env"
for i in {0..6}; do
    printf 'hc620-%s\t%s/dev/disk/by-id/ata-disk%s\tdmz-sata%s\n' "$i" "$tmp" "$i" "$i"
    touch "$tmp/dev/disk/by-id/ata-disk$i" "$tmp/dev/disk/by-partlabel/dmz-sata$i"
done > "$Z8_STORAGE_CONFIG/hybrid.tsv"
touch "$tmp/dev/disk/by-id/nvme-optane" "$tmp/dev/disk/by-partlabel"/{z8-special,z8-cold-index}

for cmd in modprobe udevadm; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/$cmd"
done
cat > "$tmp/bin/lsblk" <<'MOCK'
#!/usr/bin/env bash
case "$2" in
    KNAME) echo nvme-optane ;;
    PKNAME) if [[ -e "$Z8_TEST/foreign-part" && "${@: -1}" == */z8-cold-index ]]; then echo other; else echo nvme-optane; fi ;;
    ZONED) echo host-managed ;;
    *) echo 'fixture disk' ;;
esac
MOCK
cat > "$tmp/bin/blockdev" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == '--getss' ]]; then
    if [[ "$2" == */nvme-optane ]]; then echo 512; else echo 4096; fi
    exit
fi
case "$2" in
    */nvme-optane) echo 1500301910016 ;;
    */z8-special) echo 228990524928 ;;
    */z8-cold-index) echo 910533066752 ;;
    */dmz-sata[0-3]) echo 25769803776 ;;
    */dmz-sata[4-6]) echo 85899345920 ;;
    */hc620-*)
        chunks=$(cat "$Z8_TEST/chunks" 2>/dev/null || echo 52152)
        echo $((chunks * 256 * 1024**2)) ;;
    *) exit 1 ;;
esac
MOCK
cat > "$tmp/bin/dmzadm" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
    --check) exit 0 ;;
    --format)
        [[ "$2" == */dmz-sata[0-6] && "$3" == */ata-disk[0-6] ]]
        printf '%s\n' "$*" >> "$Z8_TEST/format.log"
        exit 0 ;;
    --start) ;;
    *) exit 1 ;;
esac
i=${3##*ata-disk}
mapper="dm-$i"
ln -s "$Z8_TEST/dev/$mapper" "$Z8_TEST/dev/mapper/hc620-$i"
touch "$Z8_TEST/dev/$mapper"
mkdir -p "$Z8_TEST/sys/class/block/$mapper/slaves"
touch "$Z8_TEST/sys/class/block/$mapper/slaves/${2##*/}" "$Z8_TEST/sys/class/block/$mapper/slaves/${3##*/}"
MOCK
cat > "$tmp/bin/dmsetup" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
    info) test -L "$Z8_TEST/dev/mapper/$2" ;;
    table)
        test -L "$Z8_TEST/dev/mapper/$2" || exit 1
        if [[ -e "$Z8_TEST/foreign-$2" ]]; then echo '0 1000 linear 8:0 0'; else printf '0 %s zoned 8:1 8:2\n' "$(( $(blockdev --getsize64 "$Z8_TEST/dev/mapper/$2") / 512 ))"; fi
        ;;
    remove) rm -- "$Z8_TEST/dev/mapper/$2" ;;
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

run() { bash "$tmp/storage" "$@"; }
reject() { if run "$@"; then echo "Unexpected success: $*" >&2; exit 1; fi; }
run format 0 --create <<< hc620-0
run format 6 --replace <<< hc620-6
grep -q -- '--label=hc620-0 --seq=96$' "$tmp/format.log"
grep -q -- '--label=hc620-6 --seq=320 --force$' "$tmp/format.log"
run map
printf '52080\n' > "$tmp/chunks"
run check-map 0
printf '52079\n' > "$tmp/chunks"
reject check-map 0
printf '52157\n' > "$tmp/chunks"
reject check-map 0
rm -- "$tmp/chunks"
reject format 6 --replace <<< hc620-6
[[ $(run cold-ready | wc -l) -eq 4 ]]
run import
[[ $(grep -c '/dev/mapper/hc620-[456]' "$tmp/import.args") -eq 3 ]]
if grep -q 'hc620-[0123]' "$tmp/import.args"; then exit 1; fi
grep -qx '123456' "$tmp/import.args"
reject unmap
rm -- "$tmp/dev/disk/by-id/ata-disk3"
[[ $(run cold-ready | wc -l) -eq 3 ]]
run export
run unmap
[[ -z $(ls -A "$tmp/dev/mapper") ]]

rm -- "$tmp/dev/disk/by-id/ata-disk4"
run map
run import
[[ $(grep -c '/dev/mapper/hc620-[456]' "$tmp/import.args") -eq 2 ]]
run export
rm -- "$tmp/dev/disk/by-id/ata-disk5"
reject import
[[ $(run cold-ready | wc -l) -eq 3 ]]
rm -- "$tmp/dev/disk/by-partlabel/z8-special"
touch "$tmp/dev/disk/by-id/ata-disk4" "$tmp/dev/disk/by-id/ata-disk5"
run map
[[ $(run cold-ready | wc -l) -eq 3 ]]
reject import
touch "$tmp/dev/disk/by-partlabel/z8-special"
touch "$tmp/foreign-part"
reject cold-ready
run import
run export
rm -- "$tmp/foreign-part"
rm -- "$tmp/dev/disk/by-id/nvme-optane"
reject map
reject cold-ready
reject import
touch "$tmp/foreign-hc620-0"
reject unmap
[[ $(ls -A "$tmp/dev/mapper") == hc620-0 ]]

root="$tmp/systemd"
units="$root/etc/systemd/system"
mkdir -p "$units"
install -m 0644 z8-kit/storage/systemd/{data-other.mount,z8-zpool.service,z8-dmzoned.service,z8-cold.service,z8-cold-scan.service,z8-cold-scan@.service,z8-cold-health.service,z8-cold-health.timer,z8-cold-selftest.service,z8-cold-selftest.timer,z8-buildbarn.service} "$units/"
for target in multi-user timers; do printf '[Unit]\nDescription=Target fixture\n' > "$units/$target.target"; done
systemctl --root "$root" --quiet enable data-other.mount z8-cold.service z8-cold-health.timer z8-cold-selftest.timer
[[ -L "$units/multi-user.target.wants/data-other.mount" &&
    -L "$units/multi-user.target.wants/z8-cold.service" &&
    -L "$units/z8-zpool.service.wants/data-other.mount" &&
    -L "$units/timers.target.wants/z8-cold-health.timer" &&
    -L "$units/timers.target.wants/z8-cold-selftest.timer" ]]
grep -Fxq 'ExecStart=/usr/bin/flock /run/lock/z8-cold-scan.lock /usr/local/sbin/z8-cold-scan %i' "$units/z8-cold-scan@.service"
grep -Fxq 'RuntimeDirectory=z8-bb-cache' "$units/z8-buildbarn.service"
grep -Fxq 'Wants=z8-pmem-model.service' "$units/z8-buildbarn.service"
grep -Fxq 'After=docker.service z8-cold.service z8-pmem-model.service' "$units/z8-buildbarn.service"
grep -Fxq 'BindsTo=z8-dmzoned.service' "$units/z8-cold.service"
grep -Fxq 'BindsTo=z8-cold.service' "$units/z8-buildbarn.service"
grep -Fxq 'BindsTo=z8-zpool.service' "$units/data-other.mount"
echo 'Storage tests passed: independent cold and ZFS chains, geometry, and degraded import.'
