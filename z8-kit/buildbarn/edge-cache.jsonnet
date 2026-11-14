local base = import 'cache.jsonnet';
local disk = import 'disk.libsonnet';
local edge = import 'edge-site.json';
local MiB = 1024 * 1024;
local GiB = 1024 * MiB;
local upstream = { grpc: { client: { address: '127.0.0.1:18980' } } };
local readCache(slow, fast) = { readCaching: { slow: slow, fast: fast, replicator: { 'local': {} } } };
local darwin = std.objectHas(edge, 'xcode');
local coldDisk(path, metadata, gib) = disk(metadata, path + '/cs/blocks', gib * GiB, gib * MiB, 3);
local cold = if std.objectHas(edge, 'coldShards') then
  assert darwin && std.length(edge.coldShards) == 4 : 'Set four Darwin cold shard mount paths';
  assert std.length(std.set(edge.coldShards)) == 4 : 'Cold shard paths must be distinct';
  { sharding: { shards: {
    ['cmr-' + std.toString(i + 1)]: {
      backend: coldDisk(edge.coldShards[i], edge.hot + '/cs-cmr-' + std.toString(i + 1), 3072),
      weight: 1,
    }
    for i in std.range(0, 3)
  } } }
else coldDisk(edge.cold, edge.hot + '/cs-cold', if darwin then 512 else 640);

base + {
  grpcServers: [{ listenAddresses: ['127.0.0.1:8980'], authenticationPolicy: { allow: {} } }],
  schedulers: {
    hardlinking: {
      endpoint: { address: '127.0.0.1:18980' },
      addInstanceNamePrefix: 'hardlinking',
    },
  },
  executeAuthorizer: { instanceNamePrefix: { allowedInstanceNamePrefixes: ['hardlinking'] } },
  contentAddressableStorageServer+: {
    contentAddressableStorage+: {
      chunkStorage: readCache(
        readCache(upstream, cold),
        disk(edge.hot + '/cs', edge.hot + '/cs/blocks', 256 * GiB, 512 * MiB, 3),
      ),
      chunkMappingStorage: readCache(upstream, disk(edge.hot + '/cms', edge.hot + '/cms/blocks', 4 * GiB, 128 * MiB, 1)),
    },
  },
  actionCache: {
    backend: upstream,
    getAuthorizer: { instanceNamePrefix: { allowedInstanceNamePrefixes: ['hardlinking'] } },
    putAuthorizer: { instanceNamePrefix: { allowedInstanceNamePrefixes: ['hardlinking'] } },
  },
}
