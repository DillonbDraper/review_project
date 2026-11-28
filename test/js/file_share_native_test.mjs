import test from 'node:test';
import assert from 'node:assert/strict';
import {webcrypto} from 'node:crypto';
import {setImmediate as tick} from 'node:timers/promises';
import {createFileShare} from '../../assets/js/file_share_native.mjs';
const descriptor={id:'source',generation:1,available:true,size:100,mime:'video/mp4',codec:'video/mp4; codecs="avc1.42E01E"'};
function fixture(t){
 const events=[],inputs=[],workers=[],revoked=[],pcs=[];let sequence=0;
 class Channel extends EventTarget{
  label='review-file-v1';ordered=true;maxRetransmits=null;maxPacketLifeTime=null;readyState='connecting';bufferedAmount=0;
  send(){}close(){this.readyState='closed';this.onclose?.();this.dispatchEvent(new Event('close'));}
 }
 class Peer{
  constructor(config){this.config=config;pcs.push(this)}
  createDataChannel(){return new Channel()}
  createOffer(){return Promise.resolve({type:'offer',sdp:'bounded'})}
  setLocalDescription(value){this.localDescription=value;return Promise.resolve()}
  setConfiguration(value){this.config=value}getConfiguration(){return this.config}
  close(){this.closed=true}
 }
 const env={crypto:webcrypto,performance:{now:()=>100},addEventListener(){},RTCPeerConnection:Peer,
  URL:{createObjectURL:()=>`blob:${++sequence}`,revokeObjectURL:value=>revoked.push(value)},
  document:{createElement(type){if(type==='video')return {canPlayType:()=> 'probably'};const input={click(){this.clicked=true}};inputs.push(input);return input}},
  Hologram:{dispatchAction:(_action,_target,params)=>events.push(params)},
  Worker:class{constructor(){workers.push(this)}postMessage(){}terminate(){this.terminated=true}},
 };
 const native=createFileShare(env);t.after(()=>native.release());
 const scope={room_id:'room',epoch:'epoch',self_id:'owner'};
 const {generation}=native.start(scope);
 const choose=()=>{native.choose(generation,7);inputs.at(-1).files=[Object.assign(new Blob(['x'.repeat(100)]),{name:'clip.mp4'})];inputs.at(-1).onchange();return events.at(-1).handle};
 return {native,env,scope,generation,events,inputs,workers,revoked,pcs,choose};
}

test('file picker and worker return handles and bounded metadata; only explicit commands adopt a file',async t=>{
 const f=fixture(t),handle=f.choose();
 assert.equal(f.events.at(-1).event,'chosen');assert.equal(f.events.at(-1).request,7);
 assert.equal(f.native.diagnostics.hasFile,false);
 f.native.inspect(f.generation,7,handle);const worker=f.workers[0];
 worker.onmessage({data:{tracks:[{type:'General',format:'MPEG-4'}]}});
 assert.equal(f.events.at(-1).event,'inspected');assert.equal(f.events.at(-1).status,'ok');assert.equal(worker.terminated,true);
 assert.equal(f.native.diagnostics.hasFile,false);
 f.native.adoptFile(f.generation,handle,descriptor);f.native.configureSource(f.generation,descriptor,'source');
 assert.equal(await f.native.url(descriptor),'blob:1');
 assert.equal(f.events.some(event=>event.file instanceof Blob),false);
});

test('same-document invalidation immediately closes peers but preserves only the accepted File handle',async t=>{
 const f=fixture(t),handle=f.choose();f.native.adoptFile(f.generation,handle,descriptor);
 f.native.configureSource(f.generation,descriptor,'source');
 const ref=f.native.keepIce(f.generation,[{urls:'turn:local',credential:'private'}]);
 f.native.run(f.generation,'group','create',{ice_ref:ref},{peer:'guest',token:1});await tick();
 await f.native.url(descriptor);const count=f.events.length;
 f.native.suspend();assert.equal(f.pcs[0].closed,true);assert.deepEqual(f.revoked,['blob:1']);assert.equal(f.native.diagnostics.hasFile,true);
 const next=f.native.start(f.scope,50);assert.ok(next.generation>50);assert.equal(next.retained.handle,handle);
 assert.equal(f.events.length,count,'restoration decisions are left to Hologram');
 await assert.rejects(f.native.url(descriptor),/unavailable/);
 f.native.configureSource(next.generation,null,'receiver');assert.equal(f.native.diagnostics.hasFile,false);
});

test('new document/room, explicit release and source replacement release the old File',t=>{
 const f=fixture(t),handle=f.choose();f.native.adoptFile(f.generation,handle,descriptor);
 const changed=f.native.start({...f.scope,room_id:'different'});assert.equal(changed.retained,null);assert.equal(f.native.diagnostics.hasFile,false);
 f.native.release();assert.equal(f.native.diagnostics.hasFile,false);
});

test('cancelled inspections and delayed native results cannot cross a resource generation',async t=>{
 const f=fixture(t),handle=f.choose();f.native.inspect(f.generation,7,handle);
 f.native.releaseFile(handle);const count=f.events.length;f.workers[0].onmessage({data:{tracks:[]}});assert.equal(f.events.length,count);
 const ref=f.native.keepIce(f.generation,[]);
 f.native.run(f.generation,'group','create',{ice_ref:ref},{peer:'guest',token:1});f.native.suspend();await tick();
 assert.equal(f.events.length,count);assert.equal(f.pcs[0].closed,true);
 f.native.run(f.generation,'stale','create',{ice_ref:ref},{peer:'guest',token:2});assert.equal(f.pcs.length,1);
});

test('API results expose descriptions, credentials remain behind handles, and failures do not schedule policy retries',async t=>{
 const f=fixture(t),ref=f.native.keepIce(f.generation,[{urls:'turn:local',credential:'private'}]);
 assert.equal(typeof ref,'string');f.native.run(f.generation,'group','create',{ice_ref:ref},{peer:'guest',token:1});await tick();
 assert.equal(f.pcs[0].config.iceServers[0].credential,'private');
 f.native.run(f.generation,'group','create_offer',null,{peer:'guest',token:2});await tick();
 assert.deepEqual(f.events.at(-1).result,{type:'offer',sdp:'bounded'});
 f.native.run(f.generation,'missing','set_local',{}, {peer:'guest',token:3});
 assert.equal(f.events.at(-1).status,'error');assert.equal(f.pcs.length,1);
 assert.ok(!JSON.stringify(f.events).includes('private'));
});

test('releasing a player URL does not release the supplying File',async t=>{
 const f=fixture(t),handle=f.choose();f.native.adoptFile(f.generation,handle,descriptor);f.native.configureSource(f.generation,descriptor,'source');
 const url=await f.native.url(descriptor);f.native.revokeURL(url);assert.deepEqual(f.revoked,[url]);assert.ok(f.native.diagnostics.hasFile);
 f.native.release();assert.deepEqual(f.revoked,[url]);
});

test('a peer retains only one protocol channel and disposal closes unbound channels too',async t=>{
 const f=fixture(t),ref=f.native.keepIce(f.generation,[]);
 f.native.run(f.generation,'group','create',{ice_ref:ref},{peer:'guest',token:1});await tick();
 const first=f.pcs[0].createDataChannel(),extra=f.pcs[0].createDataChannel();
 f.pcs[0].ondatachannel({channel:first});f.pcs[0].ondatachannel({channel:extra});
 assert.equal(f.events.filter(event=>event.event==='channel').length,1);
 assert.equal(extra.readyState,'closed');
 f.native.closePeer('group');assert.equal(first.readyState,'closed');
});
