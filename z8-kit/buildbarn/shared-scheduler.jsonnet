local allow = { allow: {} };
local storage = { grpc: { client: { address: 'cache:8980' } } };

{
  global: {},
  clientGrpcServers: [{ listenAddresses: [':8982'], authenticationPolicy: allow }],
  workerGrpcServers: [{ listenAddresses: [':8983'], authenticationPolicy: allow }],
  contentAddressableStorage: {
    chunkStorage: storage,
    chunkMappingStorage: { chunkMappingValidating: { backend: storage } },
    cdcParameterCache: {
      cacheSize: 1000,
      cacheDuration: '60s',
      cacheReplacementPolicy: 'LEAST_RECENTLY_USED',
    },
  },
  maximumMessageSizeBytes: 16 * 1024 * 1024,
  executeAuthorizer: allow,
  modifyDrainsAuthorizer: { deny: {} },
  killOperationsAuthorizer: { deny: {} },
  synchronizeAuthorizer: allow,
  actionRouter: {
    simple: {
      platformKeyExtractor: { action: {} },
      invocationKeyExtractors: [
        { correlatedInvocationsId: {} },
        { toolInvocationId: {} },
      ],
      initialSizeClassAnalyzer: {
        defaultExecutionTimeout: '1800s',
        maximumExecutionTimeout: '7200s',
      },
    },
  },
  platformQueueWithNoWorkersTimeout: '60s',
}
