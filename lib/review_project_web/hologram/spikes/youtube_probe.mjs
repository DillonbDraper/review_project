// The official SDK must load from YouTube. Our loader and facade are bundled by
// Hologram; no script tags or API keys are placed in templates. No media capture.
const sessions = new Map();
const states = {"-1": "unstarted", 0: "ended", 1: "playing", 2: "paused", 3: "buffering", 5: "cued"};

// bfcache may restore the document after pagehide has released its native player.
// One module-level listener avoids retaining disposed Session instances.
globalThis.addEventListener?.("pageshow", event => {
  const host = document.getElementById("youtube-player-host");
  if (event.persisted && host?.dataset.resources === "0") {
    globalThis.Hologram?.dispatchAction("youtube_event", "page", {
      ready: false, status: "Player removed. Create the player to reconnect.",
      player_state: "removed", video_id: "", position: 0, duration: 0,
      error: "", blocked: false, events: 0,
    });
  }
});

export function videoId(input) {
  const value = String(input).trim();
  if (/^[\w-]{11}$/.test(value)) return value;
  let url;
  try { url = new URL(value); } catch { throw new Error("Enter a YouTube video link or an 11-character video ID."); }
  if (url.protocol !== "https:" && url.protocol !== "http:") throw new Error("Use an http or https YouTube link.");
  let id;
  if (["youtu.be", "www.youtu.be"].includes(url.hostname)) id = url.pathname.slice(1);
  if (["youtube.com", "www.youtube.com", "m.youtube.com"].includes(url.hostname)) {
    if (url.pathname === "/watch") id = url.searchParams.get("v");
    else id = url.pathname.match(/^\/(?:embed|shorts|live)\/([\w-]{11})\/?$/)?.[1];
  }
  if (!id || !/^[\w-]{11}$/.test(id)) throw new Error("That link does not identify a YouTube video. Playlists alone are not supported.");
  return id;
}

export {playerError, loadAPI} from "../../../../assets/js/youtube_api.mjs";
import {playerError, loadAPI} from "../../../../assets/js/youtube_api.mjs";

class Session {
  constructor(id, host) {
    this.id = id;
    this.host = host;
    this.player = null;
    this.ready = false;
    this.disposed = false;
    this.status = "Loading the YouTube player…";
    this.error = "";
    this.blocked = false;
    this.cueing = false;
    this.events = 0;
    this.video = "";
    this.state = "loading";
    this.onPageHide = () => this.dispose(false);
    globalThis.addEventListener("pagehide", this.onPageHide);
    this.observer = new MutationObserver(() => {
      if (!this.host.isConnected) this.dispose(false);
    });
    this.observer.observe(document.documentElement, {childList: true, subtree: true});
  }

  emit(status) {
    if (status) this.status = status;
    const position = this.ready ? this.player.getCurrentTime() : 0;
    const duration = this.ready ? this.player.getDuration() : 0;
    const snapshot = {
      ready: this.ready && !this.cueing, status: this.status, player_state: this.state,
      video_id: this.video, position: Math.round(position || 0),
      duration: Math.round(duration || 0), error: this.error,
      blocked: this.blocked, events: this.events,
    };
    // Data attributes also make lifecycle checks possible without retaining the player.
    this.host.dataset.session = this.id;
    this.host.dataset.resources = this.disposed ? "0" : "1";
    globalThis.Hologram?.dispatchAction("youtube_event", "page", snapshot);
  }

