// Run against `mix holo` and Chrome with remote debugging and fake media enabled.
// Uses Node 24's built-in fetch/WebSocket APIs; no npm dependencies are needed.
import assert from "node:assert/strict";
import {setTimeout as delay} from "node:timers/promises";

const origin = process.env.APP_URL || "http://127.0.0.1:4000";
const debugUrl = process.env.CHROME_DEBUG_URL || "http://127.0.0.1:9222";
const version = await fetch(`${debugUrl}/json/version`).then(response => response.json());
const socket = new WebSocket(version.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
  socket.addEventListener("open", resolve, {once: true});
  socket.addEventListener("error", reject, {once: true});
});

let sequence = 0;
const pending = new Map();
const tabs = [];
socket.addEventListener("message", ({data}) => {
  const message = JSON.parse(data);
  if (message.id) {
    const request = pending.get(message.id);
    if (!request) return;
    pending.delete(message.id);
    clearTimeout(request.timer);
    if (message.error) request.reject(new Error(JSON.stringify(message.error)));
    else request.resolve(message.result);
    return;
  }
  const tab = tabs.find(tab => tab.sessionId === message.sessionId);
  if (!tab) return;
  if (message.method === "Runtime.exceptionThrown") {
    tab.errors.push(message.params.exceptionDetails);
  } else if (message.method === "Runtime.consoleAPICalled" && message.params.type === "error") {
    tab.errors.push(message.params.args.map(arg => arg.description || arg.value));
  } else if (message.method === "Network.responseReceived") {
    const {response} = message.params;
    if (response.status >= 400) tab.errors.push({url: response.url, status: response.status});
    if (new URL(response.url).pathname === "/hologram/sse" && response.status === 200) {
      tab.streamConnections += 1;
    }
  } else if (message.method === "Network.loadingFailed" && !message.params.canceled) {
    tab.errors.push({networkError: message.params.errorText});
  }
});

function send(method, params = {}, sessionId) {
  const id = ++sequence;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`CDP timeout: ${method}`));
    }, 30_000);
    pending.set(id, {resolve, reject, timer});
    socket.send(JSON.stringify({id, method, params, ...(sessionId ? {sessionId} : {})}));
  });
}

async function evaluate(tab, expression) {
  const {result, exceptionDetails} = await send("Runtime.evaluate", {
    expression, returnByValue: true, awaitPromise: true,
  }, tab.sessionId);
  if (exceptionDetails) throw new Error(JSON.stringify(exceptionDetails));
  return result.value;
}

async function until(check, label, timeout = 30_000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await check()) return;
    await delay(100);
  }
  throw new Error(`Timed out: ${label}`);
}

const text = (tab, id) => evaluate(tab, `document.getElementById(${JSON.stringify(id)})?.textContent.trim()`);
const waitText = (tab, id, expected) => until(async () => await text(tab, id) === expected, `${id} = ${expected}`);
const click = (tab, id) => evaluate(tab, `document.getElementById(${JSON.stringify(id)}).click()`);

// Track the actual browser PeerConnections and RTP stats without modifying the app.
function installBrowserMonitor() {
  const OriginalEventSource = window.EventSource;
  window.__smokeStreams = [];
  window.EventSource = class extends OriginalEventSource {
    constructor(...args) {
      super(...args);
      window.__smokeStreams.push(this);
    }
  };
  const Original = window.RTCPeerConnection;
  const connections = [];
  window.RTCPeerConnection = class extends Original {
    constructor(...args) {
      super(...args);
      connections.push(this);
    }
  };
  window.__watchPartyRtcMonitor = {
    connections,
    async snapshot() {
      return {peerConnections: await Promise.all(connections.map(async pc => {
        const stats = [...(await pc.getStats()).values()];
        return {
          connectionState: pc.connectionState,
          stats: {
            inbound: stats.filter(stat => stat.type === "inbound-rtp"),
            outbound: stats.filter(stat => stat.type === "outbound-rtp"),
          },
        };
      }))};
    },
  };
}

async function open(path, marker) {
  const {targetId} = await send("Target.createTarget", {url: "about:blank"});
  const {sessionId} = await send("Target.attachToTarget", {targetId, flatten: true});
  const tab = {targetId, sessionId, errors: [], streamConnections: 0};
  tabs.push(tab);
  await send("Page.enable", {}, sessionId);
  await send("Runtime.enable", {}, sessionId);
  await send("Network.enable", {}, sessionId);
  await send("Emulation.setDeviceMetricsOverride", {width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false}, sessionId);
  await send("Page.addScriptToEvaluateOnNewDocument", {
    source: `(${installBrowserMonitor.toString()})()`,
  }, sessionId);
  await send("Page.navigate", {url: `${origin}${path}`}, sessionId);
  await until(() => evaluate(tab, `document.readyState === "complete" && !!document.getElementById(${JSON.stringify(marker)}) && !!globalThis.Hologram?.dispatchAction`), `mount ${path}`);
  await until(() => tab.streamConnections > 0, `realtime stream ${path}`);
  return tab;
}

