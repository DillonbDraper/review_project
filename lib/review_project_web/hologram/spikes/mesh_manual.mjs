// Statistics and written observations only; no audio/video recording.
export function reportSample(sample) {
  if (!sample) return null;
  const keys = ["room", "role", "connected", "ready", "enabled", "blocked", "state", "video", "actual_video", "playing", "revision", "position", "duration", "expected", "drift", "sampled_at_ms", "rtt_ms", "corrections", "error", "mesh", "access"];
  const copy = structuredClone(Object.fromEntries(keys.filter(key => sample[key] !== undefined).map(key => [key, sample[key]])));
  for (const track of copy.mesh?.local_tracks || []) {
    const allowed = ["width", "height", "frameRate", "sampleRate", "channelCount", "echoCancellation", "noiseSuppression", "autoGainControl"];
    track.settings = Object.fromEntries(allowed.filter(key => track.settings?.[key] !== undefined).map(key => [key, track.settings[key]]));
  }
  return copy;
}

export class ManualTest {
  constructor(sample, media) {
    this.sample = sample;
    this.media = media;
    this.started = new Date().toISOString();
    this.samples = [];
    this.events = [];
    this.root = document.getElementById("mesh-manual-panel");
    this.onInput = event => { if (event.target.id === "manual-volume") this.media()?.setVolume(event.target.value); };
    this.root.addEventListener("input", this.onInput);
    this.timer = setInterval(() => this.record(), 5000);
    this.mark("joined_test_page");
    this.record();
  }

  record(value = this.sample()) {
    if (this.ended) return;
    this.samples.push({at: new Date().toISOString(), visibility: document.visibilityState, sample: reportSample(value)});
    if (this.samples.length > 720) this.samples.splice(0, this.samples.length - 720);
    this.render(value);
  }

  mark(action, detail = "") {
    this.events.push({at: new Date().toISOString(), action, detail: String(detail).slice(0, 500)});
    if (this.events.length > 200) this.events.shift();
  }

  text(id, value) { const element = document.getElementById(id); if (element) element.textContent = value; }

  render(value = this.sample()) {
    const mesh = value?.mesh;
    this.text("manual-environment", globalThis.isSecureContext && navigator.mediaDevices?.getUserMedia ?
      "Secure connection · camera and microphone API available. Allow access when prompted." :
      "Camera access unavailable. Trust the test certificate and reopen this HTTPS URL in a normal browser window.");
    if (mesh) {
      const connected = mesh.peers.filter(peer => peer.connection === "connected").length;
      const tracks = mesh.local_tracks.map(track => `${track.kind}: ${track.readyState}${track.enabled ? "" : " (muted)"}`).join(" · ");
      this.text("manual-media-status", `${mesh.connected ? "Joined" : "Disconnected"} · ${mesh.participants}/5 participants · ${connected}/4 peers connected${tracks ? ` · ${tracks}` : " · camera and microphone stopped"}`);
      this.text("manual-media-error", mesh.error || mesh.warning || "");
      this.text("manual-ice-status", `Network mode: ${mesh.ice?.mode || "direct"} · policy: ${mesh.ice?.policy || "all"} · credentials renewed: ${mesh.ice?.renewals || 0}. Selected paths: ${mesh.peers.map(p => `${p.stats?.local_candidate || "pending"}/${p.stats?.relay_protocol || p.stats?.candidate_protocol || "pending"}`).join(", ") || "no peers yet"}`);
      const audio = mesh.audio;
      this.text("manual-audio-status", audio?.blocked > 0 ? "Room playback was blocked. Click Enable room audio again while peers are connected." :
        audio?.enabled ? `Room audio enabled · ${audio.remote_elements} remote playback elements · volume ${Math.round(audio.volume * 100)}%. Confirm voices by listening.` :
        "Room audio is off. Enable it to hear others; your own preview stays silent.");
    }
    this.text("manual-report-status", `${this.samples.length} samples retained · ${this.events.length} event markers${this.ended ? " · test ended; report remains downloadable" : " · sampling every 5 seconds"}. Download before reloading or starting a new room.`);
  }

  finish(value) {
    if (this.ended) return;
    this.record(value);
    this.mark("leave", "Media disposed; confirm hardware indicators manually.");
    this.ended = new Date().toISOString();
    clearInterval(this.timer);
    this.root.removeEventListener("input", this.onInput);
    this.final = value;
    this.render(value);
  }

  report() {
    const input = (id, length) => (document.getElementById(id)?.value || "").slice(0, length);
    return {
      schema: "review-project-mesh-3b/v1", started_at: this.started, ended_at: this.ended || null,
      exported_at: new Date().toISOString(), user_agent: navigator.userAgent,
      metadata: {participant: input("manual-label", 80), hardware: input("manual-hardware", 300),
        audio_and_network: input("manual-audio-setup", 300), notes: input("manual-notes", 6000)},
      checks: Object.fromEntries([...this.root.querySelectorAll("[data-manual-check]")].map(el => [el.dataset.manualCheck, el.value])),
      settings: {video_ideal: "320x180@15", video_max_bitrate: 250000, audio_max_bitrate: 32000,
        ice: this.sample()?.mesh?.ice || null, sample_interval_ms: 5000, max_samples: 720, max_events: 200,
        note: "Research settings, not release targets. No media or chat bodies included. CPU, memory and audio quality require manual observation."},
      events: this.events, samples: this.samples,
    };
  }

  download() {
    if (!this.ended) this.record();
    const report = this.report();
    const url = URL.createObjectURL(new Blob([JSON.stringify(report, null, 2)], {type: "application/json"}));
    const anchor = document.createElement("a");
    anchor.href = url;
    const label = report.metadata.participant.replace(/[^a-z0-9_-]/gi, "_").slice(0, 50) || "participant";
    anchor.download = `mesh-3b-${label}-${Date.now()}.json`;
    document.body.append(anchor); anchor.click(); anchor.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    this.text("manual-report-status", `Downloaded ${report.samples.length} samples. Keep this report with the other four device reports.`);
  }
}
