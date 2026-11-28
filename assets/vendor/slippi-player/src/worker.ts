import {parseReplay} from './parser/parser';
import {replayRaw,validateRaw} from './parser/container';
self.onmessage = async ({data}) => {
 try {
  const container = replayRaw(await data.file.arrayBuffer());
  const metadata = validateRaw(container.raw);
  const replay = data.inspectOnly ? undefined : parseReplay(container);
  self.postMessage({metadata,replay});
 } catch(error) {self.postMessage({error:error.message || 'Replay could not be parsed.'});}
};
