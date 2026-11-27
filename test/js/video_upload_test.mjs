import test from "node:test";
import assert from "node:assert/strict";
import { createVideoUpload } from "../../assets/js/video_upload.mjs";
const tick = () => new Promise(done => setImmediate(done));
const reply = data => ({ ok: true, json: async () => data });
function fixture(fetch) {
  const events = [], inputs = [], requests = [];
  class XHR {
    upload = {}; headers = {};
    constructor() { requests.push(this); }
    open(...args) { this.opened = args; }
    setRequestHeader(key, value) { this.headers[key] = value; }
    send(file) { this.body = file; }
    abort() { this.aborted = true; this.onabort?.(); }
  }
  const upload = createVideoUpload({ fetch, XMLHttpRequest: XHR,
    document: { createElement: () => { const input = { click() {} }; inputs.push(input); return input; } },
    Hologram: { dispatchAction: (...args) => events.push(args[2]) } });
  const open = room_id => upload.open({ room_id, can_control: true, connected: true, guards: { epoch: "e", revision: 1, authority_revision: 2 } });
  const choose = file => { upload.choose(); const input = inputs.at(-1); input.files = [file]; input.onchange(); };
  return { upload, open, choose, events, inputs, requests };
}
test("late status and old file chooser cannot mutate a new room", async () => {
  let resolve;
  const f = fixture(() => new Promise(done => { resolve = done; }));
  f.open(""); assert.equal(resolve, undefined);
  f.open("old"); f.upload.reset();
  resolve(reply({ staged: { id: "old" }, enabled: true })); await tick();
  assert.deepEqual(f.events, []);
});
test("XHR sends raw bytes and encoded filename with session CSRF, progress and ready state", async () => {
  const f = fixture(async url => reply(url === "/room-session" ? { csrf_token: "csrf" } : { staged: null, enabled: true, max_file_bytes: 100 }));
  f.open("a/b"); await tick();
  const file = { name: "my clip.webm", size: 50 };
  f.choose(file); f.upload.choose(); assert.equal(f.inputs.length, 1);
  await tick(); const req = f.requests[0];
  assert.deepEqual(req.opened, ["POST", "/room-media/a%2Fb"]);
  assert.equal(req.body, file);
  assert.equal(req.headers["x-video-filename"], "my%20clip.webm");
  assert.equal(req.headers["x-csrf-token"], "csrf");
  assert.equal(req.headers["x-video-size"], "50");
  req.upload.onprogress({ lengthComputable: true, loaded: 25, total: 50 });
  assert.equal(f.events.at(-1).progress, 50);
  req.status = 201; req.responseText = JSON.stringify({ id: "asset", status: "ready" }); req.onload();
  assert.equal(f.events.at(-1).staged.id, "asset");
  assert.equal(f.events.at(-1).completed, true);
  await f.upload.status();
  assert.equal(f.events.at(-1).completed, undefined, "status refreshes must not select a video");
  f.upload.reset(); const count = f.events.length; req.onload(); req.onerror();
  assert.equal(f.events.length, count);
});
test("server size limit is enforced and stale session cannot start XHR", async () => {
  let session;
  const f = fixture(url => url === "/room-session" ? new Promise(done => { session = done; }) : Promise.resolve(reply({ staged: null, enabled: true, max_file_bytes: 10 })));
  f.open("room"); await tick();
  f.choose({ name: "clip.mp4", size: 11 }); assert.equal(f.requests.length, 0);
  f.choose({ name: "clip.mp4", size: 10 }); f.upload.reset();
  session(reply({ csrf_token: "old" })); await tick(); assert.equal(f.requests.length, 0);
});
test("1 GiB files reach XHR and one byte over the cap is rejected without allocating bytes", async () => {
  const cap = 1073741824;
  for (const size of [775550155, cap, cap + 1]) {
    const f = fixture(async url => reply(url === "/room-session" ? { csrf_token: "csrf" } : { staged: null, enabled: true, max_file_bytes: cap }));
    f.open("room"); await tick();
    const file = { name: "av1.webm", size };
    f.choose(file); await tick();
    assert.equal(f.requests.length, size <= cap ? 1 : 0);
    if (size <= cap) assert.equal(f.requests[0].body, file);
    f.upload.reset();
  }
});
test("failed upload retains its retry error after status refresh and permits another choice", async () => {
  const f = fixture(async url => reply(url === "/room-session" ? { csrf_token: "csrf" } : { staged: null, enabled: true }));
  f.open("room"); await tick(); f.choose({ name: "a.mp4", size: 1 }); await tick();
  const req = f.requests[0];
  req.status = 422; req.responseText = JSON.stringify({ error: "unsupported_codec" }); req.onload();
  await tick();
  assert.equal(f.events.at(-1).staged, null);
  assert.equal(f.events.at(-1).message, "unsupported_codec. Choose a file to retry.");
  f.choose({ name: "retry.mp4", size: 1 }); await tick();
  assert.equal(f.requests.length, 2);
});
test("stale cancellation remains visible after status refresh without hiding the retained file", async () => {
  const asset = { id: "asset", status: "ready" };
  const f = fixture(async (url, options) => options.method === "DELETE"
    ? { ok: false, json: async () => ({ error: "stale_revision" }) }
    : reply(url === "/room-session" ? { csrf_token: "csrf" } : { staged: asset, enabled: true }));
  f.open("room"); await tick(); f.upload.cancel(); await tick();
  assert.equal(f.events.at(-1).message, "stale_revision");
  assert.deepEqual(f.events.at(-1).staged, asset);
});
test("cancellation aborts immediately and guards DELETE; late completion cannot report into another room", async () => {
  let deletion; const calls = [];
  const f = fixture((url, options) => {
    calls.push([url, options]);
    if (options.method === "DELETE") return new Promise(done => { deletion = done; });
    return Promise.resolve(reply(url === "/room-session" ? { csrf_token: "csrf" } : { staged: null, enabled: true }));
  });
  f.open("old"); await tick(); f.choose({ name: "a.mp4", size: 1 }); await tick();
  f.upload.cancel(); assert.equal(f.requests[0].aborted, true); await tick();
  assert.deepEqual(JSON.parse(calls.find(([, o]) => o.method === "DELETE")[1].body), { epoch: "e", revision: 1, authority_revision: 2 });
  f.open("new"); await tick(); const count = f.events.length;
  deletion(reply({ staged: null })); await tick(); assert.equal(f.events.length, count);
});
