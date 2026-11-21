import {Socket} from "../../../../deps/phoenix/priv/static/phoenix.mjs";
import {loadAPI, videoId, playerError} from "./youtube_probe.mjs";
import {targetPosition, newerSnapshot, correction, playbackStatus} from "./youtube_sync_policy.mjs";
import {MeshSession} from "./mesh_probe.mjs";
import {ManualTest} from "./mesh_manual.mjs";
import {bootstrapAccess, watchAccessAuth} from "./room_access_auth.mjs";

import {NativeIntent} from "./youtube_native_policy.mjs";

export {watchAccessAuth};

const sessions = new Map();
let lastManual;
let pendingAccess;
const states = {"-1": "unstarted", 0: "ended", 1: "playing", 2: "paused", 3: "buffering", 5: "cued"};

export class SyncSession {
  constructor(id, room, token, access = null) {
    this.id = id;
    this.room = room;
    this.token = token;
    this.access = access;
    this.host = document.getElementById("sync-player");
    this.role = "joining";
    this.connected = false;
    this.ready = false;
    this.enabled = false;
    this.blocked = false;
    this.disposed = false;
    this.error = "";
    this.playerError = "";
    this.video = "";
    this.pendingVideo = null;
    this.offset = 0;
    this.rtt = 0;
    this.bestRtt = Infinity;
    this.lastSeek = -Infinity;
    this.lastTransport = -Infinity;
    this.corrections = 0;
    this.accepted = 0;
    this.ignored = 0;
    this.commands = Promise.resolve();
    this.lag = 0;
    this.delays = new Set();
    this.manualMode = !!document.getElementById("mesh-manual-panel");
    // Hologram removes queries during initialization. Navigation Timing retains
    // the document's original URL even if history.replaceState has already run.
    const navigationURL = performance.getEntriesByType("navigation")[0]?.name || location.href;
    this.iceMode = new URL(navigationURL).searchParams.get("ice") || document.getElementById("manual-ice-mode")?.value || "direct";
    const options = new URL(navigationURL).searchParams;
    // Opt in only on spike 2; preserve historical ownership/mesh experiments.
    this.nativeControls = !access && options.get("native_controls") === "1";
    this.tightSync = options.get("tight_sync") === "1";
    this.native = new NativeIntent();
    this.nativeCommands = 0;
    this.nativeInFlight = false;
    this.trace = [];
    this.host.syncTrace = () => this.trace.slice();
    this.host.syncSample = () => this.sample();
    this.onPageHide = () => this.dispose();
    this.onVisibility = () => { if (!document.hidden) this.refresh(); };
    globalThis.addEventListener("pagehide", this.onPageHide);
    document.addEventListener("visibilitychange", this.onVisibility);
    this.observer = new MutationObserver(() => { if (!this.host.isConnected) this.dispose(); });
    this.observer.observe(document.documentElement, {childList: true, subtree: true});
  }

  sample() {
    const now = performance.now();
    const position = this.ready ? this.player.getCurrentTime() : 0;
    const duration = this.ready ? this.player.getDuration() : 0;
    const expected = this.desired ? targetPosition(this.desired, now, this.offset) : 0;
    const state = this.ready ? this.player.getPlayerState() : -1;
    return {
      native_controls: this.nativeControls, native_commands: this.nativeCommands, tight_sync: this.tightSync,
      room: this.room, role: this.role, connected: this.connected, ready: this.ready,
      enabled: this.enabled, blocked: this.blocked, state: states[state] || "loading",
      video: this.video, actual_video: this.ready ? this.player.getVideoData()?.video_id || "" : "",
      desired_video: this.desired?.video_id || "", playing: this.desired?.playing || false,
      revision: this.desired?.revision ?? -1, position, duration, expected,
      drift: position - expected, sampled_at_ms: now, rtt_ms: this.rtt,
      corrections: this.corrections, accepted: this.accepted, ignored: this.ignored,
      error: this.error || this.playerError, pending_video: !!this.pendingVideo,
      injected_one_way_delay_ms: this.lag,
      mesh: this.mesh?.snapshot() || null,
      access: this.desired?.access ? {...this.desired.access, can_control: this.canControl()} : null,
    };
  }

