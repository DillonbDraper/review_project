import test from 'node:test';
import assert from 'node:assert/strict';
globalThis.self={addEventListener(){},clients:{},location:{origin:'https://example.test'}};
const {localResponse}=await import('../../assets/js/local_media_sw.mjs');
function request(method='GET',range,clientId='tab-a'){
 const file=Uint8Array.from({length:100},(_,i)=>i), events=[];
 const client={postMessage(data,[port]){
  events.push(data);
  port.onmessage=({data})=>{
   if(data.type==='cancel'){port.close();return;}
   const bytes=file.slice(data.offset,Math.min(data.offset+7,data.end+1));
   port.postMessage({type:'chunk',bytes:bytes.buffer},[bytes.buffer]);
  };
  port.postMessage({type:'metadata',size:file.length,mime:'video/mp4'});
 }};
 return {event:{request:new Request('https://example.test/__local_media/source/1/capability',{method,headers:range?{Range:range}:{}}),clientId},clients:{async get(id){assert.equal(id,'tab-a');return client}},events};
}
test('worker streams correct lengths and ranges without state across requests',async()=>{
 for(const [header,status,length,first]of [[null,200,100,0],['bytes=0-1',206,2,0],['bytes=91-',206,9,91],['bytes=-12',206,12,88],['bytes=100-',416,0,0]]){
  const f=request('GET',header),r=await localResponse(f.event,f.clients);const bytes=new Uint8Array(await r.arrayBuffer());
  assert.equal(r.status,status);assert.equal(r.headers.get('content-length'),String(length));assert.equal(r.headers.get('cache-control'),'no-store');
  assert.equal(bytes.length,length);if(length)assert.equal(bytes[0],first);
  assert.equal(f.events.length,1);assert.equal(f.events[0].path,'/__local_media/source/1/capability');
 }
});
test('worker handles HEAD, missing initiating clients, methods and cancellation',async()=>{
 const f=request('HEAD','bytes=0-1'),r=await localResponse(f.event,f.clients);assert.equal(r.status,206);assert.equal(r.headers.get('content-length'),'2');assert.equal((await r.arrayBuffer()).byteLength,0);
 const missing=request('GET',null,'');assert.equal((await localResponse(missing.event,missing.clients)).status,403);
 const post=request('POST');assert.equal((await localResponse(post.event,post.clients)).status,405);
 const streaming=request(),response=await localResponse(streaming.event,streaming.clients);await response.body.cancel();
});
