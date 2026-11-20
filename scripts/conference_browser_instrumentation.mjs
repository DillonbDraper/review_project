// Enables tests to run for conference rooms in the browser
// Browser-only fault injection and forced relay selection for conference tests.
export function conferenceInstrumentation(mode = "", relayURL = "") {
  return `(() => {
    if (!globalThis.RTCPeerConnection || !navigator.mediaDevices?.getUserMedia) return;
    globalThis.__rtcPeers = [];
    globalThis.__rtcTracks = [];
    globalThis.__captureCalls = [];
    globalThis.__captureModes = {audio: "real", video: "real"};
    const relayMode = ${JSON.stringify(mode)};
    globalThis.__rtcConfigUpdates = [];
    globalThis.__rtcIceErrors = [];
    function configuration(config) {
      if (!relayMode) return config;
      const servers = (config?.iceServers || []).flatMap(server => {
        const urls = (Array.isArray(server.urls) ? server.urls : [server.urls]).filter(url =>
          relayMode === "tls" ? url.startsWith("turns:") : url.startsWith("turn:") && url.endsWith("transport=" + relayMode));
        return urls.length ? [{...server, urls: ${JSON.stringify(relayURL)} ? [${JSON.stringify(relayURL)}] : urls}] : [];
      });
      return {...config, iceServers: servers, iceTransportPolicy: "relay"};
    }
    const NativePeer = globalThis.RTCPeerConnection;
    globalThis.RTCPeerConnection = class extends NativePeer {
      constructor(config) {
        super(configuration(config)); globalThis.__rtcPeers.push(this);
        this.addEventListener('icecandidateerror', event => __rtcIceErrors.push({code: event.errorCode, text: event.errorText, url: event.url}));
      }
      get connectionState() { return this.__testFailed ? "failed" : super.connectionState; }
      close() { this.__testFailed = false; return super.close(); }
      setConfiguration(config) {
        globalThis.__rtcConfigUpdates.push(Date.now());
        return super.setConfiguration(configuration(config));
      }
    };
    const nativeCapture = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
    navigator.mediaDevices.getUserMedia = async request => {
      const kind = request.audio ? "audio" : "video";
      globalThis.__captureCalls.push(kind);
      const mode = globalThis.__captureModes[kind];
      if (mode === "pending") return new Promise(() => {});
      if (mode !== "real") throw new DOMException("Test device failure", mode);
      const stream = await nativeCapture(request);
      globalThis.__rtcTracks.push(...stream.getTracks());
      return stream;
    };
    globalThis.__testSockets = new Set();
    const NativeWebSocket = globalThis.WebSocket;
    globalThis.WebSocket = class extends NativeWebSocket {
      constructor(...args) {
        super(...args);
        globalThis.__testSockets.add(this);
        this.addEventListener('close', () => globalThis.__testSockets.delete(this));
      }
    };
  })();`;
}

// Deliberately excludes SDP, candidates, configuration, and credentials.
export function conferenceTrace() {
  return `(() => {
    globalThis.__rtcTrace = [];
    const record = item => { __rtcTrace.push(item); if (__rtcTrace.length > 200) __rtcTrace.shift(); };
    for (const method of ['sync', 'run']) {
      const original = ReviewConferenceNative[method];
      ReviewConferenceNative[method] = function(generation, group, command, metadata) {
        if (command.op !== 'get' && command.method !== 'getElementById') record({native: method, group, method: command.method || command.op, token: metadata?.token});
        return original.apply(this, arguments);
      };
    }
    const dispatch = Hologram.dispatchAction;
    Hologram.dispatchAction = function(action, target, params = {}) {
      if (target === 'conference-panel' && !['video_play', 'video_status'].includes(params.event)) record({
        action, event: params.event, peer: params.peer || params.signal?.from,
        status: params.status, name: params.name, group: params.group, token: params.token,
        type: params.signal?.data?.type, descriptionType: params.signal?.data?.description?.type,
        reason: params.result?.reason, pair: params.signal?.peer_generation
      });
      return dispatch.apply(this, arguments);
    };
  })()`;
}
