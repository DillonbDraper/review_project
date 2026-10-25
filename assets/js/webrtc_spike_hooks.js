const defaultIceServers = [{ urls: "stun:stun.l.google.com:19302" }]

function ensureMonitor() {
  if (!window.__watchPartyRtcMonitor) {
    window.__watchPartyRtcMonitor = {}
  }

  return window.__watchPartyRtcMonitor
}

function setText(id, value) {
  const element = document.getElementById(id)
  if (element) element.textContent = value
}

function statusTargetId(videoId) {
  if (videoId === "spike-capture") return "capture-connection-state"
  if (videoId === "spike-player") return "player-connection-state"
  return null
}

function statsTargetId(videoId) {
  if (videoId === "spike-capture") return "capture-stats"
  if (videoId === "spike-player") return "player-stats"
  return null
}

function summarizeStats(report) {
  const statsById = new Map()
  report.forEach((stat) => statsById.set(stat.id, stat))

  const summary = {
    timestamp: Date.now(),
    selectedPair: null,
    localCandidate: null,
    remoteCandidate: null,
    candidates: [],
    candidatePairs: [],
    inbound: [],
    outbound: []
  }

  report.forEach((stat) => {
    if (stat.type === "transport" && stat.selectedCandidatePairId) {
      summary.selectedPair = statsById.get(stat.selectedCandidatePairId) || null
    }

    if (stat.type === "candidate-pair" && (stat.selected || stat.nominated) && stat.state === "succeeded") {
      summary.selectedPair = stat
    }

    if (stat.type === "local-candidate" || stat.type === "remote-candidate") {
      summary.candidates.push({
        id: stat.id,
        type: stat.type,
        address: stat.address,
        port: stat.port,
        protocol: stat.protocol,
        candidateType: stat.candidateType,
        priority: stat.priority,
      })
    }

    if (stat.type === "candidate-pair") {
      summary.candidatePairs.push({
        id: stat.id,
        state: stat.state,
        selected: stat.selected,
        nominated: stat.nominated,
        bytesSent: stat.bytesSent,
        bytesReceived: stat.bytesReceived,
        localCandidateId: stat.localCandidateId,
        remoteCandidateId: stat.remoteCandidateId,
      })
    }

    if (stat.type === "inbound-rtp" && !stat.isRemote) {
      summary.inbound.push({
        kind: stat.kind || stat.mediaType,
        bytesReceived: stat.bytesReceived,
        packetsReceived: stat.packetsReceived,
        framesDecoded: stat.framesDecoded,
        jitter: stat.jitter
      })
    }

    if (stat.type === "outbound-rtp" && !stat.isRemote) {
      summary.outbound.push({
        kind: stat.kind || stat.mediaType,
        bytesSent: stat.bytesSent,
        packetsSent: stat.packetsSent,
        framesEncoded: stat.framesEncoded
      })
    }
  })

  if (summary.selectedPair) {
    summary.localCandidate = statsById.get(summary.selectedPair.localCandidateId) || null
    summary.remoteCandidate = statsById.get(summary.selectedPair.remoteCandidateId) || null
  }

  return summary
}

function renderSummary(videoId, pc, extra = {}) {
  if (!pc) return

  pc.getStats()
    .then((report) => {
      const summary = {
        id: videoId,
        connectionState: pc.connectionState,
        iceConnectionState: pc.iceConnectionState,
        iceGatheringState: pc.iceGatheringState,
        signalingState: pc.signalingState,
        ...extra,
        ...summarizeStats(report)
      }

      ensureMonitor()[videoId] = summary
      setText(statsTargetId(videoId), JSON.stringify(summary, null, 2))
    })
    .catch((error) => {
      setText(statsTargetId(videoId), `getStats failed: ${error.message}`)
    })
}

