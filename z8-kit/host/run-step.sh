#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: bash host/run-step.sh STEP [ARGS...]

  t1-network                   Check Ethernet or transitional Wi-Fi, DNS and APT
  t1-cpu-prepare               Install microcode and CPU diagnostics before reboot
  t1-cpu                       Run the 30-minute general CPU stress test
  t1-avx                       Run the VNNI preflight and 30-minute stress test
  t1-avx-temperature           Stream per-core AVX temperature, frequency and power
  t2-memory                    Show memory, NUMA topology and ECC counters
  t2-temperature               Stream CPU temperature and throttle counts (Ctrl+C to stop)
  t2-ddr4 NODE0,NODE1          Run the four-hour 144 GiB DDR4 stress test
  t2-ddr4 NODE                Run the four-hour 70 GiB single-node diagnostic
  t3-pmem                      Collect PMem inventory and run built-in diagnostics
  t4-inventory                 Capture the complete host baseline
  t4-nvme-read BY_ID BY_ID BY_ID   Read each confirmed whole NVMe device for five minutes
  t4-hdd-status BY_ID...        Print SMART self-test status for seven confirmed drives
  t4-hdd-start BY_ID...         Start background Extended SMART tests on those drives
  t5-cuda-build                Build the CUDA test utilities on the SanDisk system
  t5-gpu-burn GPU-UUID[,GPU-UUID...]   Burn one V100 for 15 min or four for 60 min
  t5-pinned NODE0,NODE1 GPU-UUID,...   Run interleaved DDR4 H-to-D on four V100s
  i1-disks FIT_BY_ID NVME_BY_ID NVME_BY_ID [--imported]   Print the installer matching IDs
  i1-boot                      Collect FIT, md, XFS and Dracut boot evidence
  i2-remote                    Check active networking and local SSH/xrdp listeners
  i3-cuda GPU-UUID,...          Run P2P and all-reduce on the four V100s (also used at T5)
  i4-status                    Collect pool, mappers and boot journal, including failed units
  i5-worker tiered|xfs         Inspect the selected Buildbarn runner and CPU assignment
  i6-probe [PROBE_ARGS...]      Run the inference probe and print GPU/error evidence
  i7-snapshot [PID]            Capture NUMA, memory, CPU and hardware counter evidence

Default logs: ~/z8-burnin/steps. Override the directory with Z8_LOG_DIR.
EOF
}

fail() {
    printf "%s\n" "$*" >&2
    exit 2
}

kernel_events() {
    sudo journalctl -k -b --no-pager -g 'mce|MCE|EDAC|thermal|throttl|Xid|AER' || true
}

ras() {
    local status=0
    sudo ras-mc-ctl --status || true
    sudo ras-mc-ctl --errors || status=$?
    sudo ras-mc-ctl --error-count || printf "ECC counters unavailable; check EDAC and the kernel log.\n"
    return "$status"
}

stress_with_ras() {
    local result=0 interrupted=0
    sudo systemctl enable --now rasdaemon
    printf '\n[RAS before stress]\n'
    ras
    # Keep collecting evidence when the terminal interrupts the load.
    trap 'interrupted=1' INT
    "$@" || result=$?
    trap - INT
    if (( interrupted )); then result=130; fi
    printf '\n[RAS after stress]\n'
    if ! ras && (( result == 0 )); then result=1; fi
    kernel_events
    return "$result"
}

gpu_snapshot() {
    nvidia-smi -q -d ECC,POWER,TEMPERATURE,PAGE_RETIREMENT
    nvidia-smi --query-gpu=uuid,pci.bus_id,pcie.link.gen.current,pcie.link.width.current --format=csv
}

driver_status() {
    uname -r
    modinfo -F version nvidia
    modinfo -F license nvidia
    nvidia-smi -L
    nvidia-smi topo -m
    nvidia-smi nvlink -s || true
}