  emit() {
    if (this.disposed) return;
    const sample = this.sample();
    this.manual?.render(sample);
    const status = this.access && sample.ready && sample.enabled && !sample.playing && !sample.error ?
      (this.canControl() ? "The room is paused. You control playback: press Play for everyone." : "The room is paused. Waiting for the current playback controller.") : playbackStatus(sample);
    const access = this.desired?.access;
    const controller = access?.seats.find(seat => seat.id === access.controller_identity);
    const summary = access ? `${access.connected_count} connected · ${access.seat_count}/5 seats occupied or reserved · Owner ${access.owner_present ? "present" : "absent"} · Playback: ${controller?.name || "waiting for the 10-second handoff"}.` : "";
    this.host.dataset.resources = "1";
    globalThis.Hologram?.dispatchAction("sync_event", "page", {
      room: this.room, role: this.role, status, error: sample.error,
      ready: this.ready, connected: this.connected, enabled: this.enabled,
      sample: JSON.stringify(this.manualMode ? {room: sample.room, state: sample.state, drift: sample.drift,
        rtt_ms: sample.rtt_ms, corrections: sample.corrections} : sample),
      can_control: this.canControl(), access_summary: summary,
      invite: this.access ? `${location.origin}/dev/spikes/room-access/room/${this.room}/${encodeURIComponent(this.access.invitation)}${this.iceMode === "direct" ? "" : `?ice=${encodeURIComponent(this.iceMode)}`}` : `${location.origin}/dev/spikes/${this.manualMode ? "youtube-mesh-manual" : this.mesh ? "youtube-mesh" : "youtube-sync"}/room/${this.room}${this.iceMode === "direct" ? "" : `?ice=${encodeURIComponent(this.iceMode)}`}`,
    });
  }

  canControl() {
    return this.connected && (this.access ? !!this.mesh?.selfId && this.desired?.access?.controller_identity === this.mesh.selfId : this.role === "host");
  }

  async connect() {
    this.socket = new Socket(this.access ? "/dev/spikes/room-access-socket" : "/dev/spikes/youtube-sync-socket",
      this.access ? {params: {_csrf_token: this.access.csrf_token}} : {});
    this.socket.onClose(() => this.connectionLost());
    this.channel = this.socket.channel(`${this.access ? "room_access" : "youtube_sync"}:${this.room}`,
      this.access ? {invitation: this.access.invitation, display_name: this.access.name, ice_mode: this.iceMode} : {host_token: this.token, ice_mode: this.iceMode});
    this.channel.on("seat_replaced", () => {
      this.connectionLost(); this.mesh?.stop(); this.socket.disconnect();
      this.error = "This browser's seat moved to another tab. Join here to move it back.";
      this.emit();
    });
    if (document.getElementById("mesh-panel")) {
      this.mesh = new MeshSession(this.channel, () => this.emit(), {manual: this.manualMode});
      if (this.manualMode) {
        this.manual = new ManualTest(() => this.sample(), () => this.mesh);
        lastManual = this.manual;
      }
      this.channel.on("mesh_roster", ({peers}) => this.mesh.updateRoster(peers));
      this.channel.on("mesh_signal", signal => this.mesh.signal(signal));
      this.channel.on("mesh_chat", message => this.mesh.receivedChat(message));
    }
    this.channel.on("playback", snapshot => this.schedule(() => this.accept(snapshot)));
    this.channel.onError(() => this.connectionLost());
    this.channel.onClose(() => this.connectionLost());
    let sent = performance.now();
    this.socket.onOpen(() => { sent = performance.now(); });
    this.channel.join().receive("ok", async ({role, snapshot, mesh}) => {
      if (this.disposed) return;
      this.role = role;
      this.connected = true;
      this.mesh?.joined(mesh);
      this.manual?.mark("transport_joined");
      this.calibrate(snapshot, sent);
      this.accept(snapshot);
      if (!this.player && !this.loading) await this.createPlayer(snapshot.video_id);
      this.refresh();
    }).receive("error", error => { this.error = `Join failed: ${error.reason}`; this.emit(); });
    this.socket.connect();
    this.tick = setInterval(() => { this.reconcile(); this.emit(); }, 500);
    this.poll = setInterval(() => this.refresh(), 2000);
    if (this.nativeControls) this.nativeTick = setInterval(() => this.observeNative(), 100);
    this.emit();
  }

  calibrate(snapshot, sent) {
    const received = performance.now();
    this.rtt = received - sent;
    if (this.rtt < this.bestRtt) {
      this.bestRtt = this.rtt;
      this.offset = snapshot.server_time_ms - (sent + received) / 2;
    }
  }

  schedule(callback) {
    if (this.disposed) return;
    if (!this.lag) { callback(); return; }
    const timer = setTimeout(() => {
      this.delays.delete(timer);
      if (!this.disposed) callback();
    }, this.lag);
    this.delays.add(timer);
  }

