// Same-host traffic uses the cache's UNIX socket; TCP 8980 stays for clients and edge tunnels.
local storage = { grpc: { client: { address: 'unix:///run/bb-cache/cache.sock' } } };
local digest = 'dd7654ffb01d5b7b54b23b9ce928a1f7f2d08c7b3d7e320b6574b55d7ccde78b';

{
  global: {},
  blobstore: {
    actionCache: storage,
    contentAddressableStorage: {
      chunkStorage: storage,
      chunkMappingStorage: { chunkMappingValidating: { backend: storage } },
      cdcParameterCache: {
        cacheSize: 1000,
        cacheDuration: '60s',
        cacheReplacementPolicy: 'LEAST_RECENTLY_USED',
      },
    },
  },
  maximumMessageSizeBytes: 16 * 1024 * 1024,
  scheduler: { address: 'scheduler:8983' },
  buildDirectories: [{
    native: {
      buildDirectoryPath: '/worker/build',
      cacheDirectoryPath: '/worker/cache',
      maximumCacheFileCount: 1000000,
      maximumCacheSizeBytes: 128 * 1024 * 1024 * 1024,
      cacheReplacementPolicy: 'LEAST_RECENTLY_USED',
    },
    runners: [{
      endpoint: { address: 'unix:///run/bb-runner/runner.sock' },
      concurrency: 72,
      instanceNamePrefix: 'hardlinking',
      environmentVariables: { PATH: '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' },
      platform: {
        properties: [
          { name: 'OSFamily', value: 'linux' },
          { name: 'container-image', value: 'docker://ghcr.io/catthehacker/ubuntu:act-22.04@sha256:' + digest },
        ],
      },
      workerId: { hostname: 'jackywang-xubuntu-max' },
    }],
  }],
  inputDownloadConcurrency: 32,
  outputUploadConcurrency: 32,
  directoryCache: {
    maximumCount: 100000,
    maximumSizeBytes: 100 * 1024 * 1024,
    cacheReplacementPolicy: 'LEAST_RECENTLY_USED',
  },
}
