local disk = import 'disk.libsonnet';
local base = import 'cache.jsonnet';
local GiB = 1024 * 1024 * 1024;
local MiB = 1024 * 1024;
local chunking = { minChunkSizeBytes: 256 * 1024, horizonSizeBytes: 2 * MiB };

base + {
  global: {
    diagnosticsHttpServer: {
      httpServers: [{ listenAddresses: [':9980'], authenticationPolicy: { allow: {} } }],
      enablePrometheus: true,
    },
  },
  schedulers: {
    hardlinking: { endpoint: { address: 'scheduler:8982' }, addInstanceNamePrefix: 'hardlinking' },
  },
  executeAuthorizer: {
    instanceNamePrefix: { allowedInstanceNamePrefixes: ['hardlinking'] },
  },
  contentAddressableStorageServer+: {
    contentAddressableStorage+: {
      chunkStorage: {
        local cold = import '../cold-layout.json',
        readCaching: {
          slow: {
            sharding: {
              shards: {
                [name]: {
                  weight: 1,
                  backend: disk('/store/cold/' + name, '/dev/z8-cold-' + name, 0, 0,
                                3, chunking, 22, 66, '/dev/z8-index-' + name),
                }
                for name in cold.active
              },
            },
          },
          fast: disk('/store/cs-hot', '/store/cs-hot/blocks', 1638 * GiB, 26 * GiB, 3, chunking),
          replicator: { 'local': {} },
        },
      },
      chunkMappingStorage: {
        chunkMappingValidating: { backend: disk('/store/cms', '/store/cms/blocks', 64 * GiB, 4 * GiB, 1) },
      },
    },
  },
  actionCache+: {
    backend: {
      completenessChecking: {
        backend: disk('/store/ac', '/store/ac/blocks', 216 * GiB, 4 * GiB, 1),
        maximumTotalTreeSizeBytes: 16 * MiB,
      },
    },
    getAuthorizer: {
      instanceNamePrefix: { allowedInstanceNamePrefixes: ['linux-x86_64', 'hardlinking'] },
    },
    putAuthorizer: {
      instanceNamePrefix: { allowedInstanceNamePrefixes: ['linux-x86_64', 'hardlinking'] },
    },
  },
}
