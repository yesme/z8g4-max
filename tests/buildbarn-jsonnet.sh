#!/usr/bin/env bash
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -r -- "$tmp"' EXIT
mkdir "$tmp/config"
cp z8-kit/buildbarn/*.{jsonnet,libsonnet} "$tmp/config/"
jq '. + {hostname:"fixture-mac", hot:"/hot", cold:"/cold", work:"/work", socket:"/work/runner.sock"}' \
    z8-kit/buildbarn/edge-site.json.example > "$tmp/config/edge-site.json"
jq -n '{shardCount:32,dataBytes:1747514818560,indexBytes:28454158336,
    active:[range(4) as $disk | range(8) as $shard | "sata\($disk)-\($shard)"]}' > "$tmp/cold-layout.json"

for source in "$tmp"/config/*.jsonnet; do
    jsonnet "$source" > "${source%.jsonnet}.rendered.json"
done
assert_index_size() {
    local config=$1 path=$2 gib=$3
    jq -e --argjson path "$path" --argjson gib "$gib" '
        .contentAddressableStorageServer.contentAddressableStorage.chunkStorage
        | getpath($path).keyLocationMap.onBlockDevice.file.sizeBytes == ($gib * 1024 * 1024 * 1024)
    ' "$config" >/dev/null
}
assert_index_size "$tmp/config/tiered-cache.rendered.json" '["readCaching","fast","local"]' 26
assert_index_size "$tmp/config/edge-cache.rendered.json" '["readCaching","fast","local"]' 4
jq -e '.buildDirectories[0] | (.native | has("caseInsensitive") | not)
    and (.runners[0].environmentVariables.PATH | contains("/usr/bin"))' \
    "$tmp/config/edge-worker.rendered.json" >/dev/null

jq -e '
    .contentAddressableStorageServer.contentAddressableStorage.chunkStorage.readCaching
    | .fast.local.blocksOnBlockDevice.source.file.sizeBytes == (1638 * 1024*1024*1024)
      and (.slow.sharding.shards | length == 32 and all(to_entries[];
         .key as $name |
        (.value.weight == 1 and (.value.backend.local |
          .blocksOnBlockDevice.source == {devicePath:("/dev/z8-cold-" + $name)}
          and .keyLocationMap.onBlockDevice == {devicePath:("/dev/z8-index-" + $name)}
          and .persistent.stateDirectoryPath == ("/store/cold/" + $name + "/persistent_state")
          and .oldBlocks == 22 and .currentBlocks == 65 and .newBlocks == 3
          and .blocksOnBlockDevice.spareBlocks == 3))))
' "$tmp/config/tiered-cache.rendered.json" >/dev/null
# Same-host services use the cache socket; clients and edge tunnels keep TCP.
socket=/run/bb-cache/cache.sock
for config in tiered-cache fallback-farm; do
    jq -e --arg socket "$socket" '.grpcServers == [{authenticationPolicy:{allow:{}},
        listenAddresses:[":8980"], listenPaths:[$socket]}]' "$tmp/config/$config.rendered.json" >/dev/null
done
jq -e '.grpcServers[0] | has("listenPaths") | not' "$tmp/config/cache.rendered.json" >/dev/null
jq -e --arg address "unix://$socket" '[.. | objects | select(has("grpc")) | .grpc.client.address] | length == 3 and all(. == $address)' \
    "$tmp/config/shared-worker.rendered.json" >/dev/null
jq -e --arg address "unix://$socket" '[.. | objects | select(has("grpc")) | .grpc.client.address] | length == 2 and all(. == $address)' \
    "$tmp/config/shared-scheduler.rendered.json" >/dev/null
jq -e '[.. | objects | select(has("grpc")) | .grpc.client.address] | all(. == "127.0.0.1:8980")' \
    "$tmp/config/edge-worker.rendered.json" >/dev/null
jq '.active |= map(select(startswith("sata1-") | not))' "$tmp/cold-layout.json" > "$tmp/degraded.json"
mv "$tmp/degraded.json" "$tmp/cold-layout.json"
jsonnet "$tmp/config/tiered-cache.jsonnet" | jq -e '
    .contentAddressableStorageServer.contentAddressableStorage.chunkStorage.readCaching.slow.sharding.shards
    | length == 24 and all(keys[]; startswith("sata1-") | not)
' >/dev/null

jq '. + {xcode:"26.1", developerDir:"/Applications/Xcode.app/Contents/Developer",
    coldShards:["/Volumes/Cold1","/Volumes/Cold2","/Volumes/Cold3","/Volumes/Cold4"]}' \
    "$tmp/config/edge-site.json" > "$tmp/edge-darwin.json"
mv "$tmp/edge-darwin.json" "$tmp/config/edge-site.json"
for source in "$tmp"/config/edge-*.jsonnet; do
    jsonnet "$source" > "${source%.jsonnet}.rendered.json"
done
assert_index_size "$tmp/config/edge-cache.rendered.json" '["readCaching","fast","local"]' 4
jq -e '.buildDirectories[0] | (.native | has("caseInsensitive") | not)
    and (.runners[0].environmentVariables.PATH | contains("/opt/homebrew/bin"))' \
    "$tmp/config/edge-worker.rendered.json" >/dev/null

# The XFS fallback may be started without the D4800X index or its geometry.
rm "$tmp/cold-layout.json"
jsonnet "$tmp/config/fallback-farm.jsonnet" > "$tmp/config/fallback-farm.rendered.json"
assert_index_size "$tmp/config/fallback-farm.rendered.json" '["local"]' 1
echo 'Buildbarn Jsonnet tests passed.'
