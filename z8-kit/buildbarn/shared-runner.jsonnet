{
  global: {},
  buildDirectoryPath: '/worker/build',
  grpcServers: [{
    listenPaths: ['/run/bb-runner/runner.sock'],
    authenticationPolicy: { allow: {} },
  }],
}