function attachCommonPeerHandlers(hook, pc, role) {
  const videoId = hook.el.id
  const updateState = () => {
    const state = `${pc.connectionState} / ice:${pc.iceConnectionState}`
    setText(statusTargetId(videoId), state)
    renderSummary(videoId, pc, { role, ...(hook.__diagnostics || {}) })
  }

  pc.onconnectionstatechange = updateState
  pc.oniceconnectionstatechange = updateState
  pc.onicegatheringstatechange = updateState
  updateState()

  hook.__statsInterval = window.setInterval(
    () => renderSummary(videoId, pc, { role, ...(hook.__diagnostics || {}) }),
    1000
  )
}

function stopTracks(video) {
  const stream = video?.srcObject
  if (!stream) return

  for (const track of stream.getTracks()) {
    track.stop()
  }
}

function describeError(error) {
  return {
    name: error?.name,
    message: error?.message,
    constraint: error?.constraint,
    stack: error?.stack,
  }
}

function isOrdinaryIpv4Address(address) {
  const parts = `${address || ""}`.split(".")
  if (parts.length !== 4) return false

  const octets = parts.map((part) => Number.parseInt(part, 10))
  if (octets.some((octet) => Number.isNaN(octet) || octet < 0 || octet > 255)) return false

  // Exclude CGNAT/Tailscale-like space. This local spike is trying to prove the
  // ordinary LAN + fixed server UDP-port path first.
  if (octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127) return false

  return true
}

function parseCandidateLine(candidate) {
  const line = `${candidate || ""}`.trim().replace(/^a=/, "")
  if (!line.startsWith("candidate:")) return null

  const parts = line.split(/\s+/)
  const typeIndex = parts.indexOf("typ")

  return {
    protocol: parts[2]?.toLowerCase(),
    address: parts[4],
    port: parts[5],
    type: typeIndex >= 0 ? parts[typeIndex + 1] : null,
  }
}

function shouldSignalCandidate(candidate) {
  if (!candidate?.candidate) return true

  const parsed = parseCandidateLine(candidate.candidate)
  if (!parsed) return false

  return parsed.protocol === "udp" && isOrdinaryIpv4Address(parsed.address)
}

function mungeSessionDescription(description, opts = {}) {
  const json = description.toJSON ? description.toJSON() : { type: description.type, sdp: description.sdp }
  const forceDtlsSetup = opts.forceDtlsSetup

  return {
    ...json,
    sdp: `${json.sdp || ""}`
      .split("\r\n")
      .filter((line) => !line.startsWith("a=candidate:") || shouldSignalCandidate({ candidate: line.slice(2) }))
      .map((line) => forceDtlsSetup && line.startsWith("a=setup:") ? `a=setup:${forceDtlsSetup}` : line)
      .join("\r\n"),
  }
}

function sdpDiagnostics(description) {
  const sdp = typeof description === "string" ? description : description?.sdp

  return {
    setupLines: `${sdp || ""}`.split("\r\n").filter((line) => line.startsWith("a=setup:")),
    candidateLines: `${sdp || ""}`.split("\r\n").filter((line) => line.startsWith("a=candidate:")).length,
  }
}

async function waitForIceGatheringComplete(pc, timeoutMs = 2500) {
  if (pc.iceGatheringState === "complete") return { completed: true, timedOut: false }

  return new Promise((resolve) => {
    const timeout = window.setTimeout(() => {
      pc.removeEventListener("icegatheringstatechange", onStateChange)
      resolve({ completed: pc.iceGatheringState === "complete", timedOut: true })
    }, timeoutMs)

    const onStateChange = () => {
      if (pc.iceGatheringState !== "complete") return

      window.clearTimeout(timeout)
      pc.removeEventListener("icegatheringstatechange", onStateChange)
      resolve({ completed: true, timedOut: false })
    }

    pc.addEventListener("icegatheringstatechange", onStateChange)
  })
}

function endOfCandidates(sdpMid = null, sdpMLineIndex = 0) {
  return { candidate: "", sdpMid, sdpMLineIndex }
}

