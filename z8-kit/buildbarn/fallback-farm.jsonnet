local base = import 'cache.jsonnet';
local farm = import 'tiered-cache.jsonnet';

base + {
  grpcServers: farm.grpcServers,
  schedulers: farm.schedulers,
  executeAuthorizer: farm.executeAuthorizer,
  actionCache+: {
    getAuthorizer: farm.actionCache.getAuthorizer,
    putAuthorizer: farm.actionCache.putAuthorizer,
  },
}
