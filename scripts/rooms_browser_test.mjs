// Run against a local development server and an isolated Chrome debugging port.
// Registers a synthetic host using the local mailbox; never contacts real email.
import assert from "node:assert/strict";
import {writeFile} from "node:fs/promises";
import {verifyRoomChat} from "./room_chat_browser_scenarios.mjs";

const app = process.env.APP_URL || "http://localhost:4000";
const debug = process.env.CHROME_DEBUG_URL || "http://127.0.0.1:9222";
const version = await fetch(`${debug}/json/version`).then(response => response.json());
const ws = new WebSocket(version.webSocketDebuggerUrl);
await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
let sequence = 0;
const pending = new Map();
const contexts = [];
const exceptions = [];
const loaded = new Set();

ws.onmessage = ({data}) => {
  const message = JSON.parse(data);
  if (message.id) {
    const request = pending.get(message.id);
    pending.delete(message.id);
    if (message.error) request?.reject(new Error(message.error.message));
    else request?.resolve(message.result);
  } else if (message.method === "Runtime.exceptionThrown") {
    exceptions.push(message.params.exceptionDetails.exception?.description || message.params.exceptionDetails.text);
  } else if (message.method === "Page.lifecycleEvent" && message.params.name === "load") {
    loaded.add(`${message.sessionId}:${message.params.loaderId}`);
  }
};

function call(method, params = {}, sessionId) {
  const id = ++sequence;
  return new Promise((resolve, reject) => {
    pending.set(id, {resolve, reject});
    ws.send(JSON.stringify({id, method, params, ...(sessionId ? {sessionId} : {})}));
  });
}

async function tab(context) {
  if (!context) {
    ({browserContextId: context} = await call("Target.createBrowserContext", {disposeOnDetach: true}));
    contexts.push(context);
  }
  const {targetId} = await call("Target.createTarget", {url: "about:blank", browserContextId: context});
  const {sessionId} = await call("Target.attachToTarget", {targetId, flatten: true});
  await call("Page.enable", {}, sessionId);
  await call("Emulation.setDeviceMetricsOverride", {width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false}, sessionId);
  await call("Page.setLifecycleEventsEnabled", {enabled: true}, sessionId);
  await call("Runtime.enable", {}, sessionId);
  await call("Page.addScriptToEvaluateOnNewDocument", {source: `
    globalThis.__testSockets = new Set();
    const NativeWebSocket = globalThis.WebSocket;
    globalThis.WebSocket = class extends NativeWebSocket {
      constructor(...args) {
        super(...args);
        globalThis.__testSockets.add(this);
        this.addEventListener('close', () => globalThis.__testSockets.delete(this));
      }
    };
  `}, sessionId);
  const evaluate = async expression => {
    const result = await call("Runtime.evaluate", {expression, returnByValue: true, awaitPromise: true}, sessionId);
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text);
    return result.result.value;
  };
  return {context, sessionId, evaluate,
    navigate: async url => {
      const result = await call("Page.navigate", {url: new URL(url, app).href}, sessionId);
      if (result.errorText) throw new Error(result.errorText);
      const deadline = Date.now() + 20000;
      while (result.loaderId && !loaded.has(`${sessionId}:${result.loaderId}`)) {
        if (Date.now() > deadline) throw new Error(`Page load timed out: ${url}`);
        await new Promise(resolve => setTimeout(resolve, 75));
      }
    },
    click: async selector => {
      await call("Page.bringToFront", {}, sessionId);
      const {x, y} = await evaluate(`(() => {
        const el = document.querySelector(${JSON.stringify(selector)});
        el.scrollIntoView({block: "center"});
        const rect = el.getBoundingClientRect();
        return {x: rect.x + rect.width / 2, y: rect.y + rect.height / 2};
      })()`);
      await call("Input.dispatchMouseEvent", {type: "mousePressed", x, y, button: "left", clickCount: 1}, sessionId);
      await call("Input.dispatchMouseEvent", {type: "mouseReleased", x, y, button: "left", clickCount: 1}, sessionId);
    },
    fill: (selector, value) => evaluate(`(() => {
      const el = document.querySelector(${JSON.stringify(selector)});
      el.value = ${JSON.stringify(value)};
      el.dispatchEvent(new Event("input", {bubbles: true}));
      el.dispatchEvent(new Event("change", {bubbles: true}));
    })()`),
  };
}