function queueOrPushIceCandidate(hook, eventName, candidate) {
  hook.__iceDiagnostics ||= { sent: 0, queued: 0, filtered: 0, endOfCandidates: 0 }

  if (!shouldSignalCandidate(candidate)) {
    hook.__iceDiagnostics.filtered += 1
    hook.__diagnostics = { ...(hook.__diagnostics || {}), iceSignaling: hook.__iceDiagnostics }
    return
  }

  const message = { type: "ice_candidate", data: candidate }

  if (hook.__localDescriptionSent) {
    hook.__iceDiagnostics.sent += 1
    if (candidate?.candidate === "") hook.__iceDiagnostics.endOfCandidates += 1
    hook.pushEvent(eventName, message)
  } else {
    hook.__pendingIceCandidates ||= []
    hook.__pendingIceCandidates.push(message)
    hook.__iceDiagnostics.queued += 1
  }

  hook.__diagnostics = { ...(hook.__diagnostics || {}), iceSignaling: hook.__iceDiagnostics }
}

function flushQueuedIceCandidates(hook, eventName) {
  hook.__localDescriptionSent = true

  for (const message of hook.__pendingIceCandidates || []) {
    hook.__iceDiagnostics ||= { sent: 0, queued: 0, filtered: 0, endOfCandidates: 0 }
    hook.__iceDiagnostics.sent += 1
    if (message.data?.candidate === "") hook.__iceDiagnostics.endOfCandidates += 1
    hook.pushEvent(eventName, message)
  }

  hook.__pendingIceCandidates = []
  hook.__diagnostics = { ...(hook.__diagnostics || {}), iceSignaling: hook.__iceDiagnostics }
}

async function deviceSummary() {
  if (!navigator.mediaDevices?.enumerateDevices) return { available: false }

  try {
    const devices = await navigator.mediaDevices.enumerateDevices()
    return {
      available: true,
      devices: devices.map((device) => ({
        kind: device.kind,
        label: device.label || "(hidden until permission is granted)",
        deviceId: device.deviceId ? "present" : "missing",
      })),
    }
  } catch (error) {
    return { available: false, error: describeError(error) }
  }
}

function createSyntheticMediaStream() {
  const canvas = document.createElement("canvas")
  canvas.width = 640
  canvas.height = 360
  const ctx = canvas.getContext("2d")
  let frame = 0

  const draw = () => {
    frame += 1
    const hue = frame % 360
    ctx.fillStyle = `hsl(${hue}, 70%, 16%)`
    ctx.fillRect(0, 0, canvas.width, canvas.height)
    ctx.fillStyle = `hsl(${(hue + 160) % 360}, 90%, 58%)`
    ctx.beginPath()
    ctx.arc(80 + (frame * 5) % 480, 180, 48, 0, Math.PI * 2)
    ctx.fill()
    ctx.fillStyle = "white"
    ctx.font = "24px sans-serif"
    ctx.fillText("Synthetic WebRTC spike stream", 32, 54)
    ctx.font = "16px sans-serif"
    ctx.fillText(new Date().toLocaleTimeString(), 32, 86)
  }

  draw()
  const interval = window.setInterval(draw, 1000 / 15)
  const videoStream = canvas.captureStream(15)
  videoStream.getVideoTracks()[0].addEventListener("ended", () => window.clearInterval(interval))

  const AudioContext = window.AudioContext || window.webkitAudioContext
  if (!AudioContext) return videoStream

  const audioContext = new AudioContext()
  const oscillator = audioContext.createOscillator()
  const gain = audioContext.createGain()
  const destination = audioContext.createMediaStreamDestination()

  oscillator.frequency.value = 440
  gain.gain.value = 0.025
  oscillator.connect(gain)
  gain.connect(destination)
  oscillator.start()

  const stream = new MediaStream([
    ...videoStream.getVideoTracks(),
    ...destination.stream.getAudioTracks(),
  ])

  for (const track of stream.getTracks()) {
    track.addEventListener("ended", () => {
      oscillator.stop()
      audioContext.close().catch(() => {})
      window.clearInterval(interval)
    }, { once: true })
  }

  return stream
}

