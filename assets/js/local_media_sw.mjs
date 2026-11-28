import {rangeResponse} from './local_media_range.mjs';
const PREFIX = '/__local_media/';
self.addEventListener('install', event => event.waitUntil(self.skipWaiting()));
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));
// The worker holds no authoritative room state. Every request consults its own tab.
export async function localResponse(event, clients = self.clients) {
  const request = event.request, url = new URL(request.url);
  const headers = {'Cache-Control': 'no-store', 'Accept-Ranges': 'bytes', 'X-Content-Type-Options': 'nosniff'};
  if (!['GET', 'HEAD'].includes(request.method)) return new Response(null, {status: 405, headers: {...headers, Allow: 'GET, HEAD'}});
  const client = event.clientId && await clients.get(event.clientId);
  if (!client) return new Response(null, {status: 403, headers});
  const {port1: port, port2} = new MessageChannel();
  let waiter, cancelled = false;
  const receive = () => new Promise((resolve, reject) => {
    const timer = setTimeout(() => { waiter = null; reject(Error('Source unavailable')); }, 30000);
    waiter = {resolve: data => { clearTimeout(timer); waiter = null; resolve(data); }, reject: error => { clearTimeout(timer); waiter = null; reject(error); }};
  });
  const cancel = () => {
    if (cancelled) return;
    cancelled = true; port.postMessage({type: 'cancel'}); port.close(); waiter?.reject(Error('Range cancelled'));
  };
  port.onmessage = ({data}) => {
    if (data.type === 'error') waiter?.reject(Error(data.message));
    else waiter?.resolve(data);
  };
  request.signal.addEventListener('abort', cancel, {once: true});
  try {
    const metadata = receive();
    client.postMessage({type: 'local_media_request', path: url.pathname}, [port2]);
    const meta = await metadata;
    if (meta.type !== 'metadata' || !['video/mp4', 'video/webm'].includes(meta.mime)) throw Error('Invalid media');
    headers['Content-Type'] = meta.mime;
    const range = rangeResponse(request.headers.get('range'), meta.size);
    headers['Content-Length'] = String(range.length);
    if (range.status === 416) headers['Content-Range'] = `bytes */${meta.size}`;
    if (range.status === 206) headers['Content-Range'] = `bytes ${range.start}-${range.end}/${meta.size}`;
    if (request.method === 'HEAD' || range.status === 416) {
      cancel(); return new Response(null, {status: range.status, headers});
    }
    let offset = range.start;
    const stream = new ReadableStream({
      async pull(controller) {
        try {
          if (offset > range.end) { controller.close(); cancel(); return; }
          const response = receive();
          port.postMessage({type: 'read', offset, end: range.end});
          const data = await response;
          if (data.type !== 'chunk' || !(data.bytes instanceof ArrayBuffer) || !data.bytes.byteLength || data.bytes.byteLength > Math.min(262144, range.end - offset + 1)) throw Error('Invalid range data');
          offset += data.bytes.byteLength; controller.enqueue(new Uint8Array(data.bytes));
          if (offset > range.end) { controller.close(); cancel(); }
        } catch (error) { controller.error(error); cancel(); }
      },
      cancel,
    }, {highWaterMark: 0});
    return new Response(stream, {status: range.status, headers});
  } catch {
    cancel(); return new Response(null, {status: 503, headers});
  }
}
self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);
  if (url.origin === self.location.origin && url.pathname.startsWith(PREFIX)) event.respondWith(localResponse(event));
});
