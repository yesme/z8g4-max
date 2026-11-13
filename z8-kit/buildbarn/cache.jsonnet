local GiB = 1024 * 1024 * 1024;
local MiB = 1024 * 1024;
local allow = { allow: {} };

local disk(root, bytes, indexBytes, newBlocks) = {
  'local': {
    keyLocationMap: {
      onBlockDevice: {
        file: { path: root + '/key_location_map', sizeBytes: indexBytes },
      },
      maximumGetAttempts: 16,
      maximumPutAttempts: 64,
    },
    oldBlocks: 8,
    currentBlocks: 24,
    newBlocks: newBlocks,
    blocksOnBlockDevice: {
      source: { file: { path: root + '/blocks', sizeBytes: bytes } },
      spareBlocks: 3,
    },
    persistent: {
      stateDirectoryPath: root + '/persistent_state',
      minimumEpochInterval: '300s',
    },
  },
};

{
  grpcServers: [{ listenAddresses: [':8980'], authenticationPolicy: allow }],
  maximumMessageSizeBytes: 16 * MiB,
  contentAddressableStorageServer: {
    contentAddressableStorage: {
      chunkStorage: disk('/store/cs', 64 * GiB, 128 * MiB, 3) + {
        'local'+: {
          chunkingParameters: {
            minChunkSizeBytes: 256 * 1024,
            horizonSizeBytes: 2 * MiB,
          },
        },
      },
      chunkMappingStorage: {
        chunkMappingValidating: { backend: disk('/store/cms', 4 * GiB, 32 * MiB, 1) },
      },
    },
    getAuthorizer: allow,
    putAuthorizer: allow,
    findMissingAuthorizer: allow,
    maximumChunkCount: 100000,
  },
  actionCache: {
    backend: {
      completenessChecking: {
        backend: disk('/store/ac', 2 * GiB, 32 * MiB, 1),
        maximumTotalTreeSizeBytes: 16 * MiB,
      },
    },
    getAuthorizer: {
      instanceNamePrefix: { allowedInstanceNamePrefixes: ['linux-x86_64', 'macos-arm64', 'macos-x86_64'] },
    },
    putAuthorizer: {
      instanceNamePrefix: { allowedInstanceNamePrefixes: ['linux-x86_64', 'macos-arm64', 'macos-x86_64'] },
    },
  },
}
