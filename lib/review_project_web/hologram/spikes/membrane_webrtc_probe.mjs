// Phase 0 spike: Hologram-owned WebRTC facade that negotiates with the Membrane
// Source/Sink echo pipeline over `Membrane.WebRTC.PhoenixSignaling` (a plain
// Phoenix socket, NOT LiveView). This is the integration seam between spike 1
// (Hologram drives browser-native WebRTC) and spike 3 (membrane_webrtc_plugin
// media engine). PeerConnections are held in a module-level registry keyed by
// the page's base_id — the "registry + opaque id" boundary the Hologram interop
// spike recommended for browser-native objects.
//
// Resolved at compile time to an absolute path by Hologram, then bundled by
// esbuild; the relative import below resolves against this file's real location.
import { Socket } from "../../../../deps/phoenix/priv/static/phoenix.mjs";

const ICE_SERVERS = [{ urls: "stun:stun.l.google.com:19302" }];
const registry = new Map();

function dispatch(session, eventType) {
  session.eventCount += 1;
  session.lastEvent = eventType;
  globalThis.Hologram?.dispatchAction("membrane_webrtc_event", "page", session.snapshot());
}

class MembraneEchoSession {
  constructor(baseId) {
    this.baseId = baseId;
    this.socket = null;
    this.captureChannel = null;
    this.playerChannel = null;
    this.capturePc = null;
    this.playerPc = null;
    this.localStream = null;
    this.status = "created";
    this.error = "—";
    this.eventCount = 0;
    this.lastEvent = "created";
    this.captureStats = { audioPkts: 0, videoPkts: 0 };
    this.playerStats = { audioPkts: 0, videoPkts: 0, videoFrames: 0 };
    this.statsInterval = null;
  }

  snapshot() {
    return {
      base_id: this.baseId,
      status: this.status,
      ready:
        this.capturePc?.connectionState === "connected" &&
        this.playerPc?.connectionState === "connected",
      capture_state: this.capturePc?.connectionState || "—",
      capture_ice: this.capturePc?.iceConnectionState || "—",
      player_state: this.playerPc?.connectionState || "—",
      player_ice: this.playerPc?.iceConnectionState || "—",
      capture_audio_pkts: this.captureStats.audioPkts,
      capture_video_pkts: this.captureStats.videoPkts,
      player_audio_pkts: this.playerStats.audioPkts,
      player_video_pkts: this.playerStats.videoPkts,
      player_video_frames: this.playerStats.videoFrames,
      error: this.error,
      event_count: this.eventCount,
      last_event: this.lastEvent,
    };
  }

  fail(stage, error) {
    this.status = `error: ${stage}`;
    this.error = error?.message || String(error);
    dispatch(this, `error: ${stage}`);
    console.error(`[membrane-webrtc ${this.baseId}] ${stage} failed`, error);
  }

  async start() {
    try {
      this.status = "connecting signaling socket";
      this.socket = new Socket("/signaling", {});
      this.socket.connect();
      dispatch(this, "socket connecting");

      await this.startPlayer();
      await this.startCapture();

      this.statsInterval = setInterval(() => this.pollStats(), 1000);
    } catch (error) {
      this.fail("start", error);
    }
  }

  joinChannel(topic) {
    const channel = this.socket.channel(topic);
    return new Promise((resolve, reject) => {
      channel
        .join()
        .receive("ok", () => resolve(channel))
        .receive("error", (resp) => reject(new Error(`join ${topic} failed: ${JSON.stringify(resp)}`)));
    });
  }

  attachCommonHandlers(pc, side) {
    pc.addEventListener("connectionstatechange", () => {
      this.status = `capture ${this.capturePc?.connectionState || "—"} / player ${this.playerPc?.connectionState || "—"}`;
      dispatch(this, `${side} connectionstatechange`);
    });
    pc.addEventListener("iceconnectionstatechange", () =>
      dispatch(this, `${side} iceconnectionstatechange`)
    );
  }

