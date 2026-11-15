#!/usr/bin/env bash
set -uo pipefail

show() {
    local label=$1
    shift
    printf '\n[%s]\n' "$label"
    if command -v "$1" >/dev/null; then
        "$@" || printf 'Command exited with status %s\n' "$?"
    else
        printf 'Missing command: %s\n' "$1"
    fi
}

network_hardware() {
    local nic driver address link_speed duplex
    printf '\n[PCI network controllers]\n'
    if command -v lspci >/dev/null; then
        lspci -Dnnk | grep -A3 -Ei 'Ethernet controller|Network controller' || true
    fi
    for nic in /sys/class/net/*; do
        [[ -e "$nic/device" ]] || continue
        driver=$(readlink "$nic/device/driver") || driver=unknown
        address=$(<"$nic/address")
        printf 'Interface %s: driver=%s mac=%s\n' "${nic##*/}" "${driver##*/}" "$address"
        if [[ -e "$nic/phy80211" || -d "$nic/wireless" ]]; then continue; fi
        if link_speed=$(cat "$nic/speed" 2>/dev/null) && [[ "$link_speed" =~ ^[1-9][0-9]*$ ]]; then
            duplex=$(cat "$nic/duplex" 2>/dev/null) || duplex=unknown
            printf '  negotiated speed=%s Mb/s duplex=%s\n' "$link_speed" "$duplex"
        else
            printf '  no negotiated link speed\n'
        fi
    done
}

if [[ "${1:-}" == --network ]]; then
    network_hardware
    exit 0
fi

show timestamp date -Is
show kernel uname -a
show kernel-cmdline cat /proc/cmdline
show bios dmidecode -t bios
show memory-slots dmidecode -t memory
show cpu lscpu
# shellcheck disable=SC2016 # $3 is an awk field.
show cpu-microcode awk '/^microcode/ && !seen[$3]++ {print $3}' /proc/cpuinfo
show numa numactl --hardware
show pmem-socket-limit ipmctl show -units GiB -socket
show persistent-memory ipmctl show -dimm
show pmem-firmware ipmctl show -dimm -firmware
show pmem-memory-resources ipmctl show -memoryresources
show namespaces ndctl list -RNu
show pci-tree lspci -Dtv
show pci-links lspci -Dvv
show secure-boot mokutil --sb-state
show gpu nvidia-smi --query-gpu=index,name,uuid,pci.bus_id,driver_version,vbios_version,memory.total,pcie.link.gen.current,pcie.link.width.current --format=csv
show topology nvidia-smi topo -m
show nvlink nvidia-smi nvlink -s
show disks lsblk -e 7 -o NAME,PATH,TYPE,SIZE,MODEL,SERIAL,REV,TRAN,ZONED,LOG-SEC,PHY-SEC,FSTYPE,MOUNTPOINTS
show nvme nvme list
show network nmcli device status
network_hardware
show arrays cat /proc/mdstat
show maps dmsetup ls --target zoned
show zfs zpool status
show zoned-kernel modinfo dm-zoned
show boot efibootmgr -v
printf '\n[Recent kernel errors]\n'
journalctl -k -b --no-pager | grep -Ei 'Xid|AER|NVRM|mce:|EDAC|dm-zoned|nvme.*(reset|timeout)|ata[0-9].*(resetting link|link down|failed command)' | tail -n 100 || true
printf '\n[DMA remapping]\n'
journalctl -k -b --no-pager | grep -Ei 'DMAR|IOMMU|Default domain' || true
