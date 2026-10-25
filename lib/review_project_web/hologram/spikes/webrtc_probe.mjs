const registry = new Map()
let nextId = 1

function safeState(value) {
  return value || "unknown"
}

class LoopbackProbe {
  constructor(mode, id, target = "page") {
    this.mode = mode
    this.id = id
    this.target = target
    this.status = "created"
    this.pc1 = null
    this.pc2 = null
    this.localChannel = null
    this.remoteChannel = null
    this.pingsSent = 0
    this.pongsReceived = 0
    this.lastMessage = "—"
    this.error = "—"
    this.ready = false
    this.closed = false
    this.eventCount = 0
    this.lastEvent = "created"
    this.iceCandidateEvents = 0
    this.connectionStateEvents = 0
    this.iceConnectionStateEvents = 0
    this.dataChannelEvents = 0
    this.messageEvents = 0
  }

  dispatch(eventType = "snapshot") {
    this.eventCount += 1
    this.lastEvent = eventType
    globalThis.Hologram?.dispatchAction(`${this.mode}_webrtc_event`, this.target, this.snapshot())
  }

  snapshot() {
    return {
      probe_id: this.id,
      ready: this.ready,
      status: this.status,
      pc1_state: safeState(this.pc1?.connectionState),
      pc2_state: safeState(this.pc2?.connectionState),
      pc1_ice_state: safeState(this.pc1?.iceConnectionState),
      pc2_ice_state: safeState(this.pc2?.iceConnectionState),
      ice_state: `${safeState(this.pc1?.iceConnectionState)} / ${safeState(this.pc2?.iceConnectionState)}`,
      channel_state: safeState(this.localChannel?.readyState),
      pings_sent: this.pingsSent,
      pongs_received: this.pongsReceived,
      last_message: this.lastMessage,
      error: this.error,
      event_count: this.eventCount,
      last_event: this.lastEvent,
      ice_candidate_events: this.iceCandidateEvents,
      connection_state_events: this.connectionStateEvents,
      ice_connection_state_events: this.iceConnectionStateEvents,
      datachannel_events: this.dataChannelEvents,
      message_events: this.messageEvents
    }
  }

  async start() {
    try {
      this.status = "starting"
      this.dispatch("start")

      this.pc1 = new RTCPeerConnection()
      this.pc2 = new RTCPeerConnection()

      this.pc1.addEventListener("icecandidate", event => {
        this.iceCandidateEvents += 1

        if (event.candidate) {
          this.pc2?.addIceCandidate(event.candidate).catch(error => this.fail(error))
        }

        this.dispatch("pc1 icecandidate")
      })

      this.pc2.addEventListener("icecandidate", event => {
        this.iceCandidateEvents += 1

        if (event.candidate) {
          this.pc1?.addIceCandidate(event.candidate).catch(error => this.fail(error))
        }

        this.dispatch("pc2 icecandidate")
      })

      for (const pc of [this.pc1, this.pc2]) {
        pc.addEventListener("connectionstatechange", () => {
          this.connectionStateEvents += 1
          this.status = `connection ${this.pc1.connectionState}/${this.pc2.connectionState}`
          this.dispatch("connectionstatechange")
        })

        pc.addEventListener("iceconnectionstatechange", () => {
          this.iceConnectionStateEvents += 1
          this.status = `ice ${this.pc1.iceConnectionState}/${this.pc2.iceConnectionState}`
          this.dispatch("iceconnectionstatechange")
        })
      }

      this.pc2.addEventListener("datachannel", event => {
        this.dataChannelEvents += 1
        this.remoteChannel = event.channel
        this.dispatch("remote datachannel")

        this.remoteChannel.addEventListener("message", messageEvent => {
          this.messageEvents += 1
          const message = String(messageEvent.data)
          this.lastMessage = message

          if (message.startsWith("ping:")) {
            this.remoteChannel.send(`pong:${message.slice(5)}`)
          }

          this.dispatch("remote message")
        })
      })

      this.localChannel = this.pc1.createDataChannel("hologram-loopback")
      this.localChannel.addEventListener("open", () => {
        this.dataChannelEvents += 1
        this.ready = true
        this.status = "datachannel open"
        this.dispatch("local datachannel open")
      })

      this.localChannel.addEventListener("close", () => {
        this.dataChannelEvents += 1
        this.ready = false
        this.status = "datachannel closed"
        this.dispatch("local datachannel close")
      })

      this.localChannel.addEventListener("message", event => {
        this.messageEvents += 1
        const message = String(event.data)
        this.lastMessage = message

        if (message.startsWith("pong:")) {
          this.pongsReceived += 1
        }

        this.dispatch("local message")
      })

      const offer = await this.pc1.createOffer()
      await this.pc1.setLocalDescription(offer)
      await this.pc2.setRemoteDescription(offer)

      const answer = await this.pc2.createAnswer()
      await this.pc2.setLocalDescription(answer)
      await this.pc1.setRemoteDescription(answer)

      this.status = "offer/answer complete"
      this.dispatch("offer/answer complete")
    } catch (error) {
      this.fail(error)
    }
  }

  sendPing() {
    if (!this.localChannel || this.localChannel.readyState !== "open") {
      this.status = "datachannel not open"
      this.dispatch("send ping blocked")
      return this.snapshot()
    }

    this.pingsSent += 1
    const message = `${this.id}:${this.pingsSent}:${Date.now()}`
    this.lastMessage = `ping:${message}`
    this.localChannel.send(`ping:${message}`)
    this.status = "ping sent"
    this.dispatch("send ping")
    return this.snapshot()
  }

  close() {
    this.closed = true
    this.ready = false
    this.status = "closed"

    this.localChannel?.close()
    this.remoteChannel?.close()
    this.pc1?.close()
    this.pc2?.close()

    this.dispatch("close requested")
    return this.snapshot()
  }

  fail(error) {
    this.ready = false
    this.status = "error"
    this.error = error?.message || String(error)
    this.dispatch("error")
  }
}

function lookup(id) {
  return registry.get(id)
}

export default {
  createDirect(target = "page") {
    const probe = new LoopbackProbe("direct", "direct", target)
    probe.start()
    return probe
  },

  sendDirectPing(probe) {
    return probe?.sendPing?.() || { status: "missing direct probe", ready: false }
  },

  closeDirect(probe) {
    return probe?.close?.() || { status: "missing direct probe", ready: false }
  },

  createRegistry(target = "page") {
    const id = `webrtc-registry-${nextId}`
    nextId += 1
    const probe = new LoopbackProbe("registry", id, target)
    registry.set(id, probe)
    probe.start()
    return [id]
  },

  sendRegistryPing(id) {
    return lookup(id)?.sendPing() || { status: "missing registry probe", ready: false }
  },

  closeRegistry(id) {
    const snapshot = lookup(id)?.close() || { status: "missing registry probe", ready: false }
    registry.delete(id)
    return snapshot
  }
}
