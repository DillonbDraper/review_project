import assert from "node:assert/strict";
import {writeFile, readFile, rename} from "node:fs/promises";

const active = "__rtcPeers.filter(pc => pc.connectionState !== 'closed')";
const pressed = kind => `document.querySelector('#conference-${kind}')?.getAttribute('aria-pressed') === 'true'`;

async function toggle(page, kind, enabled, wait) {
  if ((await page.evaluate(pressed(kind))) !== enabled) await page.click(`#conference-${kind}`);
  await wait(page, `${pressed(kind)} === ${enabled}`, `${kind} ${enabled ? "enabled" : "disabled"}`);
}

async function receiving(page, kind, wait) {
  if (page.activate) await page.activate();
  // The product's video elements must consume and display the decoded frames.
  // An auxiliary test sink could hide a broken stream-to-tile binding.
  const sample = `(async () => {
    const reports = (await Promise.all(${active}.map(pc => pc.getStats())))
      .flatMap(reports => [...reports.values()]);
    const rtp = reports.filter(report => report.type === 'inbound-rtp' && report.kind === '${kind}')
      .reduce((total, report) => ({bytes: total.bytes + report.bytesReceived,
        frames: total.frames + (report.framesDecoded || 0)}), {bytes: 0, frames: 0});
    const displayed = [...document.querySelectorAll('.conference-tile[data-local="false"][data-video="true"] video')]
      .filter(video => video.srcObject && !video.paused && getComputedStyle(video).visibility === 'visible')
      .reduce((frames, video) => {
        if (video.requestVideoFrameCallback && !video.__frameObserver) {
          video.__frameObserver = true;
          video.__presentedFrames = 0;
          const presented = () => { video.__presentedFrames++; video.requestVideoFrameCallback(presented); };
          video.requestVideoFrameCallback(presented);
        }
        return frames + Math.max(video.getVideoPlaybackQuality().totalVideoFrames, video.__presentedFrames || 0);
      }, 0);
    return {...rtp, displayed};
  })()`;
  const before = await page.evaluate(sample);
  await wait(page, `${sample}.then(sample => sample.bytes > ${before.bytes} &&
    ('${kind}' !== 'video' || (sample.frames > ${before.frames} && sample.displayed > ${before.displayed})))`, `advancing incoming ${kind} RTP${kind === "video" ? " and displayed tile frames" : ""}`);
}

async function blackTiles(page, count, wait) {
  await wait(page, `document.querySelectorAll('.conference-tile').length === ${count} &&
    [...document.querySelectorAll('.conference-tile')].every(tile => tile.dataset.video === 'false' &&
      getComputedStyle(tile).backgroundColor === 'rgb(0, 0, 0)' &&
      getComputedStyle(tile.querySelector('.conference-media')).visibility === 'hidden')`, "named black participant tiles");
}

async function localPreview(page, enabled, wait) {
  await wait(page, `(() => {
    const tile = document.querySelector('.conference-tile[data-local="true"]');
    const video = tile?.querySelector('video');
    return tile?.dataset.video === '${enabled}' && video?.muted && video.playsInline &&
      (${enabled} ? video.srcObject && !video.paused && video.videoWidth > 0 : !video.srcObject);
  })()`, `muted local preview ${enabled ? "playing" : "cleared"}`);
}

