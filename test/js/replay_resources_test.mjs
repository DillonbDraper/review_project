import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createReplayResources,parseReplayFile} from '../../assets/js/replay_native.mjs';
const deferred=()=>{let resolve;const promise=new Promise(r=>resolve=r);return {resolve,promise};};
function setup(){
 const workers=[],inputs=[],events=[],renderers=[],listeners=new Map();
 class Worker {constructor(){workers.push(this);}postMessage(){}terminate(){this.terminated=true;}}
 const env={addEventListener:(event,callback)=>listeners.set(event,callback),Worker,crypto:{randomUUID:()=>String(inputs.length)},document:{createElement(type){const el={type,addEventListener(){},click(){},remove(){}};if(type==='input')inputs.push(el);return el;}},Hologram:{dispatchAction:(a,t,p)=>events.push(p)},fetch(){throw Error('Local replay must not upload');}};
 const resources=createReplayResources(env,{mountReplay:async()=>{const r={destroyed:false,destroy(){this.destroyed=true;}};renderers.push(r);return r;}});
 const choose=(params={})=>{resources.choose({solo:true,request:inputs.length+1,generation:1,...params});const input=inputs.at(-1);input.files=[{name:'match.slp',size:42}];const done=input.onchange();return done;};
 const parsed=()=>workers.at(-1).onmessage({data:{metadata:{frames:60,duration:1,stage:2},replay:{frames:[{}]}}});
 return {env,resources,choose,parsed,workers,inputs,events,renderers,listeners};
}
test('solo preparation uses no HTTP and cancellation cannot delete an adopted source',async()=>{
 const t=setup();const task=t.choose();t.parsed();await task;
 const accepted=t.events.find(e=>e.status==='accepted');assert.equal(accepted.result.delivery,'local');
 assert.equal(accepted.result.replay,undefined);assert.equal(accepted.result.handle,'1');
 t.resources.commitLocal(accepted.result.handle);t.resources.cancel();
 assert.equal(t.renderers[0].destroyed,false);
 const entry=await t.resources.scene(accepted.result,new AbortController().signal);assert.ok(entry.replay);
 t.resources.release();assert.equal(t.renderers[0].destroyed,true);
 await assert.rejects(t.resources.scene(accepted.result),/released/);
});
test('cancelled worker callbacks cannot accept a new local source',async()=>{
 const t=setup();const task=t.choose();t.resources.cancel();t.parsed();await task;
 assert.equal(t.workers[0].terminated,true);assert.equal(t.events.some(e=>e.status==='accepted'),false);
});
test('replacement releases previous parsed resources only after adoption',async()=>{
 const t=setup();let task=t.choose();t.parsed();await task;const first=t.events.find(e=>e.status==='accepted').result;t.resources.commitLocal(first.handle);t.resources.cancel();
 task=t.choose();t.parsed();await task;assert.equal(t.renderers[0].destroyed,false);
 const second=t.events.at(-1).result;t.resources.commitLocal(second.handle);assert.equal(t.renderers[0].destroyed,true);assert.equal(t.renderers[1].destroyed,false);
 t.resources.retainSource({kind:'youtube'});assert.equal(t.renderers[1].destroyed,true);
});
test('parser abort terminates the worker and rejects exactly once',async()=>{
 const t=setup(),controller=new AbortController();const p=parseReplayFile({}, {env:t.env,signal:controller.signal});controller.abort();
 await assert.rejects(p,/cancelled/);assert.equal(t.workers[0].terminated,true);
 t.workers[0].onmessage({data:{replay:{}}});
});

test('the accepted room broadcast cannot cancel its pending publishing response',async()=>{
 const t=setup(),reached=deferred(),response=deferred();let uploadSignal;
 t.resources.bind({push(){return {receive(status,callback){if(status==='ok')queueMicrotask(()=>callback({grant:'native-only'}));return this;}};}});
 t.env.fetch=async(url,options)=>{
  if(url==='/room-session')return {json:async()=>({csrf_token:'test'})};
  uploadSignal=options.signal;reached.resolve();return response.promise;
 };
 const task=t.choose({solo:false,room_id:'room'});t.parsed();await reached.promise;
 t.resources.retainSource({kind:'slippi_replay',delivery:'server',id:'accepted'});
 assert.equal(uploadSignal.aborted,false);
 response.resolve({ok:true,json:async()=>({video_id:'accepted'})});await task;
 assert.equal(t.events.at(-1).status,'accepted');t.resources.release();
});

test('pagehide releases parsed local data even if the document enters the back-forward cache',async()=>{
 const t=setup(),task=t.choose();t.parsed();await task;
 const source=t.events.at(-1).result;t.resources.commitLocal(source.handle);
 t.listeners.get('pagehide')();
 assert.equal(t.renderers[0].destroyed,true);
 await assert.rejects(t.resources.scene(source),/released/);
});
