import test from "node:test";
import assert from "node:assert/strict";

class Track extends EventTarget {
  stops = 0;
  stop() { this.stops++; }
}
class Stream { constructor(tracks = []) { this.tracks = tracks; } getTracks() { return this.tracks; } }
class Peer extends EventTarget { closed = false; close() { this.closed = true; } }
class Audio { srcObject = null; remove() { this.removed = true; } }
const events = [];
Object.assign(globalThis, {MediaStreamTrack: Track, MediaStream: Stream,
  RTCPeerConnection: Peer, HTMLMediaElement: Audio, document: {},
  Hologram: {dispatchAction: (_name, _target, event) => events.push(event)}});
Object.defineProperty(globalThis, "navigator", {value: {mediaDevices: {}}});
const {default: native} = await import("../../assets/js/conference_native.mjs");
const command = (ref, method, args = []) => ({op: "call", ref, method, args});
const settle = () => new Promise(resolve => setImmediate(resolve));

test("invalidation disposes native resources immediately and advances past restored epochs", async () => {
  native.reset(30);
  const pc = new Peer();
  document.peer = () => pc;
  native.sync(30, "peer", command("document", "peer"));
  let resolve;
  navigator.mediaDevices.getUserMedia = () => new Promise(done => { resolve = done; });
  native.run(30, "camera", command("mediaDevices", "getUserMedia"), {event: "capture"});
  const before = events.length;

  assert.equal(native.invalidate(500), 501);
  assert(pc.closed);
  assert.equal(native.current(30), false);
  assert.equal(native.current(501), true);
  assert.equal(native.invalidate(1), 502);
  assert.equal(events.length, before);

  const track = new Track();
  resolve(new Stream([track]));
  await settle();
  assert.equal(track.stops, 1);
  assert.equal(events.length, before);
});

test("credentials are retained by opaque handle and released with their scope", () => {
  native.reset(20);
  const config = {iceServers: [{urls: ["turn:relay"], credential: "temporary-secret"}]};
  const kept = native.sync(20, "ice", {op: "keep", value: config});
  assert.equal(typeof kept.result, "string");
  assert(!JSON.stringify(kept).includes("temporary-secret"));
  document.acceptConfig = value => { assert.deepEqual(value, config); return true; };
  assert.equal(native.sync(20, "peer", command("document", "acceptConfig", [kept.result])).result, true);
  native.close("ice");
  assert.equal(native.sync(20, "peer", command("document", "acceptConfig", [kept.result])).status, "error");
});

test("scoped timers replace prior attempts and cannot outlive cancellation or reset", t => {
  t.mock.timers.enable({apis: ["setTimeout"]});
  native.reset(21);
  const before = events.length;
  native.later(21, "peer", "retry", 10, {event: "old"});
  native.later(21, "peer", "retry", 20, {event: "current"});
  t.mock.timers.tick(10);
  assert.equal(events.length, before);
  t.mock.timers.tick(10);
  assert.equal(events.at(-1).event, "current");
  native.later(21, "peer", "retry", 10, {event: "cancelled"});
  native.cancel(21, "peer", "retry");
  native.later(21, "other", "retry", 10, {event: "closed"});
  native.close("other");
  native.later(21, "peer", "retry", 10, {event: "reset"});
  native.reset(22);
  t.mock.timers.tick(10);
  assert.equal(events.length, before + 1);
});

test("native handles preserve identity and release resources on reset", () => {
  native.reset(1);
  const pc = native.sync(1, "peer", {op: "new", type: "RTCPeerConnection"}).result;
  const object = new Peer();
  globalThis.document.peer = () => object;
  const first = native.sync(1, "peer", command("document", "peer")).result;
  const second = native.sync(1, "peer", command("document", "peer")).result;
  assert.equal(first, second);
  assert.equal(typeof pc, "string");
  native.reset(2);
  assert(object.closed);
  assert.equal(native.sync(2, "peer", command(pc, "close")).status, "error");
});

test("cancelled permission results stop tracks without dispatching obsolete state", async () => {
  native.reset(3);
  let resolve;
  navigator.mediaDevices.getUserMedia = () => new Promise(done => { resolve = done; });
  native.run(3, "camera", command("mediaDevices", "getUserMedia"), {event: "capture"});
  native.close("camera");
  const before = events.length, track = new Track();
  resolve(new Stream([track]));
  await settle();
  assert.equal(track.stops, 1);
  assert.equal(events.length, before);
});

test("resolved captures are owned before Elixir adopts their stream", async () => {
  native.reset(4);
  const track = new Track();
  navigator.mediaDevices.getUserMedia = async () => new Stream([track]);
  native.run(4, "camera", command("mediaDevices", "getUserMedia"), {event: "capture"});
  await settle();
  assert.equal(events.at(-1).status, "ok");
  assert.equal(typeof events.at(-1).result, "string");
  native.reset(5);
  assert.equal(track.stops, 1);
});

test("closing a peer does not release borrowed local capture", async () => {
  native.reset(6);
  const track = new Track(), stream = new Stream([track]);
  navigator.mediaDevices.getUserMedia = async () => stream;
  native.run(6, "camera", command("mediaDevices", "getUserMedia"), {event: "capture"});
  await settle();
  const streamRef = events.at(-1).result;
  native.sync(6, "peer", command(streamRef, "getTracks"));
  native.close("peer");
  assert.equal(track.stops, 0);
  native.close("camera");
  assert.equal(track.stops, 1);
});

test("listeners project plain data and are detached before disposal", () => {
  native.reset(7);
  const pc = new Peer();
  document.peer = () => pc;
  const ref = native.sync(7, "peer", command("document", "peer")).result;
  native.listen(7, "peer", ref, "icecandidate", ["candidate"], {event: "ice"});
  const event = new Event("icecandidate");
  event.candidate = {toJSON: () => ({candidate: "ice", usernameFragment: "ufrag"})};
  pc.dispatchEvent(event);
  assert.deepEqual(events.at(-1).result, {candidate: {candidate: "ice", usernameFragment: "ufrag"}});
  const before = events.length;
  native.close("peer");
  pc.dispatchEvent(event);
  assert.equal(events.length, before);
});

test("reading a stopped sender track does not reacquire released capture", async () => {
  native.reset(10);
  const track = new Track();
  navigator.mediaDevices.getUserMedia = async () => new Stream([track]);
  native.run(10, "camera", command("mediaDevices", "getUserMedia"), {event: "capture"});
  await settle();
  const stream = events.at(-1).result;
  const [trackRef] = native.sync(10, "camera", command(stream, "getTracks")).result;
  native.close("camera");
  document.senderTrack = () => track;
  assert.equal(native.sync(10, "peer", command("document", "senderTrack")).result, trackRef);
  native.close("peer");
  assert.equal(track.stops, 1);
});

test("rejected native promises report plain errors and ignore superseded generations", async () => {
  native.reset(8);
  navigator.mediaDevices.getUserMedia = async () => { throw new DOMException("denied", "NotAllowedError"); };
  native.run(8, "camera", command("mediaDevices", "getUserMedia"), {event: "capture"});
  await settle();
  assert.equal(events.at(-1).name, "NotAllowedError");
  const before = events.length;
  native.run(8, "camera", command("mediaDevices", "getUserMedia"), {event: "capture"});
  native.reset(9);
  await settle();
  assert.equal(events.length, before);
});