export async function verifyRoomConference({host, guest, wait}) {
  for (const page of [host, guest]) {
    await wait(page, `${active}.length === 1 && ${active}[0].connectionState === 'connected'`, "receive-only peer connection");
    assert.equal(await page.evaluate("__captureCalls.length"), 0, "joining never requests devices");
    assert.equal(await page.evaluate(pressed("microphone")), false);
    assert.equal(await page.evaluate(pressed("camera")), false);
    await blackTiles(page, 2, wait);
    assert(await page.evaluate(`(() => {
      const tiles = [...document.querySelectorAll('.conference-tile')];
      const panel = document.querySelector('#conference-panel').getBoundingClientRect();
      const player = document.querySelector('#video-panel').getBoundingClientRect();
      return document.querySelectorAll('.conference-you').length === 1 && panel.bottom <= player.top &&
        tiles.every(tile => { const box = tile.getBoundingClientRect(); return Math.abs(box.width - box.height) < 1 && box.width < player.width / 2; });
    })()`), "square tiles include self and sit above the review player");
  }
  console.log("PASS: two receive-only participants connect without asking for devices");

  await host.evaluate("__captureModes.audio = 'NotAllowedError'; __captureModes.video = 'NotFoundError'");
  await host.click("#conference-microphone");
  await host.click("#conference-camera");
  await wait(host, "document.querySelector('#conference-microphone-error').textContent.includes('denied') && document.querySelector('#conference-camera-error').textContent.includes('not found')", "independent permission and missing-device feedback");
  assert(await host.evaluate("!document.querySelector('#chat-draft').disabled && !!document.querySelector('#leave-room')"));
  await toggle(guest, "microphone", true, wait);
  await toggle(guest, "camera", true, wait);
  await localPreview(guest, true, wait);
  await receiving(host, "audio", wait);
  await receiving(host, "video", wait);
  assert.equal(await host.evaluate("__rtcTracks.length"), 0, "a participant with neither device receives both kinds of media");
  await wait(host, "document.querySelector('#conference-enable-audio') || [...document.querySelectorAll('#conference-audio audio')].some(audio => !audio.paused)", "receive-only audio playback or unlock action");
  if (await host.evaluate("!!document.querySelector('#conference-enable-audio')")) await host.click("#conference-enable-audio");
  await wait(host, "[...document.querySelectorAll('#conference-audio audio')].some(audio => !audio.paused)", "remote audio plays without local capture permission");
  await toggle(guest, "camera", false, wait);
  await localPreview(guest, false, wait);
  await wait(host, "[...document.querySelectorAll('.conference-tile[data-local=false]')].every(tile => tile.dataset.video === 'false' && !tile.querySelector('video').srcObject)", "remote camera-off clears the displayed frame");
  await receiving(host, "audio", wait);
  await guest.evaluate("__captureModes.video = 'NotReadableError'");
  await guest.click("#conference-camera");
  await wait(guest, "document.querySelector('#conference-camera-error').textContent.includes('in use')", "busy camera preserves working microphone");
  await guest.evaluate("__captureModes.video = 'real'");
  console.log("PASS: denied devices still receive advancing audio/video and can play room audio");

  await host.evaluate("__captureModes.audio = 'pending'; __captureModes.video = 'real'");
  await host.click("#conference-microphone");
  await wait(host, "document.querySelector('#conference-microphone').textContent.includes('Cancel')", "unanswered microphone permission");
  await toggle(host, "camera", true, wait);
  await toggle(guest, "microphone", true, wait);
  await receiving(host, "audio", wait);
  await receiving(guest, "video", wait);
  await host.click("#conference-microphone");
  await wait(host, "document.querySelector('#conference-microphone').textContent.includes('Turn on')", "cancel pending microphone request");
  console.log("PASS: pending or failed capture preserves reception and the other device");

  await host.evaluate("__captureModes.audio = 'real'");
  await toggle(host, "camera", false, wait);
  await toggle(guest, "microphone", false, wait);
  await toggle(host, "microphone", true, wait);
  await toggle(guest, "camera", true, wait);
  await receiving(host, "video", wait);
  await receiving(guest, "audio", wait);
  console.log("PASS: microphone-only and camera-only participants exchange media in both directions");

  await toggle(host, "camera", true, wait);
  await toggle(guest, "microphone", true, wait);
  for (const page of [host, guest]) {
    await receiving(page, "audio", wait);
    await receiving(page, "video", wait);
    await wait(page, `document.querySelector('#conference-enable-audio') ||
      [...document.querySelectorAll('#conference-audio audio')].some(audio => !audio.paused)`, "remote audio playback or an explicit unlock action");
    if (await page.evaluate("!!document.querySelector('#conference-enable-audio')")) {
      await page.click("#conference-enable-audio");
      await wait(page, "!document.querySelector('#conference-enable-audio')", "gesture unlocks room audio without capture dependency");
    }
    assert.equal(await page.evaluate(`${active}.length`), 1, "device changes preserve the peer connection");
    assert.equal(await page.evaluate("document.querySelector('#conference-error').textContent"), "");
  }
  console.log("PASS: enabling both devices after receive-only join preserves bidirectional media and audio playback");

  // Hold only conference signaling so both native endpoints have made an
  // offer before either receives the other's. This exercises real offer glare.
  for (const page of [host, guest]) {
    await page.evaluate(`(() => {
      const socket = [...__testSockets].find(ws => ws.url.includes('/room-socket/'));
      const send = socket.send.bind(socket), held = [];
      socket.send = data => String(data).includes('"conference_signal"') ? held.push(data) : send(data);
      globalThis.__releaseConferenceSignals = () => {
        socket.send = send;
        for (const data of held) send(data);
      };
      ${active}[0].restartIce();
    })()`);
  }
  for (const page of [host, guest]) await wait(page, `${active}[0].signalingState === 'have-local-offer'`, "simultaneous local offers");
  for (const page of [host, guest]) await page.evaluate("__releaseConferenceSignals()");
  try {
    for (const page of [host, guest]) {
      await wait(page, `${active}[0].signalingState === 'stable' && ${active}[0].connectionState === 'connected'`, "offer collision resolved");
      await receiving(page, "audio", wait);
      await receiving(page, "video", wait);
      assert.equal(await page.evaluate("document.querySelector('#conference-error').textContent"), "");
    }
  } catch (error) {
    for (const [name, page] of [["host", host], ["guest", guest]]) {
      console.error(name, await page.evaluate(`(async () => {
        const pc = ${active}[0];
        if (!pc) return {state: 'no active peer'};
        return {state: pc.connectionState, signaling: pc.signalingState,
          rtp: [...(await pc.getStats()).values()]
            .filter(item => ['inbound-rtp', 'outbound-rtp', 'media-source'].includes(item.type))
            .map(item => ({type: item.type, kind: item.kind, bytesReceived: item.bytesReceived,
              bytesSent: item.bytesSent, frames: item.frames, framesEncoded: item.framesEncoded,
              framesDecoded: item.framesDecoded}))};
      })()`));
    }
    throw error;
  }
  console.log("PASS: simultaneous native offers resolve without one-way media or replacing the peer");

  for (const page of [host, guest]) {
    await toggle(page, "microphone", false, wait);
    await toggle(page, "camera", false, wait);
    await wait(page, "__rtcTracks.every(track => track.readyState === 'ended')", "disabling devices releases all local capture");
    assert.equal(await page.evaluate(`${active}.length`), 1, "receive-only connection remains after devices stop");
  }
  for (const page of [host, guest]) await blackTiles(page, 2, wait);
}

