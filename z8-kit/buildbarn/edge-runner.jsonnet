local base = import 'shared-runner.jsonnet';
local edge = import 'edge-site.json';
local darwin = std.objectHas(edge, 'xcode');

base + {
  buildDirectoryPath: if darwin then edge.work + '/build' else '/worker/build',
  setTmpdirEnvironmentVariable: true,
  grpcServers: [{
    listenPaths: [if darwin then edge.socket else '/worker/r.sock'],
    authenticationPolicy: { allow: {} },
  }],
} + (if darwin then {
  appleXcodeDeveloperDirectories: { [edge.xcode]: edge.developerDir },
} else {})