async function pixels(tab, id) {
  return evaluate(tab, `(() => {
    const canvas = document.getElementById(${JSON.stringify(id)});
    const data = canvas.getContext("2d").getImageData(0, 0, canvas.width, canvas.height).data;
    let count = 0;
    for (let i = 3; i < data.length; i += 4) if (data[i]) count++;
    return count;
  })()`);
}

async function draw(tab, id) {
  const box = await evaluate(tab, `(() => {
    const canvas = document.getElementById(${JSON.stringify(id)});
    canvas.scrollIntoView({block: "center"});
    const rect = canvas.getBoundingClientRect();
    return {x: rect.x, y: rect.y, width: rect.width, height: rect.height};
  })()`);
  const pointer = (type, x, y, pressed) => send("Input.dispatchMouseEvent", {
    type, x, y, button: pressed ? "left" : "none", buttons: pressed ? 1 : 0,
    ...(type === "mousePressed" || type === "mouseReleased" ? {button: "left", clickCount: 1} : {}),
  }, tab.sessionId);
  const x = box.x + box.width * 0.2;
  const y = box.y + box.height * 0.3;
  await pointer("mouseMoved", x, y, false);
  await pointer("mousePressed", x, y, true);
  for (let i = 1; i <= 20; i++) {
    await pointer("mouseMoved", x + box.width * 0.025 * i, y + box.height * 0.01 * i, true);
  }
  await pointer("mouseReleased", x + box.width * 0.5, y + box.height * 0.2, false);
}

async function drawingCheck(tab, canvasId, initializeId, replayId, clearId) {
  await click(tab, initializeId);
  await draw(tab, canvasId);
  await waitText(tab, "stroke-count-stat", "1");
  const drawn = await pixels(tab, canvasId);
  assert.ok(drawn > 100, `Expected a visible stroke, got ${drawn} pixels`);
  await evaluate(tab, `(() => {
    const canvas = document.getElementById(${JSON.stringify(canvasId)});
    const ctx = canvas.getContext("2d");
    ctx.save(); ctx.resetTransform(); ctx.clearRect(0, 0, canvas.width, canvas.height); ctx.restore();
  })()`);
  assert.equal(await pixels(tab, canvasId), 0);
  await click(tab, replayId);
  await until(async () => await pixels(tab, canvasId) > 100, "replay stored stroke");
  const replayed = await pixels(tab, canvasId);
  await click(tab, clearId);
  await waitText(tab, "stroke-count-stat", "0");
  assert.equal(await pixels(tab, canvasId), 0);
  return {drawn, replayed};
}