export async function verifyConferenceMesh({host, guest, observer, others, wait, call}) {
  const participants = [host, guest, observer, ...others];
  for (const page of participants) {
    await wait(page, `${active}.length === 4 && ${active}.every(pc => pc.connectionState === 'connected')`, "five-participant mesh");
    await blackTiles(page, 5, wait);
    await page.evaluate(`globalThis.__participantVideos = new Map([...document.querySelectorAll('.conference-tile')]
      .map(tile => [tile.dataset.seatId, tile.querySelector('video')]))`);
  }
  await toggle(host, "microphone", true, wait);
  await toggle(host, "camera", true, wait);
  for (const page of [guest, observer, ...others]) {
    await receiving(page, "audio", wait);
    await receiving(page, "video", wait);
  }
  await guest.evaluate(`(() => {
    const tile = document.querySelector('.conference-tile[data-local="false"][data-video="true"]');
    globalThis.__releasedVideo = {seat: tile.dataset.seatId, element: tile.querySelector('video')};
    ReviewConferenceNative.close('view:' + tile.dataset.seatId);
    Hologram.dispatchAction('sync_tiles', 'conference-panel');
  })()`);
  await wait(guest, `(() => {
    const video = document.querySelector('#conference-media-' + __releasedVideo.seat + ' video');
    return video && video !== __releasedVideo.element && video.srcObject && !video.paused;
  })()`, "restored tile recreates a released native video handle");
  await receiving(guest, "video", wait);
  await guest.evaluate("__participantVideos.set(__releasedVideo.seat, document.querySelector('#conference-media-' + __releasedVideo.seat + ' video'))");
  if (process.env.CONFERENCE_SCREENSHOT_PATH) {
    const {data} = await call("Page.captureScreenshot", {format: "png"}, guest.sessionId);
    await writeFile(process.env.CONFERENCE_SCREENSHOT_PATH, Buffer.from(data, "base64"));
  }
  assert(await guest.evaluate(`(() => {
    const boxes = [...document.querySelectorAll('.conference-tile')].map(tile => tile.getBoundingClientRect());
    return boxes.length === 5 && boxes.every(box => Math.abs(box.top - boxes[0].top) < 1);
  })()`), "five square tiles fit in a row on a wide desktop");
  await call("Emulation.setDeviceMetricsOverride", {width: 900, height: 1100, deviceScaleFactor: 1, mobile: false}, guest.sessionId);
  await wait(guest, `(() => {
    const boxes = [...document.querySelectorAll('.conference-tile')].map(tile => tile.getBoundingClientRect());
    return boxes.some(box => box.top > boxes[0].top + 1) &&
      boxes.every(box => Math.abs(box.width - box.height) < 1 && Math.abs(box.width - boxes[0].width) < 1) &&
      document.documentElement.scrollWidth <= 900;
  })()`, "equal square tiles wrap without overflowing a narrow desktop");
  await call("Emulation.setDeviceMetricsOverride", {width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false}, guest.sessionId);
  await observer.click("#leave-room");
  await wait(observer, "__rtcPeers.every(pc => pc.connectionState === 'closed')", "third participant releases its peers");
  for (const page of [host, guest, ...others]) {
    await wait(page, `${active}.length === 3`, "departed participant is removed from the mesh");
    await wait(page, "document.querySelectorAll('.conference-tile').length === 4", "departed tile is removed");
    assert(await page.evaluate("[...document.querySelectorAll('.conference-tile')].every(tile => __participantVideos.get(tile.dataset.seatId) === tile.querySelector('video'))"), "remaining participant video nodes survive roster changes");
  }
  await wait(observer, "!document.querySelector('.conference-tile') && !document.querySelector('#conference-audio audio')", "leaving clears all tiles and playback resources");
  for (const page of others) await page.click("#leave-room");
  for (const page of [host, guest]) await wait(page, `${active}.length === 1 && document.querySelectorAll('.conference-tile').length === 2`, "additional tiles and peers are removed");
  assert(await host.evaluate("__rtcTracks.filter(track => track.readyState === 'live').length === 2"), "closing one peer preserves shared local devices");
  await receiving(guest, "audio", wait);
  await receiving(guest, "video", wait);
  await toggle(host, "microphone", false, wait);
  await toggle(host, "camera", false, wait);
  console.log("PASS: five-participant mesh, responsive square tiles, and stable video nodes through middle-seat removal");
}


