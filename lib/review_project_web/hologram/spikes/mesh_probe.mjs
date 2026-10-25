// Development mesh experiment with optional STUN/TURN; no media recording.
import {captureDevices} from "./mesh_capture.mjs";

export class MeshSession {
  constructor(channel, changed, {manual = false} = {}) {
    this.channel = channel;
    this.changed = changed;
    this.container = document.getElementById("mesh-videos");
    this.chatLog = document.getElementById("mesh-chat-log");
    this.peers = new Map();
    this.roster = [];
    this.messages = [];
    this.selfId = "";
    this.connected = false;
    this.disposed = false;
    this.generation = 0;
    this.created = 0;
    this.closed = 0;
    this.error = "";
    this.warning = "";
    this.ice = {servers: [], policy: "all", mode: "direct"};
    this.iceRenewals = 0;
    this.manual = manual;
    this.listening = false;
    this.volume = Number(document.getElementById("manual-volume")?.value ?? 0.6);
    this.statsTick = setInterval(() => this.collectStats(), 1000);
    this.iceTick = setInterval(() => this.renewICE(), 1000);
  }

  joined({self_id: id, peers, chat, ice}) {
    if (ice) this.applyICE(ice);
    this.connected = true;
    this.selfId = id;
    this.messages = chat;
    this.renderChat();
    this.updateRoster(peers);
    if (this.stream) this.publishMedia(true);
  }

  applyICE(ice) {
    this.ice = ice;
    this.renewAt = ice.refresh_after ? Date.now() + ice.refresh_after * 1000 : Infinity;
    for (const peer of this.peers.values()) {
      peer.pc.setConfiguration({iceServers: ice.servers, iceTransportPolicy: ice.policy});
      // New allocations must use the renewed credentials. Updating configuration
      // alone does not reauthenticate an allocation that is already in use.
      if (this.selfId < peer.id) peer.pc.restartIce();
    }
  }

  renewICE() {
    if (!this.connected || this.disposed || this.renewing || Date.now() < this.renewAt) return;
    this.renewing = true;
    this.channel.push("mesh_ice", {}).receive("ok", ice => {
      this.renewing = false;
      if (!this.connected || this.disposed) return;
      this.applyICE(ice); this.iceRenewals++; this.changed();
    }).receive("error", () => this.iceFailure()).receive("timeout", () => this.iceFailure());
  }

  iceFailure() {
    this.renewing = false; this.renewAt = Date.now() + 5000;
    if (!this.disposed) { this.warning = "TURN credentials could not be refreshed; retrying."; this.changed(); }
  }

  updateRoster(roster) {
    if (this.disposed) return;
    this.roster = roster;
    const wanted = new Set(roster.filter(peer => peer.id !== this.selfId && peer.media).map(peer => peer.id));
    for (const [id, peer] of this.peers) if (!wanted.has(id)) this.closePeer(peer);
    if (this.stream && this.connected && roster.find(peer => peer.id === this.selfId)?.media) {
      for (const id of wanted) this.peer(id);
    }
    this.changed();
  }

  publishMedia(enabled) {
    this.channel.push("mesh_media", {enabled}).receive("ok", ({peers}) => this.updateRoster(peers))
      .receive("error", ({reason}) => { this.error = `Media presence failed: ${reason}`; this.changed(); });
  }

  async start(mode = "both") {
    if (this.stream || this.gettingMedia || this.disposed || !this.connected) return;
    const generation = ++this.generation;
    this.gettingMedia = true;
    try {
      this.error = "";
      this.warning = "";
      const captured = await captureDevices(mode, request => navigator.mediaDevices.getUserMedia(request),
        () => this.disposed || generation !== this.generation);
      if (!captured) return;
      const stream = new MediaStream(captured.tracks);
      if (this.disposed || generation !== this.generation) { stream.getTracks().forEach(track => track.stop()); return; }
      this.stream = stream;
      this.error = "";
      this.warning = captured.warnings.join(" ");
      this.preview = this.video("local", stream.getVideoTracks().length ? "You · local preview" : "You · microphone only", stream);
      this.publishMedia(true);
    } catch (error) {
      if (!this.disposed && generation === this.generation) this.error = error.message;
    } finally {
      this.gettingMedia = false;
      this.changed();
    }
  }

