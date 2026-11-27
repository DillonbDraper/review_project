import test from "node:test";
import assert from "node:assert/strict";
import { createPlaybackNative } from "../../assets/js/playback_native.mjs";
function nativeFixture(t) {
  const videos = [], events = [], windowEvents = {}, documentEvents = {};
  class Video {
    tagName = "VIDEO"; readyState = 0; currentTime = 0; duration = 30; paused = true; ended = false; playbackRate = 1; listeners = {};
    addEventListener(name, callback) { this.listeners[name] = callback; }
    fire(name, event = {}) { this.listeners[name]?.(event); }
    play() { return Promise.reject(new Error("blocked")); }
    pause() { this.paused = true; }
    removeAttribute(name) { delete this[name]; }
    load() { this.released = true; }
    remove() { this.removed = true; }
  }
  const host = { dataset: {}, isConnected: true, replaceChildren(video) { this.video = video; } };
  const document = {
    getElementById: () => host, createElement: () => { const v = new Video(); videos.push(v); return v; },
    addEventListener(name, callback) { documentEvents[name] = callback; }, documentElement: {}, hidden: false,
  };
  const bridge = createPlaybackNative({ document,
    performance: { now: () => 100 }, MutationObserver: class { observe() {} },
    requestAnimationFrame(callback) { callback(); },
    addEventListener(name, callback) { windowEvents[name] = callback; }, queueMicrotask() {},
    Hologram: { dispatchAction: (...args) => events.push(args) } });
  t.after(() => bridge.stop());
  return { bridge, videos, events, host, document, windowEvents, documentEvents };
}

test("native upload readiness, controls, blocked play, stale events and teardown", async t => {
  const { bridge, videos, events } = nativeFixture(t);
  const generation = bridge.start(true, 65, true);
  bridge.load(generation, "upload:one", { kind: "upload", url: "/room-media/r/one" });
  const v = videos[0]; assert.equal(v.src, "/room-media/r/one");
  assert.equal(bridge.read().ready, false); assert.equal(v.volume, .65); assert.equal(v.muted, true);
  v.readyState = 1; v.fire("loadedmetadata"); assert.equal(bridge.read().ready, true);
  assert.equal(events.some(([action]) => action === "player_activity"), false);
  v.fire("pointerdown"); assert.equal(events.some(([action]) => action === "player_activity"), false);
  v.fire("pointerdown", { isTrusted: true }); assert.equal(events.at(-1)[0], "player_activity");
  assert.equal(events.at(-1)[2].generation, generation);
  assert.equal(bridge.read().video_id, "upload:one"); assert.equal(bridge.read().duration, 30);
  bridge.command(generation, "seek", 12); assert.equal(v.currentTime, 12);
  bridge.command(generation, "volume", 25); assert.equal(v.volume, .25);
  bridge.command(generation, "play"); await Promise.resolve(); assert.equal(bridge.read().blocked, true);
  v.fire("error"); assert.match(bridge.read().error, /could not be played/);
  bridge.load(generation, "upload:two", { kind: "upload", url: "/room-media/r/two" });
  assert.equal(v.released, true); assert.equal(v.src, undefined);
  const count = events.length; v.fire("error"); assert.equal(events.length, count);
  bridge.clear(); assert.equal(videos[1].released, true); assert.equal(videos[1].removed, true);
  assert.equal(bridge.read().ready, false);
});

test("uploaded playback exposes local correction speed and resets it on source replacement", t => {
  const { bridge, videos } = nativeFixture(t);
  const generation = bridge.start(true);
  bridge.load(generation, "upload:one", { kind: "upload", url: "/room-media/r/one" });
  videos[0].readyState = 3; videos[0].fire("canplay");
  bridge.command(generation, "rate", 1.05);
  assert.equal(videos[0].playbackRate, 1.05);
  assert.equal(bridge.read().playback_rate, 1.05);
  bridge.command(generation, "rate", 0.95);
  assert.equal(bridge.read().playback_rate, 0.95);
  bridge.load(generation, "upload:two", { kind: "upload", url: "/room-media/r/two" });
  videos[1].readyState = 3; videos[1].fire("canplay");
  assert.equal(videos[1].playbackRate, 1);
  assert.equal(bridge.read().playback_rate, 1);
});

test("suspended native upload ignores stale events, commands and delayed play rejection", async t => {
  const { bridge, videos, events } = nativeFixture(t);
  const generation = bridge.start(true);
  bridge.load(generation, "upload:one", { kind: "upload", url: "/room-media/r/one" });
  const old = videos[0];
  old.readyState = 3;
  old.fire("canplay");
  let rejectPlay;
  old.play = () => new Promise((resolve, reject) => { rejectPlay = reject; });
  bridge.command(generation, "play");
  bridge.suspend();
  assert.equal(bridge.read(), null);
  const suspended = events.length;
  old.fire("error");
  old.fire("pointerdown", { isTrusted: true });
  bridge.command(generation, "seek", 15);
  assert.equal(old.currentTime, 0);
  assert.equal(events.length, suspended);

  const next = bridge.start(true, 35, true);
  assert.ok(next > generation);
  assert.equal(old.released, true);
  assert.equal(old.src, undefined);
  bridge.load(next, "upload:one", { kind: "upload", url: "/room-media/r/one" });
  const current = videos[1];
  current.readyState = 3;
  current.fire("canplay");
  const restored = events.length;
  rejectPlay(new Error("obsolete play attempt"));
  await Promise.resolve();
  old.fire("canplay");
  bridge.command(generation, "seek", 20);
  assert.equal(events.length, restored);
  assert.equal(current.currentTime, 0);
  assert.equal(bridge.read().blocked, false);
  assert.equal(bridge.read().generation, next);
  assert.equal(current.volume, .35);
  assert.equal(current.muted, true);
});

test("pagehide releases native source and persisted pageshow requests a fresh mount", t => {
  const { bridge, videos, events, host, document, windowEvents, documentEvents } = nativeFixture(t);
  const generation = bridge.start(true);
  bridge.load(generation, "upload:one", { kind: "upload", url: "/room-media/r/one" });
  const video = videos[0];
  video.readyState = 3;
  video.fire("canplay");
  document.hidden = true;
  documentEvents.visibilitychange();
  assert.equal(events.at(-1)[0], "player_visible");
  assert.equal(events.at(-1)[2].visible, false);
  assert.equal(events.at(-1)[2].generation, generation);

  windowEvents.pagehide();
  assert.equal(video.released, true);
  assert.equal(video.removed, true);
  assert.equal(video.src, undefined);
  assert.equal(host.dataset.resources, "0");
  assert.equal(bridge.read(), null);
  const stopped = events.length;
  video.fire("error");
  video.fire("keydown", { isTrusted: true });
  documentEvents.visibilitychange();
  assert.equal(events.length, stopped);
  windowEvents.pageshow({ persisted: false });
  assert.equal(events.length, stopped);
  windowEvents.pageshow({ persisted: true });
  assert.equal(events.at(-1)[0], "player_mounted");
  assert.equal(bridge.read(), null, "restoration must not resurrect the old native player");
  const next = bridge.start(true);
  assert.ok(next > generation);
  bridge.load(next, "upload:one", { kind: "upload", url: "/room-media/r/one" });
  assert.equal(videos.length, 2);
  assert.equal(bridge.read().generation, next);
});
