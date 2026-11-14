#!/usr/bin/env bash
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -r -- "$tmp"' EXIT
mkdir "$tmp/config" "$tmp/cold-index"
cp z8-kit/buildbarn/*.{jsonnet,libsonnet} "$tmp/config/"
jq '. + {hostname:"fixture-mac", hot:"/hot", cold:"/cold", work:"/work", socket:"/work/runner.sock"}' \
    z8-kit/buildbarn/edge-site.json.example > "$tmp/config/edge-site.json"
printf '%s\n' '{"tib":41,"indexGib":520}' > "$tmp/cold-index/cold-layout.json"

for source in "$tmp"/config/*.jsonnet; do
    jsonnet "$source" > "${source%.jsonnet}.rendered.json"
done
jq -e '
    .contentAddressableStorageServer.contentAddressableStorage.chunkStorage.readCaching.slow.local
    | .blocksOnBlockDevice.source.file == {path:"/cold/blocks", sizeBytes:(41 * 1024 * 1024 * 1024 * 1024)}
      and .keyLocationMap.onBlockDevice.file == {path:"/cold-index/key_location_map", sizeBytes:(520 * 1024 * 1024 * 1024)}
      and .persistent.stateDirectoryPath == "/cold-index/persistent_state"
' "$tmp/config/tiered-cache.rendered.json" >/dev/null

jq '. + {xcode:"26.1", developerDir:"/Applications/Xcode.app/Contents/Developer",
    caseInsensitive:true, coldShards:["/Volumes/Cold1","/Volumes/Cold2","/Volumes/Cold3","/Volumes/Cold4"]}' \
    "$tmp/config/edge-site.json" > "$tmp/edge-darwin.json"
mv "$tmp/edge-darwin.json" "$tmp/config/edge-site.json"
for source in "$tmp"/config/edge-*.jsonnet; do
    jsonnet "$source" >/dev/null
done

# The XFS fallback may be started without the P4800X index or its geometry.
rm "$tmp/cold-index/cold-layout.json"
jsonnet "$tmp/config/fallback-farm.jsonnet" >/dev/null
echo 'Buildbarn Jsonnet tests passed.'
