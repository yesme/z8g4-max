#!/usr/bin/env bash
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -r -- "$tmp"' EXIT
export BB_DATA_DIR="$tmp/store" PATH="$tmp/bin:$PATH" Z8_TEST="$tmp"
mkdir -p "$tmp"/{bin,cold,index/persistent_state} "$BB_DATA_DIR"/{cs-hot,cms,ac}/persistent_state
touch "$tmp/p9" "$tmp/wrong-part"
sed -e "s|^target=/data/buildbarn$|target=$tmp/cold|" \
    -e "s|^index_dir=/srv/bbindex$|index_dir=$tmp/index|" \
    -e "s|^index_device=.*|index_device=$tmp/p9|" z8-kit/buildbarn/z8-buildbarn-check > "$tmp/check"
cat > "$tmp/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
case "$3:$4:$5" in
    SOURCE,FSTYPE:-M:"$Z8_TEST/cold") echo 'z8data/buildbarn zfs' ;;
    FSTYPE:-M:"$Z8_TEST/index") test -e "$Z8_TEST/mounted" && echo xfs ;;
    SOURCE:-M:"$Z8_TEST/index") cat "$Z8_TEST/device" ;;
    FSTYPE:-T:"$BB_DATA_DIR") echo xfs ;;
    *) exit 2 ;;
esac
EOF
cat > "$tmp/bin/zfs" <<'EOF'
#!/usr/bin/env bash
set -e
[[ "$*" == 'get -Hp -o value refreservation z8data/buildbarn' ]]
cat "$Z8_TEST/reservation"
EOF
cat > "$tmp/bin/df" <<'EOF'
#!/usr/bin/env bash
set -e
[[ "$*" == "-B1 --output=avail -- $Z8_TEST/index" ]]
echo Avail
cat "$Z8_TEST/free"
EOF
cat > "$tmp/bin/stat" <<'EOF'
#!/usr/bin/env bash
if [[ "${@: -1}" == "$Z8_TEST/cold/blocks" ]]; then
    cat "$Z8_TEST/cold/blocks"
else
    exec /usr/bin/stat "$@"
fi
EOF
chmod +x "$tmp"/bin/*

cd "$tmp"
fail() {
    if bash check; then
        echo "$1" >&2
        exit 1
    fi
}
layout=index/cold-layout.json
index=index/key_location_map
printf '%s\n' "$((41 * 1024**4))" > reservation
printf '%s\n' "$((528 * 1024**3 + 1024**2))" > free
printf '%s\n' "$tmp/p9" > device
fail 'Accepted an unmounted cold index directory'
touch mounted
printf '%s\n' "$tmp/wrong-part" > device
fail 'Accepted another device at the cold index mountpoint'
printf '%s\n' "$tmp/p9" > device
touch cold/i4-cas-aging.bin
fail 'Initialized cold layout with the I4 test file still present'
rm cold/i4-cas-aging.bin
for reserved in none 0 "$((41 * 1024**4 + 1))"; do
    printf '%s\n' "$reserved" > reservation
    fail 'Accepted an invalid ZFS reservation'
done
printf '%s\n' "$((41 * 1024**4))" > reservation
bash check
grep -Fx '{"tib":41,"indexGib":520}' "$layout"

# Reuse the geometry when the index is already allocated and free space has changed.
rm free
truncate -s "$((520 * 1024**3))" "$index"
printf '%s\n' "$((41 * 1024**4))" > cold/blocks
bash check
printf '%s\n' "$((42 * 1024**4))" > reservation
fail 'Accepted a changed reservation'
printf '%s\n' "$((41 * 1024**4))" > reservation
truncate -s "$((519 * 1024**3))" "$index"
fail 'Accepted a mismatched existing cold index'
truncate -s "$((520 * 1024**3))" "$index"
printf '0\n' > cold/blocks
fail 'Accepted a mismatched existing cold block file'
rm "$layout" "$index"
fail 'Reinitialized the geometry of an existing cold block file'
rm cold/blocks
touch "$index"
fail 'Reinitialized the geometry of an existing cold index'
rm "$index"
touch index/persistent_state/checkpoint
fail 'Reinitialized the geometry of existing cold state'
printf '%s\n' '{"tib":41,"indexGib":520}' > "$layout"
fail 'Accepted existing checkpoint without its data files'
echo 'Buildbarn cold layout tests passed.'
