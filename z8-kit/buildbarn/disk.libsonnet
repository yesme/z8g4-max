function(metadata, blocks, bytes, indexBytes, newBlocks, chunking=null, oldBlocks=8, currentBlocks=24, indexDevice=null, indexFile=null)
  {
    'local': {
      keyLocationMap: {
        onBlockDevice: if indexDevice == null then {
          file: {
            path: if indexFile == null then metadata + '/key_location_map' else indexFile,
            sizeBytes: indexBytes,
          },
        } else { devicePath: indexDevice },
        maximumGetAttempts: 16,
        maximumPutAttempts: 64,
      },
      oldBlocks: oldBlocks,
      currentBlocks: currentBlocks,
      newBlocks: newBlocks,
      blocksOnBlockDevice: {
        source: if indexDevice == null then { file: { path: blocks, sizeBytes: bytes } }
        else { devicePath: blocks },
        spareBlocks: 3,
      },
      persistent: {
        stateDirectoryPath: metadata + '/persistent_state',
        minimumEpochInterval: '300s',
      },
      [if chunking == null then null else 'chunkingParameters']: chunking,
    },
  }