export async function verifyConferenceRecovery({host, guest, observer, wait}) {
  for (const page of [host, guest, observer]) await wait(page,
    `${active}.length === 2 && ${active}.every(pc => pc.connectionState === 'connected')`, "three-way recovery fixture");
  for (const page of [host, guest]) {
    await toggle(page, "microphone", true, wait);
    await toggle(page, "camera", true, wait);
    await page.evaluate(`Hologram.dispatchAction('video_loaded', 'video-panel', {video_id: 'M7lc1UVf-VE', embed_url: 'about:blank'})`);
    await wait(page, "document.querySelector('#youtube-player')", "review iframe before recovery");
    await page.evaluate(`globalThis.__recoveryPlayer = document.querySelector('#youtube-player');
      globalThis.__recoveryTracks = __rtcTracks.filter(track => track.readyState === "live");
      globalThis.__otherConnection = ${active}[1];`);
  }
  await host.evaluate(`(() => {
    const pc = ${active}[0];
    globalThis.__failedPeer = pc;
    pc.close(); pc.__testFailed = true;
    pc.dispatchEvent(new Event('connectionstatechange'));
  })()`);
  await wait(host, `__failedPeer.connectionState === 'closed' && ${active}.length === 2 && ${active}.every(pc => pc.connectionState === 'connected')`, "failed pair is replaced after ICE restart");
  assert(await host.evaluate("__otherConnection.connectionState === 'connected' && __rtcPeers.includes(__otherConnection)"), "unaffected peer remains connected");
  for (const page of [host, guest]) {
    assert(await page.evaluate("__recoveryTracks.every(track => track.readyState === 'live') && __recoveryPlayer === document.querySelector('#youtube-player')"), "pair replacement preserves capture and player");
    await receiving(page, "audio", wait);
    await receiving(page, "video", wait);
  }
  console.log("PASS: failed peer gets coordinated replacement while capture, other peers, and review player survive");

  // Blackhole only this pair's outbound signaling to exercise the bounded
  // failure path. The third participant's connection must remain intact.
  const target = await guest.evaluate("document.querySelector('.conference-tile[data-local=true]').dataset.seatId");
  await host.evaluate(`(() => {
    const ws = [...__testSockets].find(ws => ws.url.includes('/room-socket/'));
    const send = ws.send.bind(ws);
    ws.send = data => {
      const message = JSON.parse(data);
      if (message[3] !== 'conference_signal' || message[4]?.to !== ${JSON.stringify(target)}) send(data);
    };
    globalThis.__restoreSignals = () => { ws.send = send; };
    const pc = ${active}.find(pc => pc !== __otherConnection); pc.close(); pc.__testFailed = true;
    pc.dispatchEvent(new Event('connectionstatechange'));
  })()`);
  await wait(host, "!!document.querySelector('#conference-retry')", "unreachable pair stops automatic recovery and offers retry");
  assert(await host.evaluate("__otherConnection.connectionState === 'connected'"));
  await host.evaluate("__restoreSignals()");
  await host.click("#conference-retry");
  await wait(host, `${active}.length === 2 && ${active}.every(pc => pc.connectionState === 'connected') && !document.querySelector('#conference-retry')`, "explicit retry restores the pair");
  await receiving(guest, "video", wait);
  console.log("PASS: unreachable pair exhausts bounded recovery and explicit retry restores media");

  await guest.fill("#chat-draft", "Draft survives signaling recovery");
  await guest.evaluate(`(() => {
    globalThis.__beforeOutageTracks = __rtcTracks.slice();
    [...__testSockets].find(ws => ws.url.includes('/room-socket/')).close();
  })()`);
  await wait(guest, "__beforeOutageTracks.every(track => track.readyState === 'ended')", "signaling loss immediately stops old capture");
  await wait(guest, `${pressed("camera")} && ${pressed("microphone")} && ${active}.length === 2 && ${active}.every(pc => pc.connectionState === 'connected')`, "same-page rejoin restores enabled devices");
  assert(await guest.evaluate("__recoveryPlayer === document.querySelector('#youtube-player') && document.querySelector('#chat-draft').value === 'Draft survives signaling recovery'"), "outage preserves player and chat draft");
  await receiving(host, "video", wait);
  await receiving(guest, "audio", wait);
  await guest.evaluate(`__captureModes.audio = 'NotAllowedError'; [...__testSockets].find(ws => ws.url.includes('/room-socket/')).close()`);
  await wait(guest, `document.querySelector('#conference-microphone-error').textContent.includes('denied') && ${pressed("camera")} && !(${pressed("microphone")}) && document.querySelector('#room-participants')?.textContent.includes('3 connected')`, "resume failure leaves participant joined and other device working");
  await guest.evaluate("__captureModes.audio = 'real'");
  await toggle(guest, "microphone", true, wait);
  await receiving(host, "audio", wait);
  await guest.fill("#chat-draft", "");
  for (const page of [host, guest]) {
    await toggle(page, "microphone", false, wait);
    await toggle(page, "camera", false, wait);
  }
  console.log("PASS: same-page signaling recovery releases and reacquires devices; denied resume is independent and retryable");
}