async function wait(page, expression, description) {
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    try { if (await page.evaluate(expression)) return; } catch {}
    await new Promise(resolve => setTimeout(resolve, 75));
  }
  const state = await page.evaluate("({url: location.href, error: document.querySelector('#room-error')?.textContent, body: document.body.innerText.slice(0, 1800)})");
  throw new Error(`Timed out: ${description}\n${JSON.stringify(state)}`);
}

const connected = count => `document.querySelector('#room-participants')?.textContent.includes('${count} connected')`;
let roomURL;
try {
  const host = await tab();
  await host.navigate("/");
  await wait(host, "document.querySelector('#room-panel')?.dataset.ready === 'true'", "workspace runtime");
  await host.click("#open-create-room");
  await wait(host, "document.querySelector('#create-room-dialog')?.open", "create modal");
  assert(await host.evaluate("!!document.querySelector('#sign-in-to-create')"));
  await call("Input.dispatchKeyEvent", {type: "keyDown", key: "Escape", code: "Escape", windowsVirtualKeyCode: 27}, host.sessionId);
  await call("Input.dispatchKeyEvent", {type: "keyUp", key: "Escape", code: "Escape", windowsVirtualKeyCode: 27}, host.sessionId);
  await wait(host, "!document.querySelector('#create-room-dialog').open", "Escape closes modal");
  assert.equal(await host.evaluate("document.activeElement.id"), "open-create-room");
  await host.click("#open-create-room");
  await wait(host, "document.querySelector('#create-room-dialog').open", "reopen modal");
  await host.click("#sign-in-to-create");
  await wait(host, "document.querySelector('#login_form_magic')", "host login");
  await host.navigate("/users/register");
  await wait(host, "document.querySelector('#registration_form') && globalThis.liveSocket?.isConnected()", "registration");
  const email = `rooms-browser-${Date.now()}@example.test`;
  await host.fill('#registration_form input[type="email"]', email);
  await host.click("#registration_form button");
  await wait(host, "location.pathname === '/users/log-in' && document.querySelector('#login_form_magic')", "registration email");
  const mailbox = await fetch(`${app}/dev/mailbox/json`).then(response => response.json());
  const mail = mailbox.data.find(item => item.text_body?.includes(email));
  assert(mail, "local confirmation email");
  const magicURL = mail.text_body.match(/https?:\/\/[^\s]+\/users\/log-in\/[^\s]+/)[0];
  await host.navigate(new URL(magicURL).pathname);
  await wait(host, "document.querySelector('#confirmation_form') && globalThis.liveSocket?.isConnected()", "confirmation page");
  await host.click("#confirmation_form button");
  await wait(host, "document.querySelector('#account-email') && document.querySelector('#room-panel')?.dataset.ready === 'true'", "authenticated workspace");
  await host.click("#open-create-room");
  await wait(host, "document.querySelector('#create-room-dialog')?.open", "authenticated create modal");
  await host.fill("#room-title", "Browser watch party");
  await host.fill("#host-name", "Alex");
  await host.click("#create-room-submit");
  await wait(host, connected(1), "host joined real room");
  await wait(host, "document.querySelector('#invitation-dialog')?.open", "invitation modal");
  assert.equal(await host.evaluate("document.querySelector('#room-name').textContent"), "Browser watch party");
  const invitation = await host.evaluate("document.querySelector('#invitation-link').value");
  roomURL = new URL(invitation).pathname;
  assert(invitation.includes("#invitation="));
  await host.click("#copy-invitation");
  await wait(host, "document.querySelector('#invitation-copy-status').textContent.length > 0", "copy feedback");
  console.log("PASS: signed-in host creates a room and gets a shareable link");

  const guest = await tab();
  await guest.navigate(invitation);
  await wait(guest, "document.querySelector('#join-room-dialog')?.open", "anonymous guest name modal");
  await guest.fill("#guest-name", "Sam");
  await guest.click("#join-room-submit");
  await wait(guest, connected(2), "guest admitted");
  await wait(host, connected(2), "host sees guest");
  assert(await guest.evaluate("!document.querySelector('#account-email')"));
  assert(await host.evaluate("document.querySelector('#room-participants').textContent.includes('Sam')"));
  await host.click("#close-invitation");
  await verifyRoomChat({host, guest, wait, call, roomURL});
  await guest.navigate(roomURL);
  await wait(guest, connected(2), "refresh rejoins the same guest seat");
  console.log("PASS: anonymous invitation admission, live roster and reload");

  const replacement = await tab(guest.context);
  await replacement.navigate(invitation);
  await wait(replacement, "document.querySelector('#join-room-dialog')?.open", "second tab name entry");
  await replacement.fill("#guest-name", "Sam again");
  await replacement.click("#join-room-submit");
  await wait(replacement, connected(2), "shared-browser replacement");
  await wait(guest, "document.querySelector('#room-status').textContent.includes('another tab')", "old tab stopped");
  await replacement.click("#leave-room");
  await wait(replacement, "document.querySelector('#room-status').textContent.includes('left')", "explicit leave");
  await wait(host, connected(1), "guest seat released");
  assert(await host.evaluate("document.querySelector('.room-capacity').textContent.includes('1/5')"));
  console.log("PASS: same-browser tab replacement and immediate explicit leave");

  const bad = await tab();
  await bad.navigate(`${roomURL}#invitation=invalid`);
  await wait(bad, "document.querySelector('#join-room-dialog')?.open", "invalid invitation entry");
  await bad.fill("#guest-name", "Uninvited");
  await bad.click("#join-room-submit");
  await wait(bad, "document.querySelector('#join-room-error').textContent.includes('invalid')", "invalid invitation feedback");
  assert(!await bad.evaluate("!!document.querySelector('#room-participants')"));
  console.log("PASS: invalid invitation is refused");

  const returningHost = await tab(host.context);
  await returningHost.navigate(roomURL);
  await wait(returningHost, "document.querySelector('#join-room-dialog')?.open", "owner reentry without a saved invitation");
  await returningHost.fill("#guest-name", "Alex returns");
  await returningHost.click("#join-room-submit");
  await wait(returningHost, connected(1), "authenticated owner recovery");
  await returningHost.click("#open-invitation");
  await wait(returningHost, "document.querySelector('#invitation-dialog').open && document.querySelector('#replace-invitation')", "lost invitation recovery");
  await returningHost.click("#replace-invitation");
  await wait(returningHost, "document.querySelector('#invitation-link')?.value", "replacement link");
  const newInvitation = await returningHost.evaluate("document.querySelector('#invitation-link').value");
  assert.notEqual(newInvitation, invitation);

  const invited = await tab();
  await invited.navigate(newInvitation);
  await wait(invited, "document.querySelector('#join-room-dialog')?.open", "new invitation entry");
  await invited.fill("#guest-name", "Taylor");
  await invited.click("#join-room-submit");
  await wait(invited, connected(2), "replacement invitation admission");
  const expired = await tab();
  await expired.navigate(invitation);
  await wait(expired, "document.querySelector('#join-room-dialog')?.open", "old invitation entry");
  await expired.fill("#guest-name", "Old link");
  await expired.click("#join-room-submit");
  await wait(expired, "document.querySelector('#join-room-error').textContent.includes('replaced')", "old link revoked");
  console.log("PASS: owner reentry and explicit invitation replacement");

  if (process.env.SCREENSHOT_PATH) {
    const {data} = await call("Page.captureScreenshot", {format: "png"}, returningHost.sessionId);
    await writeFile(process.env.SCREENSHOT_PATH, Buffer.from(data, "base64"));
  }

  const logout = await tab(returningHost.context);
  await logout.navigate("/");
  await wait(logout, "document.querySelector('#room-panel')?.dataset.ready === 'true'", "logout tab");
  await logout.click("#log-out");
  await wait(returningHost, "document.querySelector('#room-status').textContent.includes('sign-in expired')", "logout disconnects idle room socket");
  await wait(invited, connected(1), "guests see host disconnect");
  console.log("PASS: logout in another tab ends idle authenticated membership");
  assert.deepEqual(exceptions, [], "no uncaught browser exceptions");
  console.log(`PASS: browser flow complete (${version.Browser})`);
} finally {
  if (exceptions.length) console.error("Browser exceptions:", exceptions);
  for (const browserContextId of contexts) await call("Target.disposeBrowserContext", {browserContextId});
  ws.close();
}
