local disk = import 'disk.libsonnet';
local base = import 'cache.jsonnet';
local GiB = 1024 * 1024 * 1024;
local MiB = 1024 * 1024;
local chunking = { minChunkSizeBytes: 256 * 1024, horizonSizeBytes: 2 * MiB };

base + {
  schedulers: {
    hardlinking: { endpoint: { address: 'scheduler:8982' } },
  },
  executeAuthorizer: {
    instanceNamePrefix: { allowedInstanceNamePrefixes: ['hardlinking'] },
  },
  contentAddressableStorageServer+: {
    contentAddressableStorage+: {
      chunkStorage: {
        readCaching: {
          // Authoritative CS: P4618 index and state, RAIDZ1 block file.
          slow: disk('/store/cs', '/cold/blocks', 512 * GiB, 512 * MiB, 3, chunking),
          fast: disk('/store/cs-hot', '/store/cs-hot/blocks', 64 * GiB, 128 * MiB, 3, chunking),
          replicator: { 'local': {} },
        },
      },
    },
  },
  actionCache+: {
    getAuthorizer: {
      instanceNamePrefix: { allowedInstanceNamePrefixes: ['linux-x86_64', 'hardlinking'] },
    },
    putAuthorizer: {
      instanceNamePrefix: { allowedInstanceNamePrefixes: ['linux-x86_64', 'hardlinking'] },
    },
  },
}
