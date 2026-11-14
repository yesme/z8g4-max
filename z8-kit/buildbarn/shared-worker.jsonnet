local storage = { grpc: { client: { address: 'cache:8980' } } };
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
      maximumCacheFileCount: 10000,
      maximumCacheSizeBytes: 16 * 1024 * 1024 * 1024,
      cacheReplacementPolicy: 'LEAST_RECENTLY_USED',
    },
    runners: [{
      endpoint: { address: 'unix:///run/bb-runner/runner.sock' },
      concurrency: 4,
      instanceNamePrefix: 'hardlinking',
      platform: {
        properties: [
          { name: 'OSFamily', value: 'linux' },
          { name: 'container-image', value: 'docker://ghcr.io/catthehacker/ubuntu:act-22.04@sha256:' + digest },
        ],
      },
      workerId: { hostname: 'jackywang-xubuntu-max' },
    }],
  }],
  inputDownloadConcurrency: 8,
  outputUploadConcurrency: 8,
  directoryCache: {
    maximumCount: 1000,
    maximumSizeBytes: 1000 * 1024,
    cacheReplacementPolicy: 'LEAST_RECENTLY_USED',
  },
}
