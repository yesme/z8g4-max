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

show timestamp date -Is
show kernel uname -a
show kernel-cmdline cat /proc/cmdline
show bios dmidecode -t bios
show memory-slots dmidecode -t memory
show cpu lscpu
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
show arrays cat /proc/mdstat
show maps dmsetup ls --target zoned
show zfs zpool status
show zoned-kernel modinfo dm-zoned
show boot efibootmgr -v
printf '\n[Recent kernel errors]\n'
journalctl -k -b --no-pager | grep -Ei 'Xid|AER|NVRM|mce:|EDAC|dm-zoned|nvme.*(reset|timeout)' | tail -n 100 || true
printf '\n[DMA remapping]\n'
journalctl -k -b --no-pager | grep -Ei 'DMAR|IOMMU|Default domain' || true