  request(event, payload, ok, error = () => {}) {
    this.schedule(() => this.channel.push(event, payload)
      .receive("ok", value => this.schedule(() => ok(value)))
      .receive("error", value => this.schedule(() => error(value)))
      .receive("timeout", () => error({reason: "timeout"})));
  }

  accept(snapshot) {
    if (this.disposed) return;
    if (!newerSnapshot(this.desired, snapshot)) { this.ignored++; return; }
    if (this.desired && snapshot.revision > this.desired.revision && snapshot.video_id === this.desired.video_id &&
        Math.abs(snapshot.position - targetPosition(this.desired, performance.now(), this.offset)) > 1) {
      this.seekRevision = snapshot.revision;
    }
    if (!this.desired || snapshot.revision !== this.desired.revision) this.native.commanded(performance.now());
    this.desired = snapshot;
    this.accepted++;
    this.reconcile();
    this.emit();
  }

  refresh() {
    if (!this.connected || this.disposed) return;
    const sent = performance.now();
    this.request("snapshot", {}, snapshot => {
      if (this.disposed) return;
      this.calibrate(snapshot, sent);
      this.accept(snapshot);
    });
  }

  record(event, details = {}) {
    if (!this.nativeControls) return;
    this.trace.push({event, now: performance.now(), revision: this.desired?.revision, ...details});
    if (this.trace.length > 2400) this.trace.shift();
  }

  observeNative() {
    if (!this.nativeControls || this.nativeInFlight || !this.ready || !this.connected || !this.desired) return;
    const sample = {now: performance.now(), position: this.player.getCurrentTime(),
      state: this.player.getPlayerState(), ready: !this.pendingVideo && !this.playerError,
      desiredPlaying: this.desired.playing, hidden: document.hidden, blocked: this.blocked, controller: this.canControl(),
      focused: document.activeElement === this.player.getIframe()};
    const before = {pending: this.native.pending, suppressedUntil: this.native.suppressedUntil};
    const intent = this.native.observe(sample);
    this.record("observation", {sample, before, pending: this.native.pending, intent});
    if (intent) {
      this.record("native_intent", intent);
      // Ownership passes to the pending command until its authoritative reply.
      // Reconciliation must not undo the input against the previous revision.
      this.nativeInFlight = true;
      this.native.commanded(performance.now());
      this.nativeCommands++;
      this.command("set_playback", intent);
    }
  }

  async createPlayer(video) {
    this.loading = true;
    try {
      const YT = await loadAPI();
      if (this.disposed) return;
      const frame = document.createElement("iframe");
      const url = new URL(`https://www.youtube.com/embed/${video}`);
      url.search = new URLSearchParams({enablejsapi: "1", origin: location.origin, autoplay: "0", playsinline: "1"});
      frame.src = url.href;
      frame.title = "Synchronized YouTube player";
      frame.allow = "autoplay; encrypted-media; picture-in-picture; fullscreen";
      frame.referrerPolicy = "strict-origin-when-cross-origin";
      frame.style.cssText = "width:100%;height:100%;min-height:200px;border:0;display:block";
      this.host.replaceChildren(frame);
      this.video = video;
      this.player = new YT.Player(frame, {events: {
        onReady: () => {
          if (this.disposed) return;
          clearTimeout(this.readyTimer);
          this.ready = true;
          if (!this.desired?.playing) this.player.cueVideoById({videoId: video,
            startSeconds: this.desired ? targetPosition(this.desired, performance.now(), this.offset) : 0});
          this.reconcile();
          this.emit();
        },
        onStateChange: event => {
          if (this.disposed) return;
          this.record("player_state", {state: event.data});
          if (event.data === 5 && this.pendingVideo && this.player.getVideoData()?.video_id === this.pendingVideo) {
            this.video = this.pendingVideo;
            this.pendingVideo = null;
          }
          if (event.data === 1) this.blocked = false;
          queueMicrotask(() => {
            this.observeNative();
            if (!this.nativeControls || !this.canControl()) this.reconcile();
            this.emit();
          });
        },
        onAutoplayBlocked: () => { this.blocked = true; this.emit(); },
        onError: event => {
          this.playerError = playerError(event.data);
          this.video = this.pendingVideo || this.video;
          this.pendingVideo = null;
          this.emit();
        },
      }});
      this.readyTimer = setTimeout(() => {
        if (!this.ready && !this.disposed) { this.playerError = "Player initialization timed out. Leave and rejoin to retry."; this.emit(); }
      }, 30_000);
    } catch (error) {
      if (!this.disposed) { this.playerError = error.message; this.emit(); }
    }
  }