  // Browser -> Membrane.WebRTC.Source: capture cam+mic, offer, send to "<base>_capture".
  async startCapture() {
    const topic = `${this.baseId}_capture`;
    this.captureChannel = await this.joinChannel(topic);

    this.localStream = await navigator.mediaDevices.getUserMedia({ audio: true, video: true });
    this.capturePc = new RTCPeerConnection({ iceServers: ICE_SERVERS });
    this.attachCommonHandlers(this.capturePc, "capture");

    this.capturePc.onicecandidate = (event) => {
      if (event.candidate === null) return;
      this.captureChannel.push(topic, JSON.stringify({ type: "ice_candidate", data: event.candidate }));
    };

    const preview = document.getElementById("membrane-capture");
    if (preview) {
      preview.srcObject = new MediaStream();
      for (const track of this.localStream.getTracks()) preview.srcObject.addTrack(track);
      preview.play().catch(() => {});
    }

    for (const track of this.localStream.getTracks()) {
      this.capturePc.addTrack(track, this.localStream);
    }

    this.captureChannel.on(topic, async (payload) => {
      try {
        if (payload.type === "sdp_answer") {
          await this.capturePc.setRemoteDescription(payload.data);
        } else if (payload.type === "ice_candidate" && payload.data) {
          await this.capturePc.addIceCandidate(payload.data);
        }
      } catch (error) {
        this.fail("capture signaling", error);
      }
    });

    const offer = await this.capturePc.createOffer();
    await this.capturePc.setLocalDescription(offer);
    this.captureChannel.push(topic, JSON.stringify({ type: "sdp_offer", data: offer }));
    dispatch(this, "capture offer sent");
  }

  // Membrane.WebRTC.Sink -> browser: Sink offers, we answer, attach track to <video>.
  async startPlayer() {
    const topic = `${this.baseId}_player`;
    this.playerChannel = await this.joinChannel(topic);

    this.playerPc = new RTCPeerConnection({ iceServers: ICE_SERVERS });
    this.attachCommonHandlers(this.playerPc, "player");

    const player = document.getElementById("membrane-player");
    if (player) player.srcObject = new MediaStream();

    this.playerPc.ontrack = (event) => {
      if (player) {
        player.srcObject.addTrack(event.track);
        player.play().catch(() => {});
      }
      dispatch(this, `player track ${event.track.kind}`);
    };

    this.playerPc.onicecandidate = (event) => {
      if (event.candidate === null) return;
      this.playerChannel.push(topic, JSON.stringify({ type: "ice_candidate", data: event.candidate }));
    };

    this.playerChannel.on(topic, async (payload) => {
      try {
        if (payload.type === "sdp_offer") {
          await this.playerPc.setRemoteDescription(payload.data);
          const answer = await this.playerPc.createAnswer();
          await this.playerPc.setLocalDescription(answer);
          this.playerChannel.push(topic, JSON.stringify({ type: "sdp_answer", data: answer }));
          dispatch(this, "player answer sent");
        } else if (payload.type === "ice_candidate" && payload.data) {
          await this.playerPc.addIceCandidate(payload.data);
        }
      } catch (error) {
        this.fail("player signaling", error);
      }
    });
  }

  async pollStats() {
    try {
      if (this.capturePc) {
        const out = { audioPkts: 0, videoPkts: 0 };
        (await this.capturePc.getStats()).forEach((s) => {
          if (s.type === "outbound-rtp") {
            if (s.kind === "audio") out.audioPkts = s.packetsSent || 0;
            if (s.kind === "video") out.videoPkts = s.packetsSent || 0;
          }
        });
        this.captureStats = out;
      }
      if (this.playerPc) {
        const inb = { audioPkts: 0, videoPkts: 0, videoFrames: 0 };
        (await this.playerPc.getStats()).forEach((s) => {
          if (s.type === "inbound-rtp") {
            if (s.kind === "audio") inb.audioPkts = s.packetsReceived || 0;
            if (s.kind === "video") {
              inb.videoPkts = s.packetsReceived || 0;
              inb.videoFrames = s.framesDecoded || 0;
            }
          }
        });
        this.playerStats = inb;
      }
      dispatch(this, "stats");
    } catch (error) {
      // stats are best-effort
    }
  }

  close() {
    if (this.statsInterval) clearInterval(this.statsInterval);
    this.localStream?.getTracks().forEach((t) => t.stop());
    this.capturePc?.close();
    this.playerPc?.close();
    this.captureChannel?.leave();
    this.playerChannel?.leave();
    this.socket?.disconnect();
    this.status = "closed";
    dispatch(this, "closed");
  }
}

export default {
  newId() {
    return globalThis.crypto?.randomUUID?.() || `holo-${Date.now()}-${Math.floor(Math.random() * 1e6)}`;
  },

  connect(baseId) {
    const existing = registry.get(baseId);
    if (existing) existing.close();

    const session = new MembraneEchoSession(baseId);
    registry.set(baseId, session);
    session.start();
    return baseId;
  },

  disconnect(baseId) {
    const session = registry.get(baseId);
    if (session) {
      session.close();
      registry.delete(baseId);
    }
    return baseId;
  },
};
