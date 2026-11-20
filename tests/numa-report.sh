#!/usr/bin/env bash
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -r -- "$tmp"' EXIT
mkdir -p "$tmp"/{bin,proc/pressure,sys/devices/system/node/node{0..3}}
# Only the disposable copy of the script knows the fixture paths.
sed -e "s@/proc/@$tmp/proc/@g" -e "s@/sys/@$tmp/sys/@g" z8-kit/host/pmem-numa-report.sh > "$tmp/report.sh"

# Two DDR4 nodes, node 0 near its low watermark, and two CPU-less PMem nodes that only have movable memory.
zone() {  # node, zone, free, min, low, high, promo, managed
    cat <<EOF
Node $1, zone $(printf '%8s' "$2")
  pages free     $3
        boost    0
        min      $4
        low      $5
        high     $6
        promo    $7
        spanned  $8
        present  $8
        managed  $8
        cma      0
        protection: (0, 0, 0, 0, 0)
      nr_free_pages $3
      numa_miss    7
  pagesets
    cpu: 0
              count: 0
              high:  1234
              batch: 63
              high_min: 1234
  start_pfn:           4096
EOF
}
{
    zone 0 DMA32 400000 1100 1400 1700 2000 440000
    zone 0 Normal 61000 45000 60000 75000 90000 24400000
    zone 0 Movable 0 32 32 32 32 0
    zone 1 Normal 15000000 46000 61000 76000 91000 24700000
    zone 2 Normal 0 0 0 0 0 0
    zone 2 Movable 190000000 0 250000 500000 750000 195000000
    zone 3 Movable 191000000 0 250000 500000 750000 195000000
} > "$tmp/proc/zoneinfo"
printf '%s\n' 'nr_free_pages 1' 'allocstall_normal 3' 'allocstall_movable 0' 'kswapd_low_wmark_hit_quickly 5' \
    'kswapd_high_wmark_hit_quickly 6' 'kswapd_inodesteal 9' 'pgdemote_kswapd 40' 'numa_miss 30' > "$tmp/proc/vmstat"
for node in {0..3}; do
    printf '%s\n' 'nr_free_pages 1' "numa_hit 10$node" "numa_miss 2$node" 'numa_interleave 8' "pgpromote_success 3$node" \
        "pgdemote_kswapd 4$node" > "$tmp/sys/devices/system/node/node$node/vmstat"
done

output=$(PATH="$tmp/bin:/usr/bin:/bin" bash "$tmp/report.sh")
# The machine-wide counters keep their old lines and gain the stall and kswapd ones.
for line in 'allocstall_normal 3' 'allocstall_movable 0' 'kswapd_low_wmark_hit_quickly 5' \
            'kswapd_high_wmark_hit_quickly 6' 'pgdemote_kswapd 40' 'numa_miss 30'; do
    grep -qx "$line" <<< "$output"
done
if grep -q 'kswapd_inodesteal\|numa_interleave\|high_min\|^nr_free_pages' <<< "$output"; then exit 1; fi

# One line per populated zone, with the watermarks of that zone and not the per-CPU list limits.
diff <(sed -n '/^\[Zone watermarks/,/^$/p' <<< "$output") - <<'EOF'
[Zone watermarks per node, in pages]
node0 DMA32 free=400000 min=1100 low=1400 high=1700 promo=2000 managed=440000
node0 Normal free=61000 min=45000 low=60000 high=75000 promo=90000 managed=24400000
node1 Normal free=15000000 min=46000 low=61000 high=76000 promo=91000 managed=24700000
node2 Movable free=190000000 min=0 low=250000 high=500000 promo=750000 managed=195000000
node3 Movable free=191000000 min=0 low=250000 high=500000 promo=750000 managed=195000000

EOF
for node in {0..3}; do
    for line in "numa_hit 10$node" "numa_miss 2$node" "pgpromote_success 3$node" "pgdemote_kswapd 4$node"; do
        grep -qx "node$node/vmstat:$line" <<< "$output"
    done
done
[[ $(grep -c '^node[0-9]/vmstat:' <<< "$output") == 16 ]]

# A kernel without NUMA nodes in sysfs still gives the rest of the report.
rm -r "$tmp/sys/devices/system/node"
output=$(PATH="$tmp/bin:/usr/bin:/bin" bash "$tmp/report.sh" 2>/dev/null)
grep -q '^node1 Normal free=15000000 ' <<< "$output"
echo 'NUMA report tests passed.'
