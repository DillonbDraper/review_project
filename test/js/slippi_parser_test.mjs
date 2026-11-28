import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {gunzipSync} from 'node:zlib';
import {Worker} from 'node:worker_threads';
const bundle=new URL('../../assets/vendor/slippi-player/worker.mjs',import.meta.url).href;
async function parse(file,inspectOnly=false) {
 const code=`import {parentPort} from 'node:worker_threads';globalThis.self={postMessage:v=>parentPort.postMessage(v)};await import(${JSON.stringify(bundle)});parentPort.on('message',data=>self.onmessage({data}));`;
 const worker=new Worker(new URL('data:text/javascript,'+encodeURIComponent(code)));
 try {
  return await new Promise((resolve,reject)=>{worker.once('message',resolve);worker.once('error',reject);worker.postMessage({file,inspectOnly});});
 }finally{await worker.terminate();}
}
for(const name of ['unranked_game1','doubles','FodPlatforms']) {
 test(`parses ${name} with complete frame data`,async()=>{
  const file=new Blob([gunzipSync(readFileSync(`test/fixtures/slippi/${name}.slp.gz`))]);
  const result=await parse(file);
  assert.equal(result.error,undefined);
  assert.ok(result.metadata.frames>0);
  assert.equal(result.metadata.frames,result.replay.frames.length);
  assert.ok(result.replay.frames.every(frame=>frame.players.filter(Boolean).every(player=>player.state&&player.inputs)));
 });
}
test('rejects incomplete and malformed replay data',async()=>{
 for(const file of [new Blob(['not a replay']),new Blob([gunzipSync(readFileSync('test/fixtures/slippi/incomplete.slp.gz'))])]) {
  const result=await parse(file,true);
  assert.ok(result.error);assert.equal(result.replay,undefined);
 }
});

test('rollback replaces items/platform state and supports Nana, transformations and missing animation fields',async()=>{
 const file=new Blob([gunzipSync(readFileSync('test/fixtures/slippi/synthetic-rollback-characters.slp.gz'))]);
 const result=await parse(file);
 assert.equal(result.error,undefined);
 assert.equal(result.metadata.frames,3);
 const frames=result.replay.frames;
 assert.equal(frames[1].items.length,0);
 assert.equal(frames[1].stage.fodLeftPlatformHeight,40);
 assert.equal(frames[2].stage.fodLeftPlatformHeight,40);
 assert.equal(frames[1].players[0].state.xPosition,50);
 assert.equal(frames[1].players[0].nanaState.internalCharacterId,11);
 assert.equal(frames[0].players[1].state.internalCharacterId,7);
 assert.equal(frames[1].players[1].state.internalCharacterId,19);
 assert.equal(frames[0].players[0].state.actionStateFrameCounter,undefined);
});
for(const name of ['invalid-player','invalid-required-float','invalid-frame-allocation','unsupported-character','invalid-container-allocation','invalid-event-bounds']){
 test(`rejects ${name} before unsafe allocation`,async()=>{
  const result=await parse(new Blob([gunzipSync(readFileSync(`test/fixtures/slippi/${name}.slp.gz`))]));
  assert.ok(result.error);assert.equal(result.replay,undefined);
 });
}