try {
  const interop = await open("/dev/spikes/hologram-interop", "initialize-canvas-button");
  const drawing = await drawingCheck(interop, "hologram-interop-canvas", "initialize-canvas-button", "replay-canvas-button", "clear-canvas-button");
  await click(interop, "create-reference-probes-button");
  await click(interop, "exercise-reference-probes-button");
  await waitText(interop, "registry-ref-count-stat", "50 / 50");
  assert.equal(await text(interop, "direct-ref-count-stat"), "1 / 1", "Plain JS objects are copied into Elixir maps");
  await evaluate(interop, `(() => {
    for (let i = 0; i < 50; i++) Hologram.dispatchAction("stroke_recorded", "page", {
      stroke: {color: "#67e8f9", points: [{x: 0.2, y: 0.3, t: i}, {x: 0.7, y: 0.5, t: i + 1}]},
      point_count: 2, sample_count: i + 1, latest_point_text: "0.700, 0.500"
    });
  })()`);
  await waitText(interop, "stroke-count-stat", "50");
  await click(interop, "replay-canvas-button");
  assert.ok(await pixels(interop, "hologram-interop-canvas") > 100);
  await click(interop, "clear-canvas-button");
  await waitText(interop, "stroke-count-stat", "0");
  for (const mode of ["direct", "registry"]) {
    await click(interop, `create-${mode}-webrtc-button`);
    await waitText(interop, `${mode}-webrtc-channel-stat`, "open");
    await click(interop, `send-${mode}-webrtc-ping-button`);
    await waitText(interop, `${mode}-webrtc-ping-stat`, "1 / 1");
    assert.ok(Number(await text(interop, `${mode}-webrtc-message-events-stat`)) >= 2);
    await click(interop, `close-${mode}-webrtc-button`);
    await waitText(interop, `${mode}-webrtc-channel-stat`, "closed");
  }
  await click(interop, "destroy-reference-probes-button");
  console.log("PASS interop:", JSON.stringify({drawing, referenceActions: 50, burstStrokes: 50, loopbacks: 2}));

  const media = await open("/dev/spikes/hologram-webrtc", "start-membrane-session");
  await click(media, "start-membrane-session");
  await waitText(media, "ready-stat", "true");
  await until(async () => Number(await text(media, "player-frames-stat")) > 20, "decoded Membrane video frames");
  await evaluate(media, `globalThis.__smokePlayer = document.getElementById("membrane-player")`);
  const before = Number(await text(media, "player-frames-stat"));
  const overlay = await drawingCheck(media, "membrane-overlay", "enable-drawing", "replay-drawing", "clear-drawing");
  assert.equal(await evaluate(media, `globalThis.__smokePlayer === document.getElementById("membrane-player")`), true);
  await until(async () => Number(await text(media, "player-frames-stat")) > before, "video continues during drawing");
  const rtc = await evaluate(media, `window.__watchPartyRtcMonitor.snapshot()`);
  assert.equal(rtc.peerConnections.length, 2);
  assert.ok(rtc.peerConnections.every(pc => pc.connectionState === "connected"));
  const inbound = rtc.peerConnections.flatMap(pc => pc.stats.inbound);
  assert.ok(inbound.some(stat => stat.kind === "audio" && stat.packetsReceived > 0));
  assert.ok(inbound.some(stat => stat.kind === "video" && stat.framesDecoded > 0));
  assert.equal(await text(media, "error-stat"), "—");
  const tracks = await evaluate(media, `(() => {
    globalThis.__smokeTracks = document.getElementById("membrane-capture").srcObject.getTracks();
    return __smokeTracks.map(track => track.kind);
  })()`);
  await click(media, "stop-membrane-session");
  await waitText(media, "ready-stat", "false");
  await until(() => evaluate(media, `__smokeTracks.every(track => track.readyState === "ended") && __watchPartyRtcMonitor.connections.every(pc => pc.connectionState === "closed")`), "media resource cleanup");
  const summarizeRtp = stats => stats.map(({kind, packetsReceived, packetsSent, framesDecoded, framesEncoded}) => ({kind, packetsReceived, packetsSent, framesDecoded, framesEncoded}));
  console.log("PASS Membrane:", JSON.stringify({overlay, tracks, peers: rtc.peerConnections.map(pc => ({state: pc.connectionState, inbound: summarizeRtp(pc.stats.inbound), outbound: summarizeRtp(pc.stats.outbound)}))}));

  // A separate tab must mount its own runtime and start with independent state.
  const second = await open("/dev/spikes/hologram-interop", "initialize-canvas-button");
  await waitText(second, "stroke-count-stat", "0");
  await click(second, "initialize-canvas-button");
  await waitText(second, "canvas-ready-stat", "true");
  const oldTimeOrigin = await evaluate(second, "performance.timeOrigin");
  const oldStreams = second.streamConnections;
  await send("Page.reload", {}, second.sessionId);
  await until(() => evaluate(second, `performance.timeOrigin !== ${oldTimeOrigin} && document.readyState === "complete" && !!document.getElementById("initialize-canvas-button") && !!globalThis.Hologram?.dispatchAction`), "reload Hologram page");
  await until(() => second.streamConnections > oldStreams, "realtime stream after reload");
  await click(second, "initialize-canvas-button");
  await waitText(second, "canvas-ready-stat", "true");
  console.log("PASS independent tab and reload");

  const beforeReconnect = second.streamConnections;
  // Close the real stream and inject the browser's error notification. Chrome's
  // network emulation does not reliably disconnect an already-open local stream.
  await evaluate(second, `(() => {
    const stream = __smokeStreams.at(-1);
    stream.close();
    stream.dispatchEvent(new Event("error"));
  })()`);
  await until(() => second.streamConnections > beforeReconnect, "realtime stream reconnect");
  await until(() => evaluate(second, "__smokeStreams.at(-1).readyState === EventSource.OPEN"), "reconnected stream open");
  console.log("PASS realtime reconnect after simulated stream loss");

  for (const tab of tabs) assert.deepEqual(tab.errors, [], "Browser exceptions, console errors or HTTP failures");
  console.log("PASS no browser exceptions, console errors or HTTP failures");
} finally {
  // Stop server-side media even when a later assertion fails.
  for (const tab of tabs) {
    await evaluate(tab, `document.getElementById("stop-membrane-session")?.click()`).catch(() => {});
  }
  for (const tab of tabs) await send("Target.closeTarget", {targetId: tab.targetId});
  socket.close();
}
