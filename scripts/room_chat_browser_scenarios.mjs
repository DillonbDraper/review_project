import assert from "node:assert/strict";
import {writeFile} from "node:fs/promises";

export async function verifyRoomChat({host, guest, wait, call, roomURL}) {
  const connected = "document.querySelector('#chat-panel')?.dataset.connected === 'true'";
  const contains = text => `[...document.querySelectorAll('#chat-messages .chat-message p')].filter(el => el.textContent === ${JSON.stringify(text)}).length === 1`;
  const send = async (page, text) => {
    await page.fill("#chat-draft", text);
    await page.click("#send-message");
    await wait(page, contains(text), "message acknowledged exactly once");
    await wait(page, "document.querySelector('#chat-draft').value === '' && !document.querySelector('#send-message').disabled", "sent draft cleared");
  };

  await wait(host, connected, "host chat connected");
  await wait(guest, connected, "guest chat connected");
  const first = "A shared thought <script>window.untrustedChat = true</script> 👋";
  await send(host, first);
  await wait(guest, contains(first), "host message received by guest");
  assert(await guest.evaluate("document.querySelector('#chat-messages strong').textContent === 'Alex'"));
  assert(await guest.evaluate("!document.querySelector('#chat-messages script') && !globalThis.untrustedChat"));
  await send(guest, "A reply from Sam");
  await wait(host, contains("A reply from Sam"), "guest reply received by host");
  const ids = await guest.evaluate("[...document.querySelectorAll('#chat-messages .chat-message')].map(el => el.id)");
  console.log("PASS: shared chat in both directions, trusted names, escaped text and no duplicate echo");

  await guest.fill("#chat-draft", "😀é");
  await wait(guest, "document.querySelector('#chat-draft-count').textContent === '3 / 2000'", "Unicode character counter");
  await guest.fill("#chat-draft", "x".repeat(2001));
  await wait(guest, "document.querySelector('#send-message').disabled", "oversized message blocked");
  await guest.fill("#chat-draft", "");
  await guest.click("#send-message");
  await wait(guest, "document.querySelector('#chat-error').textContent.includes('Write a message')", "blank message rejected");
  assert.equal(await guest.evaluate("document.querySelectorAll('#chat-messages .chat-message').length"), 2);

  await guest.navigate(roomURL);
  await wait(guest, connected, "chat rejoins after reload");
  await wait(guest, contains(first), "durable history restored");
  assert.deepEqual(await guest.evaluate("[...document.querySelectorAll('#chat-messages .chat-message')].map(el => el.id)"), ids);
  console.log("PASS: validation, Unicode count and durable chat after reload");

  // Hold just this request at the real browser transport. Reload must retain
  // uncertainty even when pagehide happens before an acknowledgement or timeout.
  await guest.evaluate(`(() => {
    const socket = [...globalThis.__testSockets].find(ws => ws.url.includes('/room-socket/'));
    const send = socket.send.bind(socket);
    socket.send = data => { if (!String(data).includes('"chat_send"')) send(data); };
  })()`);
  await guest.fill("#chat-draft", "Unconfirmed across reload");
  await guest.click("#send-message");
  await wait(guest, "document.querySelector('#send-message').disabled", "unconfirmed request pending");
  await guest.navigate(roomURL);
  await wait(guest, connected, "rejoin after unconfirmed request");
  await wait(guest, "document.querySelector('#chat-error').textContent.includes('may have been sent')", "uncertainty retained across reload");
  assert(!await host.evaluate(contains("Unconfirmed across reload")));
  assert(!await guest.evaluate(contains("Unconfirmed across reload")));
  console.log("PASS: reload retains uncertain delivery without replaying the message");

  await guest.fill("#chat-draft", "Keep this unsent draft");
  await call("Network.enable", {}, guest.sessionId);
  await call("Network.emulateNetworkConditions", {offline: true, latency: 0, downloadThroughput: 0, uploadThroughput: 0}, guest.sessionId);
  await guest.evaluate("[...globalThis.__testSockets].filter(ws => ws.url.includes('/room-socket/')).forEach(ws => ws.close(4000, 'test connection interruption'))");
  await wait(guest, "document.querySelector('#chat-draft').disabled", "composer disabled on disconnect");
  await send(host, "Sent while Sam reconnects");
  assert.equal(await guest.evaluate("document.querySelector('#chat-draft').value"), "Keep this unsent draft");
  await call("Network.emulateNetworkConditions", {offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1}, guest.sessionId);
  await wait(guest, connected, "chat reconnects");
  await wait(guest, contains("Sent while Sam reconnects"), "history catches up missed messages");
  assert.equal(await guest.evaluate("document.querySelector('#chat-draft').value"), "Keep this unsent draft");
  await send(guest, "Keep this unsent draft");
  await wait(host, contains("Keep this unsent draft"), "preserved draft sends after reconnect");
  console.log("PASS: real socket interruption, disabled sending, preserved draft and history catch-up");

  const initialCount = await host.evaluate("document.querySelectorAll('#chat-messages .chat-message').length");
  for (let i = 1; i <= 300; i++) await send(host, `History sample ${i}`);
  const began = Date.now();
  await guest.navigate(roomURL);
  await wait(guest, connected, "full history rejoin");
  await wait(guest, `document.querySelectorAll('#chat-messages .chat-message').length === ${initialCount + 300}`, "entire conversation loaded without paging");
  console.log(`PASS: loaded all ${initialCount + 300} messages after navigation in ${Date.now() - began} ms`);
  assert(await guest.evaluate(contains(first)));
  assert(!await guest.evaluate("document.querySelector('#chat-load-older, #chat-load-latest, #chat-history-controls')"));
  const readingPosition = await guest.evaluate(`(() => {
    const log = document.querySelector('#chat-messages');
    log.scrollTop = Math.floor(log.scrollHeight / 2);
    return log.scrollTop;
  })()`);
  await send(host, "New message while reading the conversation");
  await wait(guest, contains("New message while reading the conversation"), "new message appended while reading");
  assert(Math.abs(await guest.evaluate("document.querySelector('#chat-messages').scrollTop") - readingPosition) < 2);
  const sequences = await guest.evaluate("[...document.querySelectorAll('#chat-messages .chat-message')].map(el => Number(el.dataset.sequence))");
  assert.equal(new Set(sequences).size, sequences.length);
  assert.deepEqual(sequences, [...sequences].sort((a, b) => a - b));
  assert.equal(sequences.length, initialCount + 301);
  assert.equal(sequences[0], 1);
  console.log("PASS: continuous ordered conversation keeps all messages and preserves reading position");

  await guest.click("#workspace-home");
  await wait(guest, "location.pathname === '/' && document.querySelector('#room-panel')?.dataset.ready === 'true'", "leave room page for home");
  await guest.evaluate("history.back()");
  await wait(guest, connected, "history navigation restores live membership");
  await wait(guest, contains("New message while reading the conversation"), "restored page has current chat");
  await send(guest, "Back in the conversation");
  await wait(host, contains("Back in the conversation"), "restored page sends through live transport");
  console.log("PASS: navigation away and back restores a working conversation");
  if (process.env.CHAT_SCREENSHOT_PATH) {
    const {data} = await call("Page.captureScreenshot", {format: "png"}, guest.sessionId);
    await writeFile(process.env.CHAT_SCREENSHOT_PATH, Buffer.from(data, "base64"));
  }
}
