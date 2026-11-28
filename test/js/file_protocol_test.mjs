import test from 'node:test';
import assert from 'node:assert/strict';
import {setImmediate as tick} from 'node:timers/promises';
import {BLOCK, CACHE, HIGH, LOW, MESSAGE, BlockCache, createSender, createReceiver} from '../../assets/js/file_protocol.mjs';
import {rangeResponse} from '../../assets/js/local_media_range.mjs';
import {inspectionTracks} from '../../assets/js/media_metadata.mjs';

class Channel extends EventTarget {
  readyState = 'open'; bufferedAmount = 0; sent = []; binaryType = 'arraybuffer';
  send(data) {
    assert.ok(typeof data === 'string' || data.byteLength <= MESSAGE);
    this.sent.push(data);
    const size = typeof data === 'string' ? data.length : data.byteLength;
    this.bufferedAmount += size;
    setImmediate(() => {
      this.bufferedAmount -= size;
      if (this.other.readyState === 'open') this.other.dispatchEvent(new MessageEvent('message', {data}));
      if (this.bufferedAmount <= this.bufferedAmountLowThreshold) this.dispatchEvent(new Event('bufferedamountlow'));
    });
  }
  close() { if(this.readyState === 'closed') return; this.readyState = 'closed'; this.dispatchEvent(new Event('close')); }
}
function channels() { const a=new Channel(),b=new Channel();a.other=b;b.other=a;return [a,b]; }

test('inclusive, open, suffix and unsatisfiable single ranges', () => {
  assert.deepEqual(rangeResponse(null, 10), {status:200,start:0,end:9,length:10});
  for (const [range,start,end] of [['bytes=0-1',0,1],['bytes=9-',9,9],['bytes=-3',7,9],['bytes=-99',0,9],['bytes=2-99',2,9]]) {
    assert.deepEqual(rangeResponse(range,10),{status:206,start,end,length:end-start+1});
  }
  for(const range of ['bytes=10-','bytes=-0','bytes=3-2','bytes=0-1,3-4','bytes=-','items=0-1','bytes=9007199254740992-']) assert.equal(rangeResponse(range,10).status,416);
});

test('data channel delivery is bounded, exact, cancellable and cached', async t => {
  const file = new Blob([Uint8Array.from({length: BLOCK*6+17},(_,i)=>i%251)]);
  const [source, guest] = channels(), sender=createSender(file,7), cache=new BlockCache();
  sender.attach(source,()=>8192);
  const receiver=createReceiver(guest,file.size,7,cache);
  t.after(()=>{receiver.close();sender.close();guest.close();});
  const pending=Array.from({length:6},(_,i)=>receiver.block(i));
  assert.equal(receiver.outstanding,4);
  const blocks=await Promise.all(pending);
  assert.deepEqual(Buffer.concat(blocks),Buffer.from(await file.slice(0,BLOCK*6).arrayBuffer()));
  assert.ok(source.sent.every(frame=>frame.byteLength<=8192));
  assert.equal(source.bufferedAmountLowThreshold,LOW);
  const count=guest.sent.length; assert.equal(await receiver.block(0),blocks[0]);assert.equal(guest.sent.length,count);
  const abort=new AbortController();const cancelled=receiver.block(6,abort.signal);abort.abort();await assert.rejects(cancelled,/cancelled/);
  await tick(); assert.equal(receiver.outstanding,0);
});

test('source backpressure is event driven and receivers share the send scheduler fairly', async t => {
  const file=new Blob([new Uint8Array(BLOCK)]), sender=createSender(file,1);
  const links=Array.from({length:4},()=>channels());
  const receivers=links.map(([a,b])=>{sender.attach(a);a.bufferedAmount=HIGH;return createReceiver(b,file.size,1);});
  t.after(()=>{sender.close();for(const receiver of receivers)receiver.close();});
  const jobs=receivers.map(r=>r.block(0));
  await tick();await tick();assert.ok(links.every(([a])=>a.sent.length===0));
  for(const [a] of links){a.bufferedAmount=0;a.dispatchEvent(new Event('bufferedamountlow'));}
  await Promise.all(jobs);
  assert.ok(links.every(([a])=>a.sent.length>0));
  assert.ok(links.every(([a])=>a.sent.reduce((n,x)=>n+x.byteLength,0)<=BLOCK+1024));
});

test('cache evicts the least recently used block and stale frames close the receiver', async t => {
  const cache=new BlockCache(2*BLOCK), bytes=new Uint8Array(BLOCK);
  cache.put(1,bytes);cache.put(2,bytes);cache.get(1);cache.put(3,bytes);
  assert.equal(cache.get(2),undefined);assert.ok(cache.get(1));assert.equal(cache.bytes,2*BLOCK);
  const bounded=new BlockCache(); for(let i=0;i<100;i++)bounded.put(i,bytes);assert.equal(bounded.bytes,CACHE);
  const [a,b]=channels(), receiver=createReceiver(b,100,2);
  t.after(()=>{receiver.close();a.close();b.close();});
  const pending=receiver.block(0);const frame=new ArrayBuffer(13);new DataView(frame).setUint32(0,1);
  b.dispatchEvent(new MessageEvent('message',{data:frame}));await assert.rejects(pending,/closed/);
});

test('a slow receiver cannot stop another receiver', async t => {
  const file = new Blob([new Uint8Array(BLOCK)]), sender = createSender(file, 3);
  const [slowSource, slowGuest] = channels(), [fastSource, fastGuest] = channels();
  sender.attach(slowSource); sender.attach(fastSource); slowSource.bufferedAmount = HIGH;
  const slow = createReceiver(slowGuest, file.size, 3), fast = createReceiver(fastGuest, file.size, 3);
  t.after(() => { sender.close(); slow.close(); fast.close(); });
  const abort = new AbortController(), waiting = slow.block(0, abort.signal);
  assert.equal((await fast.block(0)).byteLength, BLOCK);
  assert.equal(slowSource.sent.length, 0);
  abort.abort(); await assert.rejects(waiting, /cancelled/);
});

test('inspection projects bounded primitive metadata without applying format policy', () => {
 const tracks=inspectionTracks({media:{track:[{'@type':'Video',Format:'HEVC',BitDepth:'10',Encoded_Library:'unneeded'}]}});
 assert.equal(tracks[0].format,'HEVC');assert.equal(tracks[0].bit_depth,10);assert.equal(tracks[0].Encoded_Library,undefined);
 assert.throws(()=>inspectionTracks({media:{track:Array(17).fill({})}}),/inspection_limit/);
});