export async function verifyCredentialRenewal({host, guest, wait, mode}) {
  const selected = `(async () => {
    const pc = ${active}.find(pc => pc.connectionState === 'connected') || ${active}[0];
    if (!pc) return {};
    const reports = await pc.getStats();
    const transport = [...reports.values()].find(r => r.type === 'transport' && r.selectedCandidatePairId);
    const pair = reports.get(transport?.selectedCandidatePairId) || [...reports.values()].find(r => r.type === 'candidate-pair' && r.state === 'succeeded' && r.nominated);
    const local = reports.get(pair?.localCandidateId), remote = reports.get(pair?.remoteCandidateId);
    return {local: local?.candidateType, remote: remote?.candidateType, relayProtocol: local?.relayProtocol, port: local?.port, remotePort: remote?.port, address: local?.address, remoteAddress: remote?.address};
  })()`;
  for (const page of [host, guest]) {
    await wait(page, `${selected}.then(pair => pair.local === 'relay')`, "selected relay path");
    const pair = await page.evaluate(selected);
    assert.equal(pair.local, 'relay');
    assert(['relay', 'prflx'].includes(pair.remote));
    if (pair.remote === 'prflx') {
      const opposite = await (page === host ? guest : host).evaluate(selected);
      assert.equal(pair.remotePort, opposite.port);
      assert.equal(pair.remoteAddress, opposite.address);
    }
    assert.equal(pair.relayProtocol, mode === 'tls' ? 'tls' : mode);
  }
  await toggle(host, "microphone", true, wait);
  await toggle(host, "camera", true, wait);
  await host.evaluate("(() => { globalThis.__renewStart = Date.now(); globalThis.__renewCount = __rtcConfigUpdates.length; })()");
  // Short local TTL is 60 seconds. Keep media flowing through more than two TTLs.
  for (let cycle = 0; cycle < 5; cycle++) {
    await receiving(guest, "audio", wait);
    await receiving(guest, "video", wait);
    const port = (await host.evaluate(selected)).port;
    const count = await host.evaluate("__rtcConfigUpdates.length");
    await wait(host, `__rtcConfigUpdates.length > ${count}`, "temporary relay credentials renew");
    await wait(host, `${selected}.then(pair => pair.local === 'relay' && pair.port !== ${port})`, "renewal selects a replacement relay allocation");
    await receiving(guest, "audio", wait);
    await receiving(guest, "video", wait);
    console.log(`PASS: ${mode} relay credential renewal ${cycle + 1}/5 with replacement allocation`);
  }
  assert(await host.evaluate("Date.now() - __renewStart > 120000 && __rtcConfigUpdates.length >= __renewCount + 5"));
  await receiving(guest, "audio", wait);
  await receiving(guest, "video", wait);
  assert.equal((await guest.evaluate(selected)).local, "relay");
  for (const page of [host, guest]) assert.equal(await page.evaluate("document.querySelector('#conference-network-error').textContent"), "");
  if (process.env.TURN_FAILURE_TEST === "1") {
    assert(["localhost", "127.0.0.1"].includes(new URL(process.env.APP_URL).hostname));
    const config = JSON.parse(await readFile(process.env.TURN_TEST_CONFIG, "utf8"));
    assert(config.secret_file.startsWith("/tmp/"), "fault injection requires an isolated temporary secret");
    await rename(config.secret_file, config.secret_file + ".held");
    try {
      await host.evaluate("Hologram.dispatchAction('retry_call', 'conference-panel')");
      await wait(host, "document.querySelector('#conference-network-error').textContent.length > 0 && !!document.querySelector('#conference-retry')", "credential failure offers retry without ending the room");
      await receiving(guest, "audio", wait);
      await receiving(guest, "video", wait);
    } finally { await rename(config.secret_file + ".held", config.secret_file); }
    await host.click("#conference-retry");
    await wait(host, "!document.querySelector('#conference-network-error').textContent", "credential retry recovers");
    await receiving(guest, "video", wait);
    console.log("PASS: credential failure preserves media and room; retry restores renewal");
  }
  await toggle(host, "microphone", false, wait);
  await toggle(host, "camera", false, wait);
  console.log(`PASS: forced ${mode} relay carries media over multiple credential lifetimes`);
}
