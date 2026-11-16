#!/usr/bin/env bash
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -r -- "$tmp"' EXIT
export BB_DATA_DIR="$tmp/store" PATH="$tmp/bin:$PATH" Z8_TEST="$tmp"
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
if [[ -e "$Z8_TEST/xfs" ]]; then echo '/ xfs'; else echo '/ ext4'; fi
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
bash "$tmp/check"
rmdir "$BB_DATA_DIR/cold/sata0-0/persistent_state"
reject 'Accepted a missing cold checkpoint directory'
mkdir "$BB_DATA_DIR/cold/sata0-0/persistent_state"
echo 0 > "$BB_DATA_DIR/cs-hot/blocks"
reject 'Accepted a stale hot CS geometry'
echo 1758789107712 > "$BB_DATA_DIR/cs-hot/blocks"
echo 27917287424 > "$BB_DATA_DIR/cs-hot/key_location_map"
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
echo 'Buildbarn startup guard and CMS topology tests passed.'