async function getBestAvailableMedia() {
  const attempts = [
    { label: "camera+microphone", constraints: { audio: true, video: true } },
    { label: "camera-only", constraints: { audio: false, video: true } },
    { label: "microphone-only", constraints: { audio: true, video: false } },
  ]
  const errors = []

  if (!navigator.mediaDevices?.getUserMedia) {
    errors.push({ label: "getUserMedia", error: { message: "navigator.mediaDevices.getUserMedia is unavailable. Use http://localhost or HTTPS." } })
  } else {
    for (const attempt of attempts) {
      try {
        const stream = await navigator.mediaDevices.getUserMedia(attempt.constraints)
        return { stream, label: attempt.label, errors }
      } catch (error) {
        errors.push({ label: attempt.label, error: describeError(error) })
      }
    }
  }

  return { stream: createSyntheticMediaStream(), label: "synthetic-canvas-audio", errors }
}

export function createWebRTCEchoCaptureHook(iceServers = defaultIceServers) {
  return {
    mounted() {
      this.__onStartClick = () => this.startCapture()
      document.getElementById("start-media-button")?.addEventListener("click", this.__onStartClick)
      setText(statusTargetId(this.el.id), "waiting for click")
    },

    async startCapture() {
      if (this.__started) return
      this.__started = true

      let stage = "starting"

      try {
        stage = "requesting media"
        setText(statusTargetId(this.el.id), stage)

        const devicesBefore = await deviceSummary()
        const media = await getBestAvailableMedia()
        const localStream = media.stream
        const syntheticFallback = createSyntheticMediaStream()

        if (localStream.getVideoTracks().length === 0) {
          syntheticFallback.getVideoTracks().forEach((track) => localStream.addTrack(track))
          media.label = `${media.label}+synthetic-video`
        }

        if (localStream.getAudioTracks().length === 0) {
          syntheticFallback.getAudioTracks().forEach((track) => localStream.addTrack(track))
          media.label = `${media.label}+synthetic-audio`
        }

        stage = "creating peer connection"
        this.pc = new RTCPeerConnection({ iceServers })
        attachCommonPeerHandlers(this, this.pc, "capture")

        this.pc.onicecandidate = (event) => {
          queueOrPushIceCandidate(
            this,
            "webrtc_capture_signaling",
            event.candidate || endOfCandidates()
          )
        }

        this.el.srcObject = new MediaStream()

        for (const track of localStream.getTracks()) {
          this.pc.addTrack(track, localStream)
          this.el.srcObject.addTrack(track)
        }

        this.__diagnostics = {
          stage: "media acquired",
          mediaSource: media.label,
          getUserMediaErrors: media.errors,
          devicesBefore,
          tracks: localStream.getTracks().map((track) => ({ kind: track.kind, label: track.label, enabled: track.enabled })),
        }

        setText(statsTargetId(this.el.id), JSON.stringify({
          status: "media acquired",
          ...this.__diagnostics,
        }, null, 2))

        await this.el.play().catch(() => {})

        stage = "waiting for Membrane answer"
        this.handleEvent(`webrtc_signaling-${this.el.id}`, async (event) => {
          const { type, data } = event

          try {
            if (type === "sdp_answer") {
              await this.pc.setRemoteDescription(data)
            } else if (type === "ice_candidate" && data) {
              await this.pc.addIceCandidate(data)
            }
          } catch (error) {
            const diagnostics = { stage: `handling ${type}`, error: describeError(error), event }
            ensureMonitor()[this.el.id] = diagnostics
            setText(statusTargetId(this.el.id), "signaling error")
            setText(statsTargetId(this.el.id), JSON.stringify(diagnostics, null, 2))
            console.error(`[${this.el.id}] signaling failed`, diagnostics)
          }

          renderSummary(this.el.id, this.pc, { role: "capture" })
        })

        stage = "creating offer"
        const offer = await this.pc.createOffer()
        stage = "setting local offer"
        await this.pc.setLocalDescription(offer)
        stage = "sending offer"
        this.__diagnostics = {
          ...(this.__diagnostics || {}),
          stage,
          localSdp: sdpDiagnostics(this.pc.localDescription || offer)
        }
        this.pushEvent("webrtc_capture_signaling", {
          type: "sdp_offer",
          data: mungeSessionDescription(this.pc.localDescription || offer)
        })
        flushQueuedIceCandidates(this, "webrtc_capture_signaling")
      } catch (error) {
        this.__started = false
        const diagnostics = {
          id: this.el.id,
          role: "capture",
          stage,
          error: describeError(error),
          secureContext: window.isSecureContext,
          location: window.location.href,
          devices: await deviceSummary(),
        }
        ensureMonitor()[this.el.id] = diagnostics
        setText(statusTargetId(this.el.id), "failed")
        setText(statsTargetId(this.el.id), `Capture setup failed:\n${JSON.stringify(diagnostics, null, 2)}`)
        console.error(`[${this.el.id}] capture setup failed`, error)
      }
    },

    destroyed() {
      document.getElementById("start-media-button")?.removeEventListener("click", this.__onStartClick)
      if (this.__statsInterval) window.clearInterval(this.__statsInterval)
      stopTracks(this.el)
      if (this.pc) this.pc.close()
    }
  }
}

