import mediaInfoFactory from '../vendor/mediainfo/index.mjs';
import {inspectionTracks} from './media_metadata.mjs';
self.onmessage = async ({data: {file}}) => {
  let media, read = 0;
  const start = performance.now();
  try {
    media = await mediaInfoFactory({format: 'object', locateFile: () => '/assets/mediainfo/MediaInfoModule.wasm'});
    const result = await media.analyzeData(file.size, async (length, offset) => {
      read += length;
      if (read > 16 * 1024 * 1024 || performance.now() - start > 10000) throw Error('inspection_limit');
      return new Uint8Array(await file.slice(offset, offset + length).arrayBuffer());
    });
    self.postMessage({tracks: inspectionTracks(result)});
  } catch { self.postMessage({error: 'inspection_failed'}); }
  finally { media?.close(); }
};
