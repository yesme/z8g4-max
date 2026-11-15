{
  global: {},
  buildDirectoryPath: '/worker/build',
  setTmpdirEnvironmentVariable: true,
  grpcServers: [{
    listenPaths: ['/run/bb-runner/runner.sock'],
    authenticationPolicy: { allow: {} },
  }],
}