  video(id, label, stream) {
    const figure = document.createElement("figure");
    figure.id = `mesh-video-${id}`;
    figure.className = "rounded-xl border border-white/10 bg-slate-950 p-3";
    const video = document.createElement("video");
    video.autoplay = true;
    video.muted = id === "local" || !this.manual || !this.listening;
    video.volume = this.volume;
    video.playsInline = true;
    video.className = "aspect-video w-full rounded-lg bg-black object-cover";
    video.srcObject = stream;
    video.hidden = !stream.getVideoTracks().length;
    const caption = document.createElement("figcaption");
    caption.className = "mt-2 text-xs text-slate-300";
    caption.textContent = label;
    figure.append(video, caption);
    this.container.append(figure);
    const view = {figure, video, local: id === "local", blocked: false};
    this.playView(view);
    return view;
  }

  playView(view) {
    view.video.play().then(() => {
      if (this.disposed || !view.figure.isConnected) return;
      view.blocked = false;
      this.changed();
    }).catch(error => {
      if (this.disposed || !view.figure.isConnected || view.video.muted || error.name === "AbortError") return;
      view.blocked = true;
      this.changed();
    });
  }

  enableAudio(enabled) {
    if (!this.manual || this.disposed) return;
    this.listening = enabled;
    for (const peer of this.peers.values()) if (peer.view) {
      peer.view.video.muted = !enabled;
      peer.view.blocked = false;
      if (enabled) this.playView(peer.view);
    }
    this.changed();
  }

  setVolume(value) {
    const volume = Number(value);
    if (!Number.isFinite(volume)) return;
    this.volume = Math.min(1, Math.max(0, volume));
    for (const peer of this.peers.values()) if (peer.view) peer.view.video.volume = this.volume;
    this.changed();
  }

  peer(id) {
    if (this.peers.has(id)) return this.peers.get(id);
    const pc = new RTCPeerConnection({iceServers: this.ice.servers, iceTransportPolicy: this.ice.policy});
    const peer = {id, pc, candidates: [], tasks: Promise.resolve(), closed: false,
      stream: new MediaStream(), stats: null};
    this.peers.set(id, peer);
    this.created++;
    for (const track of this.stream.getTracks()) {
      // addTrack permits the answerer to reuse the incoming offer's matching
      // transceivers. Pre-created addTransceiver entries can remain unassociated
      // and silently negotiate receive-only media at the other end.
      const sender = pc.addTrack(track, this.stream);
      const transceiver = pc.getTransceivers().find(item => item.sender === sender);
      if (track.kind === "video" && transceiver.setCodecPreferences) {
        const codecs = RTCRtpReceiver.getCapabilities("video")?.codecs || [];
        transceiver.setCodecPreferences([...codecs.filter(codec => codec.mimeType.toLowerCase() === "video/vp8"),
          ...codecs.filter(codec => codec.mimeType.toLowerCase() !== "video/vp8")]);
      }
    }
    // The offerer must offer receiving both media kinds even when its own camera
    // is absent. Otherwise a video-capable answerer has no video section to send.
    if (this.selfId < id) {
      for (const kind of ["audio", "video"]) {
        if (!this.stream.getTracks().some(track => track.kind === kind)) pc.addTransceiver(kind, {direction: "recvonly"});
      }
    }
    pc.onicecandidate = ({candidate}) => { if (candidate) this.sendSignal(peer, {type: "candidate", candidate: candidate.toJSON()}); };
    pc.ontrack = ({track}) => {
      if (peer.closed) return;
      peer.stream.addTrack(track);
      if (!peer.view) peer.view = this.video(id, this.roster.find(member => member.id === id)?.name || `Peer ${id.slice(0, 8)}`, peer.stream);
      peer.view.video.hidden = !peer.stream.getVideoTracks().length;
      this.changed();
    };
    pc.onconnectionstatechange = () => this.changed();
    pc.onnegotiationneeded = () => {
      // One deterministic offerer per pair prevents offer glare. Track toggles do
      // not renegotiate; reconnects get new identities and new peer connections.
      if (this.selfId >= id || peer.closed) return;
      this.enqueue(peer, async () => {
        if (pc.signalingState !== "stable") return;
        const offer = await pc.createOffer();
        if (peer.closed) return;
        await pc.setLocalDescription(offer);
        this.sendSignal(peer, {type: "description", description: pc.localDescription.toJSON()});
      });
    };
    return peer;
  }

