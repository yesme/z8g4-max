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
        local cold = import '../cold-index/cold-layout.json',
        readCaching: {
          // Authoritative CS: D4800X p9 index and state, RAIDZ1 block file.
          slow: disk('/cold-index', '/cold/blocks', cold.tib * 1024 * GiB, cold.indexGib * GiB, 3, chunking, 22, 66),
          fast: disk('/store/cs-hot', '/store/cs-hot/blocks', 512 * GiB, 8 * GiB, 3, chunking),
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
