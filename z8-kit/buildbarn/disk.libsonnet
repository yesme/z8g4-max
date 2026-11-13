function(metadata, blocks, bytes, indexBytes, newBlocks, chunking=null)
  local MiB = 1024 * 1024;
  {
    'local': {
      keyLocationMap: {
        onBlockDevice: {
          file: { path: metadata + '/key_location_map', sizeBytes: indexBytes },
        },
        maximumGetAttempts: 16,
        maximumPutAttempts: 64,
      },
      oldBlocks: 8,
      currentBlocks: 24,
      newBlocks: newBlocks,
      blocksOnBlockDevice: {
        source: { file: { path: blocks, sizeBytes: bytes } },
        spareBlocks: 3,
      },
      persistent: {
        stateDirectoryPath: metadata + '/persistent_state',
        minimumEpochInterval: '300s',
      },
      [if chunking == null then null else 'chunkingParameters']: chunking,
    },
  }