select_v100s() {
    local requested=$1 count=$2 id
    local -a ids
    local -A seen=()
    [[ "$requested" =~ ^GPU-[0-9a-fA-F-]+(,GPU-[0-9a-fA-F-]+)*$ ]] || fail 'Use comma-separated GPU UUIDs from nvidia-smi -L.'
    IFS=, read -ra ids <<< "$requested"
    [[ ${#ids[@]} == "$count" ]] || fail "Expected $count V100 UUIDs."
    for id in "${ids[@]}"; do
        [[ ! ${seen[$id]+present} ]] || fail "Duplicate GPU: $id"
        seen[$id]=1
        [[ $(nvidia-smi -i "$id" --query-gpu=name --format=csv,noheader) == *V100* ]] || fail "Not a V100: $id"
    done
    export CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES="$requested"
    cd -- "$HOME/z8-burnin/cuda-check"
    export LD_LIBRARY_PATH="$PWD/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
}

smart_snapshot() {
    local status=0
    sudo smartctl -x "$1" || status=$?
    if (( status )); then printf 'smartctl status for %s: %s (bitmask)\n' "$1" "$status" >&2; fi
    return "$status"
}

check_disk_ids() {
    local prefix=$1 disk resolved
    shift
    local -A seen=()
    for disk in "$@"; do
        [[ "$disk" == "/dev/disk/by-id/$prefix"* && -b "$disk" ]] || fail "Missing whole-disk by-id: $disk"
        [[ $(lsblk -dnro TYPE -- "$disk") == disk ]] || fail "Expected a whole disk: $disk"
        resolved=$(readlink -f -- "$disk")
        [[ ! ${seen[$resolved]+present} ]] || fail "Duplicate disk: $disk"
        seen[$resolved]=1
    done
}

run_step() {
    local disk id node nodes="${1:-}" size duration count mode pid runner result=0 missing=0
    local cpu_count node_mib
    local -a selected_nodes
    case "$step" in
        t1-network)
            bash host/inventory.sh --network
            nmcli device status
            ip -br address
            ip route show default
            getent ahostsv4 archive.ubuntu.com
            sudo apt-get -o APT::Update::Error-Mode=any update
            ;;
        t1-cpu-prepare)
            sudo apt-get update
            sudo apt-get install intel-microcode linux-firmware-intel-wireless ethtool stress-ng rasdaemon lm-sensors numactl
            ;;
        t1-cpu)
            lscpu
            awk '/^microcode/ {print $3}' /proc/cpuinfo | sort -u
            numactl --hardware
            cpu_count=$(nproc)
            stress_with_ras stress-ng --cpu "$cpu_count" --cpu-method matrixprod --verify --timeout 30m --metrics-brief
            ;;
        t1-avx)
            sudo modprobe msr
            grep -m1 -w avx512_vnni /proc/cpuinfo
            lscpu -e=CPU,CORE,SOCKET,NODE,ONLINE
            stress-ng --vnni 1 --vnni-intrinsic --vnni-method vpdpbusd512 --verify -t 5s --metrics-brief
            cpu_count=$(nproc)
            stress_with_ras stress-ng --vnni "$cpu_count" --vnni-intrinsic \
                --vnni-method vpdpbusd512 --verify --timeout 30m --metrics-brief
            ;;
        t2-memory)
            free -h
            numactl --hardware
            ras
            ;;
        t1-avx-temperature)
            sudo modprobe msr
            sudo turbostat --quiet --cpu core --interval 5 \
                --show Package,Core,CPU,Busy%,Bzy_MHz,CoreTmp,PkgTmp,CoreThr,PkgWatt,PKG_%
            ;;
        t2-temperature)
            sudo modprobe coretemp
            sudo modprobe msr
            sensors
            sudo turbostat --quiet --cpu package --interval 5 --header_iterations 1 \
                --show Package,CPU,Busy%,Bzy_MHz,PkgTmp,CoreThr
            ;;
        t2-ddr4)
            [[ $# == 1 && "$nodes" =~ ^[0-9]+(,[0-9]+)?$ ]] || fail 'Pass the actual DDR4 node or two comma-separated DDR4 nodes.'
            IFS=, read -ra selected_nodes <<< "$nodes"
            node_mib=71680
            if [[ ${#selected_nodes[@]} == 2 ]]; then
                [[ ${selected_nodes[0]} != "${selected_nodes[1]}" ]] || fail "Select two distinct DDR4 nodes."
                node_mib=73728
            fi
            free -h
            numactl --hardware
            for node in "${selected_nodes[@]}"; do
                [[ -s "/sys/devices/system/node/node$node/cpulist" ]] || fail "Missing CPU node: $node"
                [[ -n $(<"/sys/devices/system/node/node$node/cpulist") ]] || fail "Node $node has no CPU."
                awk -v minimum="$((node_mib * 1024))" '$3 == "MemFree:" { ok = ($4 > minimum) } END { exit !ok }' \
                    "/sys/devices/system/node/node$node/meminfo" || fail "Node $node needs more than $node_mib MiB free."
            done
            if [[ ${#selected_nodes[@]} == 2 ]]; then
                stress_with_ras numactl --interleave="$nodes" stressapptest -s 14400 -M 147456 -m 24 -W
            else
                stress_with_ras numactl --cpunodebind="$nodes" --membind="$nodes" \
                    stressapptest -s 14400 -M 71680 -m 12 -W
            fi
            ;;
        t3-pmem)
            sudo ipmctl show -units GiB -socket
            for id in topology dimm firmware memoryresources region sensor; do sudo ipmctl show "-$id"; done
            sudo ipmctl show -error Thermal -dimm
            sudo ipmctl show -error Media -dimm
            sudo ipmctl start -diagnostic
            ;;
        t4-inventory)
            sudo bash host/inventory.sh
            sudo ras-mc-ctl --errors
            ;;
        t4-nvme-read)
            [[ $# == 3 ]] || fail 'Supply both P4618 namespaces and the D4800X by-id.'
            check_disk_ids nvme- "$@"
            for disk in "$@"; do
                smart_snapshot "$disk" || result=1
                sudo fio --readonly --name=nvme-read --filename="$disk" --rw=read --bs=1M \
                    --ioengine=libaio --direct=1 --iodepth=16 --time_based --runtime=300 --group_reporting || result=1
                smart_snapshot "$disk" || result=1
            done
            return "$result"
            ;;
        t4-hdd-status|t4-hdd-start)
            [[ $# == 7 ]] || fail 'Supply seven confirmed SATA by-ids in SATA0–6 order.'
            check_disk_ids ata- "$@"
            for disk in "$@"; do
                size=$(lsblk -b -d -n -r -o SIZE,ZONED -- "$disk")
                [[ "$size" =~ ^14[0-9]{12}\ host-managed$ ]] || fail "Expected a 14 TB host-managed drive: $disk ($size)"
            done
            lsblk -d -o NAME,MODEL,SERIAL,SIZE,ZONED "$@"
            if [[ "$step" == t4-hdd-start ]]; then
                for disk in "$@"; do sudo smartctl -t long "$disk" || result=1; done
            else
                for disk in "$@"; do smart_snapshot "$disk" || result=1; done
            fi
            return "$result"
            ;;
        t5-cuda-build) bash host/build-cuda-checks.sh ;;
        t5-gpu-burn)
            [[ $# == 1 ]] || fail 'Supply one or four V100 UUIDs.'
            count=1; duration=900
            if [[ "$1" == *,* ]]; then count=4; duration=3600; fi
            select_v100s "$1" "$count"
            gpu_snapshot
            ./gpu_burn -m 80% -tc "$duration" || result=$?
            gpu_snapshot
            kernel_events
            return "$result"
            ;;
        t5-pinned)
            [[ $# == 2 && "$nodes" =~ ^[0-9]+,[0-9]+$ && ${nodes%,*} != "${nodes#*,}" ]] || fail 'Supply two distinct DDR4 nodes and four V100 UUIDs.'
            numactl --hardware
            select_v100s "$2" 4
            numactl --interleave="$nodes" ./pinned-copy 512 300 h2d
            kernel_events
            ;;
        i1-disks)
            [[ $# == 3 || ( $# == 4 && $4 == --imported ) ]] ||
                fail 'Supply the FIT and two P4618 whole-disk by-ids, optionally followed by --imported.'
            check_disk_ids usb- "$1"
            check_disk_ids nvme- "$2" "$3"
            lsblk -d -o NAME,PATH,MODEL,SERIAL,SIZE,TRAN "$1" "$2" "$3"
            for disk in "$1" "$2" "$3"; do
                udevadm info --query=property --name="$disk" | grep '^ID_SERIAL='
            done
            if [[ $# == 4 ]]; then
                sudo cmp -s "$HOME/autoinstall.yaml" /autoinstall.yaml || fail "Imported YAML does not match."
                printf "Imported YAML matches\n"
                sudo awk '/^  storage:/{show=1; print; next}
                    show && /^  [^[:space:]#]/{exit} show' /autoinstall.yaml
            fi
            ;;
        i1-boot)
            [[ -d /sys/firmware/efi ]] || fail "UEFI firmware path unavailable."
            LC_ALL=C mokutil --sb-state
            sudo efibootmgr -v
            findmnt -M / -t xfs
            findmnt -M /boot -t ext4
            findmnt -M /boot/efi -t vfat
            lsblk -o NAME,PATH,MODEL,SERIAL,SIZE,FSTYPE,MOUNTPOINTS
            sudo mdadm --detail "$(findmnt -n -M / -o SOURCE)"
            sudo xfs_info /
            sudo lsinitrd -m "/boot/initrd.img-$(uname -r)"
            ;;
        i2-remote)
            hostnamectl --static
            nmcli device status
            ip -br address
            sudo sshd -t
            systemctl status ssh.socket xrdp.service --no-pager || result=$?
            sudo ss -ltnp '( sport = :22 or sport = :3389 )'
            return "$result"
            ;;
        i3-cuda)
            [[ $# == 1 ]] || fail 'Supply four V100 UUIDs.'
            driver_status
            select_v100s "$1" 4
            nvidia-smi topo -p2p n
            ldd ./p2pBandwidthLatencyTest ./all_reduce_perf
            ./p2pBandwidthLatencyTest
            NCCL_DEBUG=INFO ./all_reduce_perf -b 8 -e 256M -f 2 -g 4 -c 1
            IFS=, read -ra v100s <<< "$CUDA_VISIBLE_DEVICES"
            for ((i = 0; i < 4; i++)); do
                for ((j = i + 1; j < 4; j++)); do
                    pair="${v100s[i]},${v100s[j]}"
                    printf '\n[NCCL pair: %s]\n' "$pair"
                    CUDA_VISIBLE_DEVICES="$pair" NCCL_DEBUG=INFO ./all_reduce_perf -b 1M -e 16M -f 2 -g 2 -c 1
                done
            done
            kernel_events
            ;;
        i4-status)
            sudo journalctl -b -o short-monotonic --no-pager -u z8-dmzoned -u z8-zpool \
                -u data-buildbarn.mount -u data-other.mount -u srv-bbindex.mount
            sudo dmsetup status --target zoned || missing=1
            sudo zpool status -P z8data || missing=1
            for disk in /data/buildbarn /data/other /srv/bbindex /srv/pmem-model; do
                findmnt -M "$disk" -o SOURCE,TARGET,FSTYPE,OPTIONS || missing=1
            done
            return "$missing"
            ;;
        i5-worker)
            cd /opt/z8-kit/buildbarn
            mode="${1:-}"
            local -a compose
            case "$mode" in
                tiered) compose=(docker compose -p z8-tiered -f compose.tiered.yaml) ;;
                xfs) compose=(env BB_DATA_DIR=/srv/buildbarn/cache-xfs docker compose -p z8-xfs \
                    -f compose.yaml -f compose.fallback-farm.yaml) ;;
                *) fail 'Select tiered or xfs.' ;;
            esac
            compose+=(-f compose.worker.yaml -f compose.cpu-layout.yaml)
            sudo "${compose[@]}" ps
            runner=$(sudo "${compose[@]}" ps -q runner)
            [[ -n "$runner" ]] || fail "No active runner for $mode."
            sudo docker inspect --format '{{.HostConfig.CgroupParent}} {{.HostConfig.NanoCpus}}' "$runner"
            pid=$(sudo docker inspect --format '{{.State.Pid}}' "$runner")
            [[ "$pid" =~ ^[1-9][0-9]*$ ]] || fail "Runner is stopped."
            sudo cat "/proc/$pid/cgroup"
            sudo grep '^Cpus_allowed_list:' "/proc/$pid/status"
            ;;
        i6-probe)
            # Do not trace the caller’s arguments. The probe accepts endpoint overrides.
            set +x
            python3 inference/probe.py "$@" || result=$?
            set -x
            nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv
            kernel_events
            return "$result"
            ;;
        i7-snapshot)
            systemctl show z8infer.slice z8build.slice z8build-local.slice user.slice \
                -p Id -p AllowedCPUs -p EffectiveCPUs -p CPUWeight
            sudo bash host/pmem-numa-report.sh "$@"
            sudo journalctl -k -b -p err --no-pager
            ;;
    esac
}

step="${1:---help}"
case "$step" in
    --help|-h) usage; exit 0 ;;
    t1-network|t1-cpu-prepare|t1-cpu|t1-avx|t1-avx-temperature|t2-memory|t2-temperature|t2-ddr4|t3-pmem|\
    t4-inventory|t4-nvme-read|t4-hdd-status|t4-hdd-start|t5-cuda-build|t5-gpu-burn|t5-pinned|\
    i1-disks|i1-boot|i2-remote|i3-cuda|i4-status|i5-worker|i6-probe|i7-snapshot) ;;
    *) usage >&2; fail "Unknown step: $step" ;;
esac
shift
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
log_dir="${Z8_LOG_DIR:-$HOME/z8-burnin/steps}"
mkdir -p -- "$log_dir"
log=$(mktemp -- "$log_dir/$step-$(date +%Y%m%d-%H%M%S)-XXXXXX.log")
printf "Log: %s\n" "$log"
# The logger and parent survive Ctrl+C. The child restores normal signal handling.
trap ':' INT
set +e
(
    trap - INT
    set -e
    printf "Started %s at %s on %s (kernel %s)\n" "$step" "$(date -Is)" "$(hostname)" "$(uname -r)"
    if [[ "$step" != i6-probe ]]; then set -x; fi
    run_step "$@"
) 2>&1 | tee -i "$log"
statuses=("${PIPESTATUS[@]}")
set -e
printf "Finished %s: exit %s, logger exit %s\nLog: %s\n" "$step" "${statuses[0]}" "${statuses[1]}" "$log" | tee -ia "$log"
(( statuses[1] == 0 )) || exit "${statuses[1]}"
exit "${statuses[0]}"
