#!/usr/bin/env bash
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -r -- "$tmp"' EXIT
export BB_DATA_DIR="$tmp/store" PATH="$tmp/bin:$PATH" Z8_TEST="$tmp"
mkdir -p "$tmp"/{bin,cold} "$BB_DATA_DIR"/{cs,cs-hot,cms,ac}/persistent_state
sed "s|^target=/data/buildbarn$|target=$tmp/cold|" z8-kit/buildbarn/z8-buildbarn-check > "$tmp/check"
cat > "$tmp/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
case "$3:$4" in
    SOURCE:-M) echo z8data/data/buildbarn ;;
    FSTYPE:-M) echo zfs ;;
    FSTYPE:-T) echo xfs ;;
    *) exit 2 ;;
esac
EOF
cat > "$tmp/bin/zfs" <<'EOF'
#!/usr/bin/env bash
cat "$Z8_TEST/available"
EOF
chmod +x "$tmp"/bin/*

cd "$tmp"
printf '%s\n' "$((75 * 1024**4))" > available
touch cold/i4-cas-aging.bin
if bash check; then
    echo 'Initialized cold layout with the I4 test file still present' >&2
    exit 1
fi
rm cold/i4-cas-aging.bin
bash check
grep -Fx '{"tib":54,"indexGib":1404}' cold-layout.json

# On restart the layout is reused, without reading remaining pool space.
rm available
index="$BB_DATA_DIR/cs/key_location_map"
truncate -s "$((1404 * 1024**3))" "$index"
bash check
truncate -s "$((54 * 1024**3))" "$index"
if bash check; then
    echo 'Accepted a mismatched existing cold index' >&2
    exit 1
fi

# A layout from before indexGib was recorded still uses its original index.
printf '%s\n' '{"tib":54}' > cold-layout.json
bash check
touch cold/blocks
if bash check; then
    echo 'Accepted a mismatched existing cold block file' >&2
    exit 1
fi
rm cold-layout.json
if bash check; then
    echo 'Reinitialized the geometry of an existing cold block file' >&2
    exit 1
fi
echo 'Buildbarn cold layout tests passed.'
