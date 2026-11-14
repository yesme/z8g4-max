local base = import 'cache.jsonnet';
local farm = import 'tiered-cache.jsonnet';

base + {
  schedulers: farm.schedulers,
  executeAuthorizer: farm.executeAuthorizer,
  actionCache+: {
    getAuthorizer: farm.actionCache.getAuthorizer,
    putAuthorizer: farm.actionCache.putAuthorizer,
  },
}
