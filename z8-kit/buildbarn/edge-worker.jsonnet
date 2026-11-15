local base = import 'shared-worker.jsonnet';
local edge = import 'edge-site.json';
local storage = { grpc: { client: { address: '127.0.0.1:8980' } } };
local directories = base.buildDirectories[0];
local runner = directories.runners[0];
local darwin = std.objectHas(edge, 'xcode');
local workerRoot = if darwin then edge.work else '/worker';

base + {
  blobstore+: {
    actionCache: storage,
    contentAddressableStorage+: {
      chunkStorage: storage,
      chunkMappingStorage: { chunkMappingValidating: { backend: storage } },
    },
  },
  scheduler: { address: '127.0.0.1:18983' },
  buildDirectories: [
    directories + {
      native+: {
        buildDirectoryPath: workerRoot + '/build',
        cacheDirectoryPath: workerRoot + '/cache',
        maximumCacheSizeBytes: (if darwin then 16 else 64) * 1024 * 1024 * 1024,
      },
      runners: [
        runner + {
          endpoint: { address: 'unix://' + (if darwin then edge.socket else '/worker/r.sock') },
          concurrency: if darwin then 4 else 16,
          workerId: { hostname: edge.hostname },
          environmentVariables: if darwin then {
            PATH: '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin',
          } else runner.environmentVariables,
          platform: if darwin then {
            properties: [
              { name: 'OSFamily', value: 'macos' },
              { name: 'arch', value: 'arm64' },
              { name: 'xcode', value: edge.xcode },
            ],
          } else runner.platform,
        },
      ],
    },
  ],
}
