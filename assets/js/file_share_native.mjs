// Scoped browser resources and byte delivery only. FileShareState/FileSharePeer
// decide selection, membership, signaling order, retries and restoration in Elixir.
import {BLOCK, BlockCache, createReceiver, createSender} from './file_protocol.mjs';

export function createFileShare(env = globalThis) {
  let generation = 0, sequence = 0, version = 0, scope, source, mode, selected, sender, reader;
  let capability, mediaURL, sentBytes = 0;
  const pageId = env.crypto?.randomUUID?.();
  const peers = new Map(), files = new Map(), ice = new Map(), timers = new Map();
  const cache = new BlockCache(), urls = new Set(), ports = new Map(), waiters = new Set();
  const current = value => value === generation;
  const key = value => value && `${value.id}:${value.generation}`;
  const owns = () => selected && source && selected.source_id === source.id && selected.source_generation === source.generation;
  const emit = (event, values = {}) => env.Hologram?.dispatchAction('share_native', 'video-panel', {generation, event, ...values});
  const peerCurrent = peer => peers.get(peer.group) === peer;
  const failPorts = () => { for (const stop of ports.values()) stop(); ports.clear(); };
  const cancelTimer = (group, name) => {
    const id = `${group}/${name}`; clearTimeout(timers.get(id)); timers.delete(id);
  };
  const closePeer = group => {
    const peer = peers.get(group); if (!peer) return;
    peers.delete(group);
    for (const [id, timer] of timers) if (id.startsWith(`${group}/`)) { clearTimeout(timer); timers.delete(id); }
    if (reader === peer.reader) { reader = null; failPorts(); }
    peer.reader?.close(); peer.detach?.();
    for (const channel of peer.channels.values()) channel.close();
    peer.pc.close();
  };
  const stopTransfers = () => {
    version++;
    for (const waiter of waiters) waiter.reject(Error('File connection changed. Retry playback.'));
    waiters.clear();
    for (const group of [...peers.keys()]) closePeer(group);
    sender?.close(); sender = null; reader = null; failPorts(); cache.clear();
    for (const url of urls) env.URL.revokeObjectURL(url);
    urls.clear(); capability = null; mediaURL = null;
  };
  const releaseFile = handle => {
    const file = files.get(handle); if (!file) return;
    files.delete(handle); file.cancel?.();
  };
  const suspend = (minimum = 0) => {
    generation = Math.max(generation, minimum) + 1; stopTransfers(); source = null;
    for (const timer of timers.values()) clearTimeout(timer);
    timers.clear(); ice.clear();
    for (const handle of [...files.keys()]) releaseFile(handle);
    return generation;
  };
  const release = (minimum = 0) => { suspend(minimum); selected = null; scope = null; return generation; };
  const start = (next, minimum = 0) => {
    const sameScope = scope && next.room_id === scope.room_id && next.epoch === scope.epoch && next.self_id === scope.self_id;
    if (sameScope) suspend(minimum); else release(minimum);
    scope = next;
    return {generation, retained: selected ? {handle: selected.handle, source_id: selected.source_id, source_generation: selected.source_generation} : null};
  };
  const ready = () => source?.available && (mode === 'source' ? owns() : reader?.channel?.readyState === 'open');
  const wake = () => {
    if (!ready()) return;
    for (const waiter of waiters) waiter.resolve(); waiters.clear();
  };
  const configureSource = (expected, descriptor, deliveryMode) => {
    if (!current(expected)) return;
    stopTransfers(); source = descriptor; mode = deliveryMode;
    if (!owns() || mode !== 'source') selected = null;
    if (source?.available && mode === 'source' && owns()) sender = createSender(selected.file, source.generation, count => { sentBytes += count; });
    wake();
  };
  const adoptFile = (expected, handle, descriptor) => {
    if (!current(expected)) return;
    const entry = files.get(handle); if (!entry) return;
    files.delete(handle);
    selected = {file: entry.file, handle, source_id: descriptor.id, source_generation: descriptor.generation};
    if (source?.available && mode === 'source' && owns() && !sender) sender = createSender(selected.file, source.generation, count => { sentBytes += count; });
    wake();
  };
  const choose = (expected, request) => {
    if (!current(expected)) return;
    const input = env.document.createElement('input'); input.type = 'file'; input.accept = 'video/mp4,video/webm';
    input.onchange = () => {
      if (!current(expected) || !input.files?.[0]) return;
      const file = input.files[0], handle = `file:${++sequence}`;
      files.set(handle, {file});
      emit('chosen', {request, handle, name: file.name.slice(0, 255), size: file.size});
    };
    input.click();
  };
  const inspect = (expected, request, handle) => {
    if (!current(expected)) return;
    const entry = files.get(handle); if (!entry) return;
    let worker, timer;
    const valid = () => current(expected) && files.get(handle) === entry;
    const finish = (status, result, reason) => {
      clearTimeout(timer); worker?.terminate(); entry.cancel = null;
      if (valid()) emit('inspected', {request, status, result, reason});
    };
    try {
      worker = new env.Worker('/assets/js/media-inspector-worker.js', {type: 'module'});
      entry.cancel = () => { clearTimeout(timer); worker.terminate(); };
      timer = setTimeout(() => finish('error', null, 'inspection_timeout'), 10000);
      worker.onmessage = ({data}) => data.error ? finish('error', null, data.error) : finish('ok', data);
      worker.onerror = () => finish('error', null, 'inspection_failed');
      worker.postMessage({file: entry.file});
    } catch { finish('error', null, 'inspection_failed'); }
  };
  const channelOpen = peer => {
    if (!peerCurrent(peer) || !peer.bound || peer.channel.readyState !== 'open' || peer.openReported) return;
    peer.openReported = true; wake(); emit('channel_open', peer.metadata);
  };
  const retainChannel = (peer, channel) => {
    if (peer.channels.size >= 1) { channel.close(); return null; }
    const handle = `channel:${++sequence}`;
    peer.channels.set(handle, channel);
    channel.onopen = () => channelOpen(peer);
    channel.onclose = () => { if (peerCurrent(peer)) emit('channel_closed', peer.metadata); };
    return handle;
  };
  const bindChannel = (expected, group, handle) => {
    const peer = peers.get(group); if (!current(expected) || !peer) return;
    const channel = peer.channels.get(handle);
    if (!channel || channel.label !== 'review-file-v1' || channel.ordered !== true || channel.maxRetransmits != null || channel.maxPacketLifeTime != null) { channel?.close(); return; }
    if (peer.bound) return;
    peer.channel = channel; peer.bound = true;
    if (mode === 'source') {
      if (!sender) { channel.close(); return; }
      peer.detach = sender.attach(channel, () => peer.pc.sctp?.maxMessageSize);
    } else {
      peer.reader = createReceiver(channel, source.size, source.generation, cache);
      peer.reader.channel = channel; reader = peer.reader;
    }
    channelOpen(peer);
  };
  const operation = (group, op, args, metadata) => {
    if (op === 'create') {
      const config = ice.get(args.ice_ref); if (!config) throw Error('Released ICE configuration');
      const pc = new env.RTCPeerConnection(config);
      const peer = {pc, group, channels: new Map(), metadata: {group, peer: metadata.peer}};
      peers.set(group, peer);
      pc.onicecandidate = ({candidate}) => { if (candidate && peerCurrent(peer)) emit('ice', {...peer.metadata, candidate: candidate.toJSON()}); };
      pc.onconnectionstatechange = () => { if (peerCurrent(peer)) emit('connection', {...peer.metadata, status: pc.connectionState}); };
      pc.ondatachannel = ({channel}) => {
        if (!peerCurrent(peer)) { channel.close(); return; }
        const handle = retainChannel(peer, channel);
        if (handle) emit('channel', {...peer.metadata, handle});
      };
      return null;
    }
    const peer = peers.get(group); if (!peer) throw Error('Released file peer');
    const pc = peer.pc;
    switch (op) {
      case 'create_channel': return retainChannel(peer, pc.createDataChannel('review-file-v1', {ordered: true}));
      case 'create_offer': return pc.createOffer();
      case 'create_answer': return pc.createAnswer();
      case 'set_local': return pc.setLocalDescription(args);
      case 'set_remote': return pc.setRemoteDescription(args);
      case 'description': return {type: pc.localDescription.type, sdp: pc.localDescription.sdp};
      case 'add_candidate': return pc.addIceCandidate(args);
      case 'configure': {
        const config = ice.get(args.ice_ref); if (!config) throw Error('Released ICE configuration');
        return pc.setConfiguration({...pc.getConfiguration(), ...config});
      }
      default: throw Error('Unknown native operation');
    }
  };
  const run = (expected, group, op, args, metadata) => {
    if (!current(expected)) return;
    let result;
    try { result = operation(group, op, args, metadata); }
    catch { emit('operation', {...metadata, group, status: 'error', result: null}); return; }
    const peer = peers.get(group);
    Promise.resolve(result).then(result => {
      if (current(expected) && peers.get(group) === peer) emit('operation', {...metadata, group, status: 'ok', result: result ?? null});
    }, () => { if (current(expected) && peers.get(group) === peer) emit('operation', {...metadata, group, status: 'error', result: null}); });
  };
  const registerWorker = async () => {
    const workers = env.navigator?.serviceWorker;
    if (!workers) throw Error('Direct file sharing needs a secure browser with service worker support.');
    await workers.register('/local-media-sw.js', {scope: '/', updateViaCache: 'none'});
    await workers.ready;
    if (!workers.controller) await new Promise((resolve, reject) => {
      const changed = () => { if (workers.controller) { clearTimeout(timer); workers.removeEventListener('controllerchange', changed); resolve(); } };
      const timer = setTimeout(() => { workers.removeEventListener('controllerchange', changed); reject(Error('File player setup timed out. Retry playback.')); }, 10000);
      workers.addEventListener('controllerchange', changed); changed();
    });
  };
  const url = async descriptor => {
    const v = version;
    if (!scope || key(descriptor) !== key(source) || !source?.available) throw Error('The file source is unavailable. Waiting for its return.');
    if (!env.document.createElement('video').canPlayType(descriptor.codec)) throw Error('This browser cannot decode the selected file.');
    if (mode !== 'source') await registerWorker();
    if (!ready()) await new Promise((resolve, reject) => {
      const waiter = {resolve: () => { clearTimeout(timer); resolve(); }, reject: error => { clearTimeout(timer); reject(error); }};
      const timer = setTimeout(() => { waiters.delete(waiter); reject(Error('Connecting to the file source. Retry playback.')); }, 15000);
      waiters.add(waiter);
    });
    if (v !== version || !ready()) throw Error('File source changed');
    if (mode === 'source') { const url = env.URL.createObjectURL(selected.file); urls.add(url); return url; }
    capability ||= [...env.crypto.getRandomValues(new Uint8Array(32))].map(x => x.toString(16).padStart(2, '0')).join('');
    mediaURL ||= `/__local_media/${source.id}/${source.generation}/${capability}`;
    return mediaURL;
  };
  const rangeRequest = event => {
    if (event.data?.type !== 'local_media_request') return;
    const port = event.ports[0], v = version, descriptor = source;
    if (!port) return;
    if (event.source !== env.navigator.serviceWorker.controller || !source?.available || event.data.path !== mediaURL || !scope || !capability) {
      port.postMessage({type: 'error', message: 'File session expired'}); port.close(); return;
    }
    const abort = new AbortController();
    const stop = () => { abort.abort(); ports.delete(port); port.close(); };
    if (ports.size >= 8) ports.values().next().value();
    ports.set(port, stop);
    port.onmessage = async ({data}) => {
      if (data.type === 'cancel') { stop(); return; }
      if (v !== version || abort.signal.aborted || data.type !== 'read' || !Number.isSafeInteger(data.offset) || !Number.isSafeInteger(data.end) || data.offset < 0 || data.end >= descriptor.size || data.end < data.offset) { stop(); return; }
      if (port.reading) return; port.reading = true;
      try {
        if (!reader) throw Error('File connection unavailable');
        const block = await reader.block(Math.floor(data.offset / BLOCK), abort.signal);
        if (v !== version || abort.signal.aborted) return;
        const start = data.offset % BLOCK;
        const chunk = block.slice(start, Math.min(block.length, start + data.end - data.offset + 1));
        port.postMessage({type: 'chunk', bytes: chunk.buffer}, [chunk.buffer]);
      } catch { if (!abort.signal.aborted) { port.postMessage({type: 'error', message: 'File connection unavailable'}); stop(); } }
      finally { port.reading = false; }
    };
    port.postMessage({type: 'metadata', size: source.size, mime: source.mime});
  };
  env.navigator?.serviceWorker?.addEventListener('message', rangeRequest);
  env.addEventListener?.('pagehide', release);
  if (env.document) env.setInterval?.(() => {
    if (source && scope) emit('metrics', {source_id: source.id, sent_bytes: sentBytes, at: env.performance.now()});
  }, 1000);
  return {
    start, suspend, release, current, configureSource, adoptFile, choose, inspect, run, bindChannel, closePeer, url,
    pageId: () => pageId,
    canDecode: codec => !!env.document.createElement('video').canPlayType(codec),
    releaseFile,
    keepIce(expected, servers) { if (!current(expected)) return null; const ref = `ice:${++sequence}`; ice.set(ref, {iceServers: servers}); return ref; },
    releaseIce: ref => ice.delete(ref),
    later(expected, group, name, delay, metadata) {
      if (!current(expected)) return;
      cancelTimer(group, name); const id = `${group}/${name}`;
      timers.set(id, setTimeout(() => { timers.delete(id); if (current(expected)) emit(metadata.event, {...metadata, group}); }, delay));
    },
    cancelTimer,
    revokeURL(value) { if (urls.delete(value)) env.URL.revokeObjectURL(value); },
    get diagnostics() { return {cacheBytes: cache.bytes, peers: peers.size, ranges: ports.size, sourceId: source?.id, available: source?.available, sentBytes, receivedBytes: reader?.receivedBytes || 0, hasFile: !!selected}; },
  };
}
export default globalThis.ReviewFileShare ||= createFileShare();