export function createWebRTCEchoPlayerHook(iceServers = defaultIceServers) {
  return {
    mounted() {
      this.pc = new RTCPeerConnection({ iceServers })
      this.el.srcObject = new MediaStream()
      attachCommonPeerHandlers(this, this.pc, "player")

      this.pc.ontrack = (event) => {
        this.el.srcObject.addTrack(event.track)
        this.__diagnostics = {
          status: "received remote track",
          track: { kind: event.track.kind, label: event.track.label, muted: event.track.muted, readyState: event.track.readyState },
          streamTrackCounts: event.streams.map((stream) => stream.getTracks().length),
        }
        setText(statsTargetId(this.el.id), JSON.stringify(this.__diagnostics, null, 2))
        this.el.play().catch((error) => {
          setText(statsTargetId(this.el.id), `Player autoplay failed: ${error.message}`)
        })
      }

      this.pc.onicecandidate = (event) => {
        queueOrPushIceCandidate(
          this,
          "webrtc_player_signaling",
          event.candidate || endOfCandidates()
        )
      }

      this.handleEvent(`webrtc_signaling-${this.el.id}`, async (event) => {
        const { type, data } = event

        try {
          if (type === "sdp_offer") {
            await this.pc.setRemoteDescription(data)
            const answer = await this.pc.createAnswer()
            await this.pc.setLocalDescription(answer)
            this.__diagnostics = {
              ...(this.__diagnostics || {}),
              remoteSdp: sdpDiagnostics(data),
              localSdp: sdpDiagnostics(this.pc.localDescription || answer)
            }
            this.pushEvent("webrtc_player_signaling", {
              type: "sdp_answer",
              data: mungeSessionDescription(this.pc.localDescription || answer)
            })
            flushQueuedIceCandidates(this, "webrtc_player_signaling")
          } else if (type === "ice_candidate" && data) {
            await this.pc.addIceCandidate(data)
          }

          renderSummary(this.el.id, this.pc, { role: "player" })
        } catch (error) {
          const diagnostics = { stage: `player handling ${type}`, error: describeError(error), event }
          ensureMonitor()[this.el.id] = diagnostics
          setText(statusTargetId(this.el.id), "signaling error")
          setText(statsTargetId(this.el.id), JSON.stringify(diagnostics, null, 2))
          console.error(`[${this.el.id}] signaling failed`, diagnostics)
        }
      })
    },

    destroyed() {
      if (this.__statsInterval) window.clearInterval(this.__statsInterval)
      stopTracks(this.el)
      if (this.pc) this.pc.close()
    }
  }
}