  reconcile() {
    if (this.disposed || !this.ready || !this.connected || !this.desired) return;
    const now = performance.now();
    this.observeNative();
    if (this.nativeControls && this.canControl() && (this.native.pending || this.nativeInFlight)) return;
    const target = Math.min(targetPosition(this.desired, now, this.offset), this.player.getDuration() || Infinity);
    if (this.desired.video_id !== this.video && this.desired.video_id !== this.pendingVideo) {
      this.pendingVideo = this.desired.video_id;
      this.playerError = "";
      this.native.commanded(now);
      this.player.cueVideoById({videoId: this.pendingVideo, startSeconds: targetPosition(this.desired, now, this.offset)});
      this.lastSeek = now;
      return;
    }
    if (this.pendingVideo || !this.enabled || this.blocked || this.playerError) return;
    const state = this.player.getPlayerState();
    const plan = correction({target, position: this.player.getCurrentTime(), playing: this.desired.playing,
      state, now, lastSeek: this.lastSeek, force: this.seekRevision === this.desired.revision,
      ...(this.tightSync ? {playingTolerance: 0.2, pausedTolerance: 0.15, cooldown: 1000} : {})});
    this.seekRevision = null;
    if (plan.seek !== null) {
      this.record("correction_seek", {position: this.player.getCurrentTime(), target: plan.seek});
      this.lastSeek = now;
      this.corrections++;
      this.native.commanded(now);
      this.player.seekTo(plan.seek, true);
    }
    if (plan.transport && now - this.lastTransport >= 1500 && !(state === 0 && target >= this.player.getDuration() - 0.5)) {
      this.lastTransport = now;
      this.record("correction_transport", {operation: plan.transport, state});
      this.native.commanded(now);
      if (plan.transport === "play") this.player.playVideo();
      else this.player.pauseVideo();
    }
  }

  enable() {
    if (!this.ready || this.pendingVideo) return;
    this.native.commanded(performance.now());
    this.enabled = true;
    this.blocked = false;
    this.lastTransport = -Infinity;
    // The local click supplies activation; player callbacks never publish room controls.
    if (this.desired?.playing) this.player.playVideo();
    else if ([1, 3].includes(this.player.getPlayerState())) this.player.pauseVideo();
    this.reconcile();
    this.emit();
  }

  command(op, observed = null) {
    this.commands = this.commands.then(() => new Promise(resolve => {
      if (!this.connected || !this.desired) { this.nativeInFlight = false; resolve(); return; }
      const command = {op, revision: this.desired.revision};
      if (this.access) command.authority_revision = this.desired.access.authority_revision;
      try {
        if (op === "set_playback") Object.assign(command, observed);
        if (op === "video") command.video_id = videoId(document.getElementById("sync-source").value);
        if (op === "seek") {
          const raw = document.getElementById("sync-seconds").value.trim();
          command.position = Number(raw);
          if (!raw || !Number.isFinite(command.position) || command.position < 0) throw new Error("Enter non-negative seek seconds.");
        }
      } catch (error) { this.error = error.message; this.emit(); resolve(); return; }
      this.request("control", command,
        snapshot => {
          this.record("command_accepted", {command, snapshot});
          if (op === "set_playback") this.nativeInFlight = false;
          this.error = ""; this.accept(snapshot); resolve();
        },
        error => {
          this.record("command_rejected", {command, error});
          this.error = `Command rejected: ${error.reason}`;
          // A rejected/uncertain native command needs a fresh authoritative
          // snapshot before correction resumes. Never retry it blindly.
          if (op === "set_playback") {
            this.request("snapshot", {}, snapshot => {
              this.nativeInFlight = false;
              this.accept(snapshot);
              resolve();
            }, () => { this.connectionLost(); resolve(); });
          } else { this.refresh(); this.emit(); resolve(); }
        });
    }));
  }

  connectionLost() {
    if (this.disposed) return;
    this.connected = false;
    this.native.reset();
    this.nativeInFlight = false;
    this.mesh?.suspend();
    this.manual?.mark("transport_disconnected");
    this.bestRtt = Infinity;
    if (this.ready) this.player.pauseVideo();
    this.emit();
  }

  dispose() {
    if (this.disposed) return;
    this.disposed = true;
    clearInterval(this.tick);
    clearInterval(this.poll);
    clearInterval(this.nativeTick);
    clearTimeout(this.readyTimer);
    for (const timer of this.delays) clearTimeout(timer);
    this.delays.clear();
    this.observer.disconnect();
    this.mesh?.dispose();
    this.manual?.finish({...this.sample(), connected: false});
    globalThis.removeEventListener("pagehide", this.onPageHide);
    document.removeEventListener("visibilitychange", this.onVisibility);
    this.channel?.leave();
    this.socket?.disconnect();
    this.player?.destroy();
    this.host.replaceChildren();
    delete this.host.syncSample;
    delete this.host.syncTrace;
    this.host.dataset.resources = "0";
    sessions.delete(this.id);
  }
}

