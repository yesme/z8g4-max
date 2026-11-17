#!/usr/bin/env bash
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -r -- "$tmp"' EXIT
export BB_DATA_DIR="$tmp/store" BB_HOT_INDEX_DIR="$tmp/pmem/bb-hot-index" PATH="$tmp/bin:$PATH" Z8_TEST="$tmp"
mkdir -p "$tmp"/{bin,runtime} "$BB_DATA_DIR"/{cs-hot,cms,ac,cold/sata0-0}/persistent_state
sed -e "s|/usr/local/sbin/z8-cold|$tmp/bin/z8-cold|" \
    -e "s|/run/z8-cold/|$tmp/runtime/|" z8-kit/buildbarn/z8-buildbarn-check > "$tmp/check"
printf '%s\n' '{"active":["sata0-0"]}' > "$tmp/runtime/cold-layout.json"
cat > "$tmp/bin/z8-cold" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == 'check' && -e "$Z8_TEST/valid" ]]
EOF
cat > "$tmp/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
if [[ "${@: -1}" == "$BB_HOT_INDEX_DIR" ]]; then
    cat "$Z8_TEST/index-mount"
elif [[ -e "$Z8_TEST/xfs" ]]; then echo '/ xfs'; else echo '/ ext4'; fi
EOF
cat > "$tmp/bin/xfs_io" <<'EOF'
#!/usr/bin/env bash
[[ "$1 $2" == '-c extsize' ]]
printf '[%s] %s\n' "$(cat "$Z8_TEST/extsize")" "$3"
EOF
cat > "$tmp/bin/stat" <<'EOF'
#!/usr/bin/env bash
cat "${@: -1}"
EOF
cat > "$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
[[ "$1 $2" == 'ps -q' ]]
EOF
chmod +x "$tmp"/bin/*
reject() { if bash "$tmp/check"; then echo "$1" >&2; exit 1; fi; }

reject 'Accepted a non-XFS hot store'
touch "$tmp/xfs"
reject 'Accepted invalid/missing cold devices'
touch "$tmp/valid"
reject 'Accepted a missing hot index directory'
mkdir -p "$BB_HOT_INDEX_DIR"
echo '/data xfs rw' > "$tmp/index-mount"
reject 'Accepted a hot index outside PMem and P4618'
echo '/srv/pmem-model xfs rw,noatime' > "$tmp/index-mount"
reject 'Accepted a PMem index without DAX'
echo '/srv/pmem-model xfs rw,noatime,dax=always' > "$tmp/index-mount"
echo 0 > "$tmp/extsize"
reject 'Accepted a PMem index directory without the extent size hint'
echo 2097152 > "$tmp/extsize"
bash "$tmp/check"
rmdir "$BB_DATA_DIR/cold/sata0-0/persistent_state"
reject 'Accepted a missing cold checkpoint directory'
mkdir "$BB_DATA_DIR/cold/sata0-0/persistent_state"
echo 0 > "$BB_DATA_DIR/cs-hot/blocks"
reject 'Accepted a stale hot CS geometry'
echo 1758789107712 > "$BB_DATA_DIR/cs-hot/blocks"
reject 'Accepted hot CS blocks without their index'
echo 0 > "$BB_HOT_INDEX_DIR/key_location_map"
reject 'Accepted a stale hot index geometry'
echo 27917287424 > "$BB_HOT_INDEX_DIR/key_location_map"
bash "$tmp/check"
echo 27917287424 > "$BB_DATA_DIR/cs-hot/key_location_map"
reject 'Accepted an index left behind on P4618'
rm -- "$BB_DATA_DIR/cs-hot/key_location_map"
# The P4618 fallback needs neither DAX nor the hint.
echo '/ xfs rw,noatime' > "$tmp/index-mount"
echo 0 > "$tmp/extsize"
reject 'Accepted an unmounted PMem directory on the root filesystem'
BB_HOT_INDEX_DIR="$BB_DATA_DIR/cs-hot-index"
mkdir -p "$BB_HOT_INDEX_DIR"
echo 27917287424 > "$BB_HOT_INDEX_DIR/key_location_map"
bash "$tmp/check"
touch "$BB_DATA_DIR/cms/blocks"
bash "$tmp/check" --prepare
[[ ! -e "$BB_DATA_DIR/cms/blocks" && -d "$BB_DATA_DIR/cms/persistent_state" ]]
touch "$BB_DATA_DIR/cms/blocks"
bash "$tmp/check" --prepare
[[ -f "$BB_DATA_DIR/cms/blocks" ]]
mkdir -p "$BB_DATA_DIR/cold/sata1-0/persistent_state"
printf '%s\n' '{"active":["sata0-0","sata1-0"]}' > "$tmp/runtime/cold-layout.json"
bash "$tmp/check" --prepare
[[ ! -e "$BB_DATA_DIR/cms/blocks" && -d "$BB_DATA_DIR/cms/persistent_state" ]]
echo 'Buildbarn startup guard, hot index placement and CMS topology tests passed.'
