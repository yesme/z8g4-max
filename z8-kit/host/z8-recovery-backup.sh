#!/usr/bin/env bash
set -euo pipefail
umask 077

die() { printf '%s\n' "$*" >&2; exit 1; }
(( EUID == 0 )) || die 'Run this backup as root.'
mode=${1:-backup}
if (( $# > 1 )) || [[ "$mode" != backup && "$mode" != --refresh-boot && "$mode" != --stdout ]]; then
    die 'Usage: z8-recovery-backup [--refresh-boot | --stdout]'
fi

boot_dir=/boot
lock=/run/z8-recovery-backup.lock
exec 9>"$lock"
flock -n 9 || die 'Another recovery backup is running.'

boot_source=$(findmnt -rn -M "$boot_dir" -t ext4 -o SOURCE) ||
    die 'The ext4 FIT boot partition must be mounted.'
esp_source=$(findmnt -rn -M "$boot_dir/efi" -t vfat -o SOURCE) ||
    die 'The FIT ESP must be mounted.'
boot_parent=$(lsblk -dnro PKNAME -- "$boot_source")
esp_parent=$(lsblk -dnro PKNAME -- "$esp_source")
[[ -n "$boot_parent" && "$boot_parent" == "$esp_parent" ]] ||
    die '/boot and /boot/efi must be on the same disk.'

recovery_device=
if [[ "$mode" != --stdout ]]; then
    recovery_device=$(blkid -c /dev/null -t LABEL=Z8RECOVERY -o device) ||
        die 'No partition labelled Z8RECOVERY.'
    [[ "$recovery_device" != *$'\n'* && -b "$recovery_device" ]] ||
        die 'Expected exactly one Z8RECOVERY block device.'
    [[ $(lsblk -dnro TYPE,FSTYPE -- "$recovery_device") == 'part ext4' &&
       $(lsblk -dnro PKNAME -- "$recovery_device") == "$boot_parent" ]] ||
        die 'Z8RECOVERY must be an ext4 partition on the FIT boot disk.'
    [[ $(lsblk -dnro MAJ:MIN -- "$recovery_device") != "$(lsblk -dnro MAJ:MIN -- "$boot_source")" ]] ||
        die 'Z8RECOVERY cannot be /boot.'
    if findmnt -rn -S "$recovery_device" >/dev/null; then die 'Unmount Z8RECOVERY before backing up.'; fi
fi

work=$(mktemp -d)
snapshot="$work/metadata"
volume="$work/fit"
stage=
pending_link=
mounted=0
cleanup() {
    local status=$?
    trap - EXIT
    if (( mounted )); then
        [[ -z "$pending_link" ]] || rm -f -- "$pending_link" || status=1
        [[ -z "$stage" ]] || rm -rf --one-file-system -- "$stage" || status=1
        if ! umount "$volume"; then
            printf 'Failed to unmount %s\n' "$volume" >&2
            exit 1
        fi
    fi
    rm -rf --one-file-system -- "$work" || status=1
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p -- "$volume" "$snapshot"/{gpt,config,hardware,storage}

(
    cd -- "$boot_dir"
    # GRUB changes grubenv during one-shot boots. Comparing it would fail on a healthy FIT.
    find . -type f ! -path './grub/grubenv' -print0 |
        LC_ALL=C sort -z | xargs -0 -r sha256sum --
) > "$snapshot/boot.sha256"
[[ -s "$snapshot/boot.sha256" ]] || die 'No boot files were hashed.'

if [[ "$mode" != --stdout ]]; then
    mount -t ext4 -o rw,noatime,nosuid,nodev,noexec "$recovery_device" "$volume"
    mounted=1
    if [[ "$mode" != --refresh-boot ]]; then
        cmp -s -- "$snapshot/boot.sha256" "$volume/boot.sha256" ||
            die 'Boot checksum mismatch or no baseline. Investigate FIT before using --refresh-boot.'
    fi
fi

copy_config() {
    local path=$1
    [[ -f "$path" && ! -L "$path" ]] || return 0
    # Back up the deployment allowlist only. Refuse common forms of inline secrets.
    if grep -Eiq -e '-----BEGIN .*PRIVATE KEY-----' \
        -e '(^|[[:space:]"{}])([a-z_0-9]*(password|secret|token|api[_-]?key|private[_-]?key)[a-z_0-9]*)"?[[:space:]]*[:=]' \
        -e 'Authorization:[[:space:]]*(Bearer|Basic)' "$path"; then
        die "Inline credentials detected in allowlisted configuration: $path"
    fi
    install -D -m 0600 -- "$path" "$snapshot/config$path"
}

lsblk -e 7 -o NAME,PATH,MODEL,SERIAL,SIZE,FSTYPE,UUID,PARTUUID,MOUNTPOINTS > "$snapshot/hardware/lsblk.txt"
blkid > "$snapshot/hardware/blkid.txt"
ls -l /dev/disk/by-id/ > "$snapshot/hardware/by-id.txt"
mdadm --detail --scan > "$snapshot/storage/mdadm-scan.txt"
xfs_info / > "$snapshot/storage/root-xfs.txt"
efibootmgr -v > "$snapshot/storage/uefi.txt"
tr ' ' '\n' </proc/cmdline |
    grep -E '^(BOOT_IMAGE=|root=|ro$|rw$|quiet$|splash$|intel_iommu=|iommu=|memhp_default_state=|memory_hotplug\.memmap_on_memory=)' \
    > "$snapshot/storage/kernel-cmdline.txt" || true
uname -r > "$snapshot/storage/kernel.txt"
apt-mark showhold > "$snapshot/storage/apt-holds.txt"
dpkg --get-selections > "$snapshot/storage/packages.txt"
grep -E '^linux-(image|modules|main-modules)' "$snapshot/storage/packages.txt" > "$snapshot/storage/kernel-packages.txt" || true

root_source=$(findmnt -rn -M / -t xfs -o SOURCE)
root_disks=$(lsblk -snro TYPE,PATH -- "$root_source" | awk '$1 == "disk" && !seen[$2]++ {print $2}')
mapfile -t disks <<< "$root_disks"
[[ ${#disks[@]} == 2 && -b "${disks[0]}" && -b "${disks[1]}" ]] ||
    die "Expected the two P4618 disks backing $root_source."
special=$(sed -n 's/^Z8_SPECIAL=\(\/dev\/disk\/by-id\/nvme-[^[:space:]]*-part8\)$/\1/p' \
    /etc/z8-storage/storage.env 2>/dev/null || true)
if [[ -n "$special" ]]; then
    optane=$(lsblk -dnro PKNAME -- "$special")
    [[ -n "$optane" && -b "/dev/$optane" ]] || die 'Invalid Optane device in storage.env.'
    disks+=("/dev/$optane")
fi
for disk in "${disks[@]}"; do
    sgdisk --backup="$snapshot/gpt/${disk##*/}.sgdisk" "$disk" >&2
done

shopt -s nullglob
for path in /etc/fstab /etc/mdadm/mdadm.conf /etc/default/grub \
    /etc/default/grub.d/*z8*.cfg /etc/dracut.conf.d/*z8*.conf /etc/grub.d/{40_custom,42_z8_recovery} \
    /etc/apt/preferences.d/z8-no-hwe /etc/apt/preferences.d/z8-nvidia-580 \
    /etc/apt/apt.conf.d/51z8-kernel-manual /etc/udev/rules.d/*z8*.rules /etc/default/irqbalance \
    /etc/sysctl.d/90-z8-tiering.conf /etc/modprobe.d/*zfs*.conf /etc/z8-infer-cpu.env \
    /etc/z8-storage/{hybrid.tsv,storage.env,pmem-model.env,pmem-kmem.env,recovery-notes.txt,model-manifest.txt} \
    /etc/systemd/system/{z8-*.service,z8-*.timer,z8*.slice,data-buildbarn.mount,data-other.mount,srv-bbindex.mount} \
    /etc/systemd/system/{z8-*.service,z8*.slice,data-buildbarn.mount,data-other.mount,srv-bbindex.mount}.d/*.conf \
    /opt/z8-kit/buildbarn/{*.jsonnet,disk.libsonnet,compose*.yaml,Dockerfile.scheduler,scheduler-command-platform.patch,buck2-shared-worker.buckconfig} \
    /srv/bbindex/cold-layout.json /home/jackywang/.config/z8-infer/launch.sh
do
    copy_config "$path"
done

# Never source or copy the full per-user environment. Keep only deployment settings.
infer=/home/jackywang/.config/z8-infer/env.sh
if [[ -f "$infer" && ! -L "$infer" ]]; then
    mkdir -p "$snapshot/config/home/jackywang/.config/z8-infer"
    while IFS= read -r line; do
        if [[ "$line" =~ ^export[[:blank:]]+(LLAMA_BUILD|DS41_GGUF|CUDA_VISIBLE_DEVICES|Z8_DRAM_INTERLEAVE|Z8_CUDA_RUNTIME|Z8_NVLINK_P2P|SLOTS|SLOT_CTX|MOE_CACHE_MIB|CACHE_PROMPT)=([[:alnum:]./,:_+-]+)[[:blank:]]*$ ]]; then
            printf 'export %s=%q\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        fi
    done < "$infer" > "$snapshot/config$infer"
fi

if command -v zpool >/dev/null && zpool list -H -o name z8data >/dev/null 2>&1; then
    zpool get all z8data > "$snapshot/storage/zpool.txt"
    zpool get -H -o value guid z8data > "$snapshot/storage/zpool-guid.txt"
    zfs get -r all z8data > "$snapshot/storage/zfs.txt"
    dmsetup table --target zoned > "$snapshot/storage/dmzoned.txt"
fi
if command -v ndctl >/dev/null; then ndctl list -NRD > "$snapshot/hardware/namespaces.json"; fi
if command -v ipmctl >/dev/null; then
    ipmctl show -region > "$snapshot/hardware/pmem-regions.txt"
    ipmctl show -dimm > "$snapshot/hardware/pmem-dimms.txt"
fi
if command -v nvidia-smi >/dev/null; then
    nvidia-smi --query-gpu=uuid,pci.bus_id,name,driver_version --format=csv > "$snapshot/hardware/gpu.csv"
fi
if [[ -x /usr/local/sbin/z8-inventory ]]; then
    /usr/local/sbin/z8-inventory | sed '/^\[kernel-cmdline\]$/,+1d' > "$snapshot/hardware/inventory.txt"
fi

(
    cd -- "$snapshot"
    find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum --
) > "$snapshot/SHA256SUMS"
if [[ "$mode" == --stdout ]]; then
    tar -C "$snapshot" -cf - .
    exit 0
fi

name=$(date -u +%Y%m%dT%H%M%S.%NZ)
stage=$(mktemp -d "$volume/.staging.XXXXXX")
cp -a -- "$snapshot/." "$stage/"
(cd -- "$stage"; sha256sum --check --strict --quiet SHA256SUMS)
mv -T -- "$stage" "$volume/$name"
stage=
if [[ "$mode" == --refresh-boot ]]; then
    new_baseline=$(mktemp "$volume/.boot-sha256.XXXXXX")
    cp -- "$snapshot/boot.sha256" "$new_baseline"
    mv -Tf -- "$new_baseline" "$volume/boot.sha256"
fi
pending_link="$volume/.latest.$name"
ln -s -- "$name" "$pending_link"
mv -Tf -- "$pending_link" "$volume/latest"
pending_link=
sync -f "$volume"

# UTC names sort chronologically. Leave unrelated files and directories alone.
backups=()
for path in "$volume"/*; do
    [[ -d "$path" && ! -L "$path" && ${path##*/} =~ ^[0-9]{8}T[0-9]{6}\.[0-9]{9}Z$ ]] || continue
    backups+=("$path")
done
for ((i = 0; i < ${#backups[@]} - 12; i++)); do
    rm -rf --one-file-system -- "${backups[i]}"
done
sync -f "$volume"
umount "$volume"
mounted=0
printf 'Verified recovery metadata backup: %s\n' "$name"