  async start() {
    try {
      this.video = videoId(document.getElementById("youtube-source").value);
      this.emit();
      const YT = await loadAPI();
      if (this.disposed) return;
      const frame = document.createElement("iframe");
      const url = new URL(`https://www.youtube.com/embed/${this.video}`);
      url.search = new URLSearchParams({enablejsapi: "1", origin: location.origin, playsinline: "1", autoplay: "0"});
      frame.src = url.href;
      frame.title = "YouTube video player";
      frame.allow = "autoplay; encrypted-media; picture-in-picture; fullscreen";
      frame.allowFullscreen = true;
      frame.referrerPolicy = "strict-origin-when-cross-origin";
      frame.style.cssText = "width:100%;height:100%;min-height:200px;border:0;display:block";
      this.host.replaceChildren(frame);
      this.player = new YT.Player(frame, {events: {
        onReady: () => {
          if (this.disposed) return;
          clearTimeout(this.readyTimer);
          this.ready = true;
          this.events++;
          this.emit("Ready. Click Enable playback, or use the video's Play button.");
          this.interval = setInterval(() => this.emit(), 1000);
        },
        onStateChange: event => {
          if (this.disposed) return;
          this.events++;
          this.state = states[event.data] || "unknown";
          if (event.data === 5) this.cueing = false;
          if (event.data === 1) { this.blocked = false; this.error = ""; }
          this.emit(`Player ${this.state}.`);
        },
        onAutoplayBlocked: () => {
          if (this.disposed) return;
          this.blocked = true;
          this.events++;
          this.emit("Playback needs a click on this device.");
        },
        onError: event => {
          if (this.disposed) return;
          this.error = playerError(event.data);
          this.cueing = false;
          this.events++;
          this.state = "error";
          this.emit("Choose another video or retry.");
        },
      }});
      this.readyTimer = setTimeout(() => {
        if (this.disposed || this.ready) return;
        this.dispose(false);
        this.error = "The embedded player did not become ready. Check your connection or content blocker, then create it again.";
        this.emit("Player initialization timed out.");
      }, 30_000);
    } catch (error) {
      if (this.disposed) return;
      this.dispose(false);
      this.error = error.message;
      this.emit("Could not create the player.");
    }
  }

  control(command) {
    if (!this.ready || this.disposed) return;
    try {
      if (command === "cue") {
        const next = videoId(document.getElementById("youtube-source").value);
        this.cueing = true;
        this.player.cueVideoById(next);
        this.video = next;
        this.error = "";
        this.blocked = false;
        this.emit(this.cueing ? "Preparing the selected video…" : "Video selected. Click Play when ready.");
      } else if (command === "play") {
        if (this.cueing) return;
        this.player.playVideo();
      } else if (command === "pause") {
        this.player.pauseVideo();
      } else if (command === "seek") {
        const raw = document.getElementById("youtube-seconds").value.trim();
        const seconds = Number(raw);
        if (!raw || !Number.isFinite(seconds) || seconds < 0) throw new Error("Enter a non-negative number of seconds.");
        this.player.seekTo(seconds, true);
        this.error = "";
        this.emit("Seek requested.");
      }
    } catch (error) {
      this.error = error.message;
      this.emit();
    }
  }

  dispose(notify = true) {
    if (this.disposed) return;
    this.disposed = true;
    this.ready = false;
    this.blocked = false;
    this.error = "";
    this.cueing = false;
    this.state = "removed";
    clearInterval(this.interval);
    clearTimeout(this.readyTimer);
    this.observer.disconnect();
    globalThis.removeEventListener("pagehide", this.onPageHide);
    this.player?.destroy();
    this.player = null;
    this.host.replaceChildren();
    this.host.dataset.resources = "0";
    sessions.delete(this.id);
    if (notify) this.emit("Player removed. Create another when ready.");
  }
}

export function create() {
  for (const session of sessions.values()) session.dispose(false);
  const id = crypto.randomUUID();
  const session = new Session(id, document.getElementById("youtube-player-host"));
  sessions.set(id, session);
  // Defer telemetry so the creating Hologram action commits the opaque ID first.
  queueMicrotask(() => session.start());
  return id;
}

export function control(id, command) { sessions.get(id)?.control(command); }
export function destroy(id) { sessions.get(id)?.dispose(); }

export default {create, control, destroy};
