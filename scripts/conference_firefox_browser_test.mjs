// Focused real-workspace Firefox media/TURN test. Use an isolated profile which
// trusts the local relay CA and has fake media devices/permission configured.
import assert from "node:assert/strict";
import {conferenceInstrumentation, conferenceTrace} from "./conference_browser_instrumentation.mjs";
import {verifyCredentialRenewal} from "./room_conference_browser_scenarios.mjs";

const app = process.env.APP_URL || "http://localhost:4000";
const mode = process.env.CONFERENCE_RELAY || "tls";
const ws = new WebSocket(process.env.FIREFOX_DEBUG_URL || "ws://127.0.0.1:9235/session");
await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
let sequence = 0;
const requests = new Map(), contexts = [], errors = [];
ws.onmessage = ({data}) => {
  const message = JSON.parse(data);
  if (message.id) {
    const request = requests.get(message.id);
    requests.delete(message.id); clearTimeout(request?.timer);
    if (message.type === "error") request?.reject(new Error(message.message));
    else request?.resolve(message.result);
  } else if (message.method === "log.entryAdded" && message.params.level === "error" && message.params.type === "javascript") {
    errors.push(message.params.text);
  }
};
function call(method, params = {}) {
  const id = ++sequence;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { requests.delete(id); reject(new Error(`Protocol timeout: ${method}`)); }, 30000);
    requests.set(id, {resolve, reject, timer}); ws.send(JSON.stringify({id, method, params}));
  });
}
async function wait(page, expression, description) {
  const deadline = Date.now() + 40000;
  while (Date.now() < deadline) {
    try { if (await page.evaluate(expression)) return; } catch {}
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error(`Timed out: ${description}; ${JSON.stringify(await page.evaluate(`(async () => ({
    body: document.body.innerText.slice(0,1800), instrumentation: typeof __rtcPeers, iceErrors: globalThis.__rtcIceErrors, trace: globalThis.__rtcTrace,
    peers: await Promise.all((globalThis.__rtcPeers || []).map(async pc => ({state: pc.connectionState, ice: pc.iceConnectionState,
      candidates: [...(await pc.getStats()).values()].filter(s => s.type === 'local-candidate').map(s => ({type: s.candidateType, protocol: s.protocol, relayProtocol: s.relayProtocol})),
      receivers: pc.getReceivers().map(r => r.track.kind), rtp: [...(await pc.getStats()).values()].filter(r => ['inbound-rtp','outbound-rtp'].includes(r.type)).map(r => ({type:r.type,kind:r.kind,bytesReceived:r.bytesReceived,framesDecoded:r.framesDecoded,framesEncoded:r.framesEncoded}))})))
    , videos: [...document.querySelectorAll('.conference-tile video')].map(v => ({width: v.videoWidth, paused: v.paused, frames: v.getVideoPlaybackQuality().totalVideoFrames}))
  }))()`))}`);
}
async function tab() {
  const {userContext} = await call("browser.createUserContext");
  const {context} = await call("browsingContext.create", {type: "window", userContext});
  contexts.push(context);
  await call("browsingContext.setViewport", {context, viewport: {width: 1440, height: 1000}});
  const evaluate = async expression => {
    const result = await call("script.evaluate", {expression: `(async () => JSON.stringify(await (${expression})))()`, target: {context}, awaitPromise: true});
    if (result.type === "exception") throw new Error(JSON.stringify(result.exceptionDetails));
    return result.result.value === undefined ? undefined : JSON.parse(result.result.value);
  };
  return {evaluate,
    activate: () => call("browsingContext.activate", {context}),
    navigate: url => call("browsingContext.navigate", {context, url: new URL(url, app).href, wait: "complete"}),
    fill: (selector, value) => evaluate(`(() => {
      const el = document.querySelector(${JSON.stringify(selector)});
      el.value = ${JSON.stringify(value)};
      el.dispatchEvent(new Event('input', {bubbles: true}));
      el.dispatchEvent(new Event('change', {bubbles: true}));
    })()`),
    click: async selector => {
      await call("browsingContext.activate", {context});
      await evaluate(`document.querySelector(${JSON.stringify(selector)}).scrollIntoView({block: 'center', behavior: 'instant'})`);
      const {x,y} = await evaluate(`(async () => {
        await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        const el = document.querySelector(${JSON.stringify(selector)});
        const r = el.getBoundingClientRect();
        const x = Math.round(r.x + r.width/2), y = Math.round(r.y + r.height/2);
        if (!el.contains(document.elementFromPoint(x,y))) throw new Error('Covered button: ' + ${JSON.stringify(selector)});
        return {x,y};
      })()`);
      await call("input.performActions", {context, actions: [{type: "pointer", id: "mouse", parameters: {pointerType: "mouse"}, actions: [
        {type: "pointerMove", x,y,duration: 0}, {type: "pointerDown",button: 0}, {type: "pointerUp",button: 0}]}]});
    }
  };
}
try {
  const session = await call("session.new", {capabilities: {alwaysMatch: {acceptInsecureCerts: false}}});
  await call("session.subscribe", {events: ["log.entryAdded"]});
  await call("script.addPreloadScript", {functionDeclaration: `() => {${conferenceInstrumentation(mode, process.env.CONFERENCE_RELAY_URL)}}`});
  const host = await tab();
  await host.navigate("/users/register");
  await wait(host, "document.querySelector('#registration_form') && document.querySelector('[data-phx-main]')?.classList.contains('phx-connected')", "register host");
  const email = `conference-firefox-${Date.now()}@example.test`;
  await host.fill('#registration_form input[type=email]', email);
  await wait(host, "!document.querySelector('.phx-change-loading') && !document.querySelector('#registration_form button').disabled", "registration validation settled");
  await host.click('#registration_form button');
  await wait(host, "location.pathname === '/users/log-in'", "registration complete");
  const mailbox = await fetch(`${app}/dev/mailbox/json`).then(r => r.json());
  const mail = mailbox.data.find(item => item.text_body?.includes(email));
  assert(mail);
  await host.navigate(new URL(mail.text_body.match(/https?:\/\/[^\s]+\/users\/log-in\/[^\s]+/)[0]).pathname);
  await wait(host, "document.querySelector('#confirmation_form') && document.querySelector('[data-phx-main]')?.classList.contains('phx-connected')", "confirm host");
  await host.click('#confirmation_form button');
  await wait(host, "document.querySelector('#account-email') && document.querySelector('#room-panel')?.dataset.ready === 'true'", "host workspace");
  await host.click('#open-create-room');
  await wait(host, "document.querySelector('#create-room-dialog')?.open", "create room");
  await host.fill('#room-title', `Firefox ${mode.toUpperCase()} conference`);
  await host.fill('#host-name', 'Firefox host');
  await host.click('#create-room-submit');
  await wait(host, "document.querySelector('#invitation-dialog')?.open && document.querySelector('#invitation-link')?.value", "invitation");
  const invitation = await host.evaluate("document.querySelector('#invitation-link').value");
  await host.click('#close-invitation');
  await wait(host, "!document.querySelector('#invitation-dialog').open", "invitation closed");
  await host.evaluate(conferenceTrace());
  const guest = await tab();
  await guest.navigate(invitation);
  await wait(guest, "document.querySelector('#join-room-dialog')?.open", "guest entry");
  await guest.evaluate(conferenceTrace());
  await guest.fill('#guest-name', 'Firefox guest');
  await guest.click('#join-room-submit');
  for (const page of [host,guest]) {
    await wait(page, "__rtcPeers.filter(pc => pc.connectionState === 'connected').length === 1", "receive-only conference connection");
    assert.equal(await page.evaluate('__captureCalls.length'), 0);
    await page.click('#conference-microphone');
    await page.click('#conference-camera');
    await wait(page, "document.querySelector('#conference-camera').getAttribute('aria-pressed') === 'true' && document.querySelector('#conference-microphone').getAttribute('aria-pressed') === 'true'", "enabled devices");
  }
  for (const page of [host,guest]) await wait(page, "__rtcPeers.filter(pc => pc.connectionState === 'connected').length === 1", "media transport connected");
  console.log("PASS: Firefox admitted both participants and enabled media");
  await verifyCredentialRenewal({host,guest,wait,mode});
  for (const page of [host,guest]) {
    await page.click('#leave-room');
    await wait(page, "__rtcPeers.every(pc => pc.connectionState === 'closed') && __rtcTracks.every(track => track.readyState === 'ended')", "leave releases native resources");
  }
  assert.deepEqual(errors, []);
  console.log(`PASS: Firefox ${session.capabilities.browserVersion} ${mode} workspace conference`);
} finally {
  for (const context of contexts) await call('browsingContext.close', {context});
  try { await call('session.end'); } catch {}
  ws.close();
}