  enqueue(peer, operation) {
    peer.tasks = peer.tasks.then(() => { if (!peer.closed) return operation(); }).catch(error => {
      if (!peer.closed && !this.disposed) { this.error = `Peer ${peer.id.slice(0, 8)}: ${error.message}`; this.changed(); }
    });
  }

  signal({from, data}) {
    if (this.disposed || !this.connected || !this.stream || !this.roster.some(p => p.id === from && p.media)) return;
    const peer = this.peer(from);
    this.enqueue(peer, async () => {
      if (data.type === "description") {
        await peer.pc.setRemoteDescription(data.description);
        if (peer.closed) return;
        for (const candidate of peer.candidates.splice(0)) await peer.pc.addIceCandidate(candidate);
        if (data.description.type === "offer") {
          const answer = await peer.pc.createAnswer();
          if (peer.closed) return;
          await peer.pc.setLocalDescription(answer);
          this.sendSignal(peer, {type: "description", description: peer.pc.localDescription.toJSON()});
        }
        for (const sender of peer.pc.getSenders()) {
          if (!sender.track || peer.closed) continue;
          const parameters = sender.getParameters();
          if (parameters.encodings?.length) {
            for (const encoding of parameters.encodings) encoding.maxBitrate = sender.track.kind === "video" ? 250_000 : 32_000;
            await sender.setParameters(parameters);
          }
        }
      } else if (data.type === "candidate") {
        if (peer.pc.remoteDescription) await peer.pc.addIceCandidate(data.candidate);
        else peer.candidates.push(data.candidate);
      }
    });
  }

  sendSignal(peer, data) {
    if (this.disposed || peer.closed || !this.connected) return;
    this.channel.push("mesh_signal", {to: peer.id, data}).receive("error", ({reason}) => {
      if (!peer.closed) { this.error = `Signaling rejected: ${reason}`; this.changed(); }
    });
  }

  toggle(kind) {
    for (const track of this.stream?.getTracks() || []) if (track.kind === kind) track.enabled = !track.enabled;
    this.changed();
  }

  chat(body) {
    this.channel.push("mesh_chat", {body}).receive("error", ({reason}) => {
      this.error = `Chat rejected: ${reason}`; this.changed();
    });
  }

  receivedChat(message) {
    if (this.disposed) return;
    this.messages = [...new Map([...this.messages, message].map(item => [item.id, item])).values()]
      .sort((a, b) => a.id - b.id).slice(-50);
    this.renderChat();
    this.changed();
  }

  renderChat() {
    const items = this.messages.map(message => {
      const line = document.createElement("p");
      line.id = `mesh-message-${message.id}`;
      line.className = "break-words rounded-lg bg-slate-950 px-3 py-2 text-sm text-slate-200";
      line.textContent = `${message.name || `${message.role} ${message.author.slice(0, 8)}`}: ${message.body}`;
      return line;
    });
    this.chatLog.replaceChildren(...items);
  }

