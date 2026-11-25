import test from "node:test";
import assert from "node:assert/strict";

class Peer {
  signalingState = "have-remote-offer";
  iceConnectionState = "checking";
  connectionState = "connecting";
  iceGatheringState = "complete";
  close() {}
}
globalThis.RTCPeerConnection = Peer;
globalThis.document = {};
Object.defineProperty(globalThis, "navigator", {value: {mediaDevices: {}}});
const events = [];
globalThis.Hologram = {dispatchAction: (_action, _target, event) => events.push(event)};
const {default: native} = await import("../../assets/js/conference_native.mjs");
const settle = () => new Promise(resolve => setImmediate(resolve));
const secret = "shared-secret TURN-user TURN-password v=0 a=ice-pwd:credential 192.0.2.1 2001:db8::1 turn:private.invalid room-private arbitrary-message";

test("operation diagnostics use only finite fields for throws, rejections and successes", async t => {
  const logs = [];
  t.mock.method(console, "warn", (...args) => logs.push(args));
  native.reset(1);
  const peer = new Peer();
  document.peer = () => peer;
  const ref = native.sync(1, "peer", {op: "call", ref: "document", method: "peer"}).result;
  for (const method of ["setRemoteDescription", "setLocalDescription", "addIceCandidate", "replaceTrack", "addTrack", "removeTrack", "addTransceiver"]) {
    for (const mode of ["sync", "throw", "reject"]) {
      const error = new Error(secret);
      error.name = "OperationError";
      peer[method] = () => { if (mode === "reject") return Promise.reject(error); throw error; };
      const command = {op: "call", ref, method, args: [secret]};
      let result;
      if (mode === "sync") result = native.sync(1, "peer", command);
      else {
        native.run(1, "peer", command, {event: "peer"});
        await settle();
        result = events.at(-1);
      }
      assert.deepEqual(result.diagnostic, {operation: method, name: "OperationError", reason: "operation-rejected", signalingState: "have-remote-offer", iceConnectionState: "checking", connectionState: "connecting", iceGatheringState: "complete"});
      assert.equal(result.status, "error");
      const output = JSON.stringify([result, logs.at(-1)]);
      for (const token of secret.split(" ")) assert(!output.includes(token), token);
    }
    const before = logs.length;
    peer[method] = () => Promise.resolve(null);
    native.run(1, "peer", {op: "call", ref, method}, {event: "peer"});
    await settle();
    assert.equal(events.at(-1).status, "ok");
    assert.equal(events.at(-1).result, null);
    assert.equal(events.at(-1).diagnostic, undefined);
    assert.equal(logs.length, before);
  }
  peer.signalingState = secret;
  peer.addIceCandidate = () => { throw {name: secret, message: secret}; };
  const result = native.sync(1, "peer", {op: "call", ref, method: "addIceCandidate"});
  assert.equal(result.name, "Error");
  assert.equal(result.diagnostic.reason, "unclassified");
  assert.equal(result.diagnostic.signalingState, "unknown");
  assert(!JSON.stringify([result, logs]).includes(secret));
});
