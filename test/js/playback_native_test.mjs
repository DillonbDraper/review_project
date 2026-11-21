import assert from "node:assert/strict";
import { test } from "node:test";
import { createPlaybackNative } from "../../assets/js/playback_native.mjs";

test("adapter cues before readiness and isolates replaced, suspended and disposed players", async (t) => {
  const prior = globalThis.YT;
  t.after(() => (globalThis.YT = prior));
  const players = [],
    events = [],
    calls = [];
  class Player {
    constructor(frame, { events }) {
      this.frame = frame;
      this.events = events;
      this.id = "";
      this.state = -1;
      players.push(this);
    }
    getVideoUrl() {
      return `https://www.youtube.com/watch?v=${this.id}`;
    }
    cueVideoById({ videoId }) {
      this.id = videoId;
      this.state = 5;
      calls.push(["cue", videoId]);
    }
    getCurrentTime() {
      return 12.5;
    }
    getDuration() {
      return 100;
    }
    getPlayerState() {
      return this.state;
    }
    getVolume() {
      return undefined;
    }
    isMuted() {
      return undefined;
    }
    setVolume(v) {
      calls.push(["volume", v]);
    }
    mute() {
      calls.push(["mute"]);
    }
    unMute() {
      calls.push(["unmute"]);
    }
    playVideo() {
      calls.push(["play"]);
    }
    pauseVideo() {
      calls.push(["pause"]);
    }
    seekTo(p) {
      calls.push(["seek", p]);
    }
    destroy() {
      calls.push(["destroy"]);
    }
  }
  globalThis.YT = { Player };
  const host = {
    dataset: {},
    isConnected: true,
    replaceChildren(...nodes) {
      this.children = nodes;
    },
  };
  const document = {
    hidden: false,
    activeElement: null,
    documentElement: {},
    getElementById: () => host,
    createElement: () => ({ remove() {} }),
    addEventListener() {},
  };
  const env = {
    document,
    location: { origin: "https://example.test" },
    performance: { now: () => 100 },
    Hologram: {
      dispatchAction: (action, target, params) =>
        events.push({ action, target, ...params }),
    },
    MutationObserver: class {
      observe() {}
    },
    requestAnimationFrame: () => {},
    addEventListener() {},
    queueMicrotask: () => {},
  };
  const bridge = createPlaybackNative(env);
  t.after(() => bridge.stop());
  const gen = bridge.start(true);
  await bridge.load(gen, "M7lc1UVf-VE");
  players[0].events.onReady();
  assert.equal(
    events.at(-1).ready,
    false,
    "onReady alone does not finish video preparation",
  );
  players[0].events.onStateChange();
  assert.equal(events.at(-1).ready, true);
  assert.equal(events.at(-1).generation, gen);
  assert.equal(
    events.at(-1).volume,
    80,
    "undefined SDK audio readings use primitive defaults",
  );
  assert.equal(events.at(-1).muted, false);
  assert.equal(
    host.children[0].referrerPolicy,
    "strict-origin-when-cross-origin",
  );
  assert.equal(
    new URL(host.children[0].src).searchParams.get("origin"),
    "https://example.test",
  );
  bridge.command(gen, "seek", 30);
  bridge.command(gen, "volume", 25);
  assert.ok(calls.some((c) => c[0] === "seek" && c[1] === 30));
  const frame = host.children[0];
  bridge.load(gen, "aqz-KE-bpKQ");
  assert.equal(host.children[0], frame, "source changes preserve the iframe");
  assert.equal(events.at(-1).ready, false, "replacement must finish cueing");
  players[0].events.onStateChange();
  assert.equal(events.at(-1).ready, true);
  assert.equal(events.at(-1).video_id, "aqz-KE-bpKQ");
  bridge.suspend();
  const count = events.length;
  players[0].events.onStateChange();
  assert.equal(
    events.length,
    count,
    "suspended player events cannot reach the component",
  );
  assert.deepEqual(calls.at(-1), ["pause"]);
  const replacement = bridge.start(true);
  bridge.command(gen, "play");
  assert.deepEqual(calls.at(-1), ["destroy"]);
  await bridge.load(replacement, "aqz-KE-bpKQ");
  players[0].events.onReady();
  assert.equal(events.length, count);
  players[1].events.onReady();
  players[1].events.onStateChange();
  assert.equal(events.at(-1).video_id, "aqz-KE-bpKQ");
  bridge.stop();
  const stopped = events.length;
  players[1].events.onError({ data: 100 });
  assert.equal(events.length, stopped);
  const finalGen = bridge.start(true);
  const pending = bridge.load(finalGen, "M7lc1UVf-VE");
  bridge.stop();
  await pending;
  assert.equal(
    players.length,
    2,
    "late SDK completion cannot recreate a disposed player",
  );
});