export function connect(room, token = "") {
  for (const session of sessions.values()) session.dispose();
  const id = crypto.randomUUID();
  if (token) sessionStorage.setItem(`youtube-sync-host:${room}`, token);
  const credential = token || sessionStorage.getItem(`youtube-sync-host:${room}`) || "";
  sessionStorage.setItem("youtube-sync-last-room", room);
  const session = new SyncSession(id, room, credential);
  sessions.set(id, session);
  queueMicrotask(() => session.connect());
  return id;
}
export function join() {
  const room = document.getElementById("sync-room").value.trim() || sessionStorage.getItem("youtube-sync-last-room") || "";
  return connect(room);
}
export function enable(id) { sessions.get(id)?.enable(); }
export function command(id, op) { sessions.get(id)?.command(op); }
export function localPause(id) { sessions.get(id)?.player?.pauseVideo(); }
export function disconnect(id) { sessions.get(id)?.socket.disconnect(); }
export function reconnect(id) { sessions.get(id)?.socket.connect(); }
export function leave(id) {
  if (pendingAccess?.id === id) { pendingAccess.controller.abort(); pendingAccess = null; }
  sessions.get(id)?.dispose();
}

function startAccess(room, invitation) {
  pendingAccess?.controller.abort();
  for (const session of sessions.values()) session.dispose();
  const id = crypto.randomUUID(), controller = new AbortController();
  pendingAccess = {id, controller};
  const name = document.getElementById("access-name").value.trim();
  queueMicrotask(async () => {
    try {
      if (!name) throw new Error("Choose your display name before creating or joining a room.");
      const auth = await bootstrapAccess(controller.signal);
      if (!room) {
        if (!auth.signed_in) throw new Error("Sign in as the room owner first, then create the room.");
        const response = await fetch("/dev/spikes/room-access/rooms", {method: "POST", signal: controller.signal,
          credentials: "same-origin", headers: {"content-type": "application/json", "x-csrf-token": auth.csrf_token}, body: "{}"});
        if (!response.ok || response.redirected) throw new Error("Room creation failed. Check that you are still signed in.");
        const created = await response.json(); room = created.room_id; invitation = created.invitation;
      }
      if (controller.signal.aborted) return;
      if (!invitation) throw new Error("Open the full invitation link to join this room.");
      const session = new SyncSession(id, room, "", {...auth, invitation, name});
      pendingAccess = null;
      sessions.set(id, session);
      session.connect();
    } catch (error) {
      if (error.name !== "AbortError") globalThis.Hologram?.dispatchAction("access_failed", "page", {error: error.message});
      if (pendingAccess?.id === id) pendingAccess = null;
    }
  });
  return id;
}

export function createAccess() { return startAccess(null, ""); }
export function joinAccess(room, invitation) { return startAccess(room.trim(), invitation); }
export function meshControl(id, action) {
  const mesh = sessions.get(id)?.mesh;
  if (!mesh) return;
  sessions.get(id)?.manual?.mark(action);
  if (action === "start_media") mesh.start();
  else if (action === "start_microphone") mesh.start("microphone");
  else if (action === "stop_media") mesh.stop();
  else if (action === "toggle_audio") mesh.toggle("audio");
  else if (action === "toggle_video") mesh.toggle("video");
  else if (action === "send_chat") mesh.chat(document.getElementById("mesh-chat-input").value);
}
export function manualControl(id, action) {
  const session = sessions.get(id);
  const manual = session?.manual || lastManual;
  if (!manual) {
    const status = document.getElementById("manual-report-status");
    if (status) status.textContent = "Create or join a room first to begin this device's test.";
    return;
  }
  if (action === "manual_export") manual.download();
  else if (action === "manual_marker") {
    manual.mark("observation", document.getElementById("manual-notes").value);
    manual.render(manual.ended ? manual.final : undefined);
  } else {
    session?.mesh?.enableAudio(action === "room_audio");
    manual.mark(action);
  }
}
export function setLag(id, raw) {
  const session = sessions.get(id);
  if (!session) return;
  const lag = Number(raw);
  session.lag = Number.isFinite(lag) ? Math.min(2000, Math.max(0, lag)) : 0;
  session.bestRtt = Infinity;
  session.emit();
}

export default {connect, join, createAccess, joinAccess, watchAccessAuth, enable, command, localPause, disconnect, reconnect, leave, setLag, meshControl, manualControl};
