// A private source-to-receiver protocol. A peer belongs to exactly one source generation.
export const BLOCK = 256 * 1024;
export const CACHE = 16 * 1024 * 1024;
export const HIGH = 256 * 1024;
export const LOW = 64 * 1024;
export const HEADER = 12;
export const MESSAGE = 16 * 1024;

export class BlockCache {
  constructor(limit = CACHE) { this.limit = limit; this.bytes = 0; this.items = new Map(); }
  get(key) {
    const value = this.items.get(key);
    if (value) { this.items.delete(key); this.items.set(key, value); }
    return value;
  }
  put(key, value) {
    if (this.items.has(key)) this.bytes -= this.items.get(key).byteLength;
    this.items.delete(key); this.items.set(key, value); this.bytes += value.byteLength;
    while (this.bytes > this.limit) { const key = this.items.keys().next().value; this.bytes -= this.items.get(key).byteLength; this.items.delete(key); }
  }
  clear() { this.items.clear(); this.bytes = 0; }
}

// One scheduler shared by all source peers gives every receiver a turn per fragment.
export function createSender(file, generation, onBytes = () => {}) {
  const peers = new Set();
  let scheduled = false, closed = false;
  const schedule = () => {
    if (scheduled || closed) return;
    scheduled = true;
    queueMicrotask(pump);
  };
  const pump = () => {
    scheduled = false;
    let progress;
    do {
      progress = false;
      for (const peer of peers) {
        if (peer.channel.readyState !== 'open') continue;
        const job = peer.jobs.values().next().value;
        if (!job) continue;
        if (!job.bytes) {
          if (!job.reading) {
            job.reading = true;
            void file.slice(job.start, job.end).arrayBuffer().then(bytes => {
              if (peer.jobs.get(job.id) !== job || closed) return;
              job.bytes = new Uint8Array(bytes); schedule();
            }).catch(() => peer.channel.close());
          }
          continue;
        }
        const limit = Math.min(MESSAGE, peer.maxMessage() || MESSAGE);
        if (limit <= HEADER) { peer.channel.close(); continue; }
        const count = Math.min(limit - HEADER, job.bytes.length - job.offset);
        if (peer.channel.bufferedAmount + HEADER + count > HIGH) continue;
        const frame = new Uint8Array(HEADER + count), view = new DataView(frame.buffer);
        view.setUint32(0, generation); view.setUint32(4, job.id); view.setUint32(8, job.offset);
        frame.set(job.bytes.subarray(job.offset, job.offset + count), HEADER);
        try { peer.channel.send(frame.buffer); } catch { peer.channel.close(); continue; }
        onBytes(frame.byteLength);
        job.offset += count;
        if (job.offset === job.bytes.length) peer.jobs.delete(job.id);
        progress = true;
      }
    } while (progress && !closed);
  };
  return {
    attach(channel, maxMessage = () => MESSAGE) {
      const peer = {channel, jobs: new Map(), maxMessage}; peers.add(peer);
      channel.bufferedAmountLowThreshold = LOW;
      channel.addEventListener('bufferedamountlow', schedule);
      channel.addEventListener('message', ({data}) => {
        try {
          if (typeof data !== 'string' || data.length > 512) throw Error('Invalid request');
          const msg = JSON.parse(data);
          if (msg.generation !== generation || !Number.isInteger(msg.id) || msg.id < 1 || msg.id > 0xffffffff) throw Error('Stale request');
          if (msg.type === 'cancel') { peer.jobs.delete(msg.id); schedule(); return; }
          if (msg.type !== 'block' || !Number.isInteger(msg.index) || msg.index < 0 || msg.index * BLOCK >= file.size || peer.jobs.size >= 4 || peer.jobs.has(msg.id)) throw Error('Invalid block');
          const start = msg.index * BLOCK;
          peer.jobs.set(msg.id, {id: msg.id, start, end: Math.min(file.size, start + BLOCK), offset: 0});
          schedule();
        } catch { channel.close(); }
      });
      const detach = () => { peer.jobs.clear(); peers.delete(peer); };
      channel.addEventListener('close', detach, {once: true});
      return detach;
    },
    close() { closed = true; for (const peer of peers) { peer.jobs.clear(); peer.channel.close(); } peers.clear(); },
  };
}

export function createReceiver(channel, size, generation, cache = new BlockCache()) {
  const pending = new Map(), queue = [];
  let serial = 0, receivedBytes = 0, closed = false;
  channel.binaryType = 'arraybuffer';
  const send = value => channel.send(JSON.stringify({...value, generation}));
  const pump = () => {
    if (closed || channel.readyState !== 'open') return;
    while (queue.length && pending.size < 4) {
      const job = queue.shift();
      job.bytes = new Uint8Array(Math.min(BLOCK, size - job.index * BLOCK));
      pending.set(job.id, job);
      job.timer = setTimeout(() => fail(job, Error('File source timed out')), 30000);
      send({type: 'block', id: job.id, index: job.index});
    }
  };
  const fail = (job, error) => {
    clearTimeout(job.timer); pending.delete(job.id);
    const index = queue.indexOf(job); if (index >= 0) queue.splice(index, 1);
    if (channel.readyState === 'open') send({type: 'cancel', id: job.id});
    job.reject(error); pump();
  };
  const close = () => {
    if (closed) return;
    closed = true;
    for (const job of [...pending.values(), ...queue]) fail(job, Error('File connection closed'));
  };
  channel.addEventListener('open', pump);
  channel.addEventListener('close', close);
  channel.addEventListener('message', ({data}) => {
    try {
      if (!(data instanceof ArrayBuffer) || data.byteLength <= HEADER || data.byteLength > MESSAGE) throw Error('Invalid frame');
      const view = new DataView(data), id = view.getUint32(4), offset = view.getUint32(8);
      if (view.getUint32(0) !== generation) throw Error('Stale frame');
      const job = pending.get(id);
      // Already cancelled in-flight frames are harmless and never enter the cache.
      if (!job) return;
      const bytes = new Uint8Array(data, HEADER);
      if (offset !== job.offset || offset + bytes.length > job.bytes.length) throw Error('Invalid block');
      receivedBytes += bytes.length;
      job.bytes.set(bytes, offset); job.offset += bytes.length;
      if (job.offset === job.bytes.length) {
        clearTimeout(job.timer); pending.delete(id); cache.put(job.index, job.bytes);
        job.resolve(job.bytes); pump();
      }
    } catch { channel.close(); close(); }
  });
  return {
    cache,
    block(index, signal) {
      if (!Number.isInteger(index) || index < 0 || index * BLOCK >= size || closed || signal?.aborted) return Promise.reject(Error('Range unavailable'));
      const hit = cache.get(index); if (hit) return Promise.resolve(hit);
      // Range streams share the cache, but have independently cancellable requests.
      if (queue.length + pending.size >= 12) return Promise.reject(Error('Too many range requests'));
      return new Promise((resolve, reject) => {
        const job = {id: ++serial, index, offset: 0, resolve, reject};
        const abort = () => fail(job, Error('Range cancelled'));
        signal?.addEventListener('abort', abort, {once: true});
        job.resolve = bytes => { signal?.removeEventListener('abort', abort); resolve(bytes); };
        job.reject = error => { signal?.removeEventListener('abort', abort); reject(error); };
        queue.unshift(job); pump();
      });
    },
    close,
    get outstanding() { return pending.size; },
    get receivedBytes() { return receivedBytes; },
  };
}