  async collectStats() {
    if (this.disposed || this.collecting) return;
    this.collecting = true;
    try {
      await Promise.all([...this.peers.values()].map(async peer => {
        if (peer.closed) return;
        const report = await peer.pc.getStats();
        if (peer.closed) return;
        const values = [...report.values()];
        const fields = ["kind", "mediaType", "packetsReceived", "packetsSent", "packetsLost", "bytesReceived", "bytesSent",
          "framesDecoded", "framesEncoded", "framesDropped", "frameWidth", "frameHeight", "framesPerSecond", "jitter",
          "totalEncodeTime", "totalDecodeTime", "qualityLimitationReason", "qualityLimitationDurations", "totalSamplesReceived", "totalAudioEnergy",
          "concealedSamples", "silentConcealedSamples", "concealmentEvents", "jitterBufferDelay", "jitterBufferEmittedCount"];
        const pick = value => ({...Object.fromEntries(fields.filter(key => value[key] !== undefined).map(key => [key, value[key]])),
          codec: report.get(value.codecId)?.mimeType || null});
        const transport = values.find(value => value.type === "transport" && value.selectedCandidatePairId);
        const pair = report.get(transport?.selectedCandidatePairId) || values.find(v => v.type === "candidate-pair" && v.nominated && v.state === "succeeded");
        peer.stats = {
          inbound: values.filter(v => v.type === "inbound-rtp").map(pick),
          outbound: values.filter(v => v.type === "outbound-rtp").map(pick),
          rtt: pair?.currentRoundTripTime ?? null,
          local_candidate: report.get(pair?.localCandidateId)?.candidateType || null,
          remote_candidate: report.get(pair?.remoteCandidateId)?.candidateType || null,
          relay_protocol: report.get(pair?.localCandidateId)?.relayProtocol || null,
          candidate_protocol: report.get(pair?.localCandidateId)?.protocol || null,
          pair_bytes_sent: pair?.bytesSent ?? null,
          pair_bytes_received: pair?.bytesReceived ?? null,
        };
      }));
    } catch (error) { if (!this.disposed) this.error = `Media stats: ${error.message}`; }
    finally { this.collecting = false; if (!this.disposed) this.changed(); }
  }

  snapshot() {
    return {
      self_id: this.selfId, connected: this.connected, participants: this.roster.length,
      ice: {mode: this.ice.mode, policy: this.ice.policy, server_urls: this.ice.servers.flatMap(server => server.urls),
        expires_at: this.ice.expires_at || null, renewals: this.iceRenewals},
      audio: {enabled: this.listening, volume: this.volume,
        remote_elements: [...this.peers.values()].filter(p => p.view).length,
        blocked: [...this.peers.values()].filter(p => p.view?.blocked).length},
      media_participants: this.roster.filter(p => p.media).length,
      local_tracks: (this.stream?.getTracks() || []).map(t => ({kind: t.kind, enabled: t.enabled, readyState: t.readyState,
        settings: t.getSettings()})),
      created: this.created, closed: this.closed, error: this.error, warning: this.warning, chat_count: this.messages.length,
      chat_ids: this.messages.map(m => m.id),
      peers: [...this.peers.values()].map(peer => ({id: peer.id, connection: peer.pc.connectionState,
        remote_tracks: peer.stream.getTracks().map(t => ({kind: t.kind, readyState: t.readyState})),
        video_width: peer.view?.video.videoWidth || 0, video_time: peer.view?.video.currentTime || 0, stats: peer.stats})),
    };
  }

  closePeer(peer) {
    if (peer.closed) return;
    peer.closed = true;
    peer.pc.onicecandidate = null;
    peer.pc.onnegotiationneeded = null;
    peer.pc.ontrack = null;
    peer.pc.onconnectionstatechange = null;
    peer.pc.close();
    peer.stream.getTracks().forEach(track => track.stop());
    if (peer.view) { peer.view.video.srcObject = null; peer.view.figure.remove(); }
    this.peers.delete(peer.id);
    this.closed++;
  }

  suspend() {
    this.connected = false;
    this.selfId = "";
    this.roster = [];
    for (const peer of this.peers.values()) this.closePeer(peer);
  }

  stop() {
    this.generation++;
    this.stream?.getTracks().forEach(track => track.stop());
    this.stream = null;
    for (const peer of this.peers.values()) this.closePeer(peer);
    if (this.preview) { this.preview.video.srcObject = null; this.preview.figure.remove(); this.preview = null; }
    if (this.connected && !this.disposed) this.publishMedia(false);
    this.changed();
  }

  dispose() {
    if (this.disposed) return;
    this.disposed = true;
    this.listening = false;
    this.connected = false;
    this.roster = [];
    this.stop();
    clearInterval(this.statsTick);
    clearInterval(this.iceTick);
    this.container.replaceChildren();
  }
}
