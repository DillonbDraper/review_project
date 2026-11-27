// File bytes stay in File objects, never in component state or JSON.
export function createVideoUpload(env = globalThis) {
  let generation = 0, request = 0, xhr, context, staged, token, pending = false;
  let maxBytes = 1073741824, enabled = false;
  const emit = values => env.Hologram?.dispatchAction("upload_status", "video-panel", { generation, room_id: context?.room_id, ...values });
  const path = () => `/room-media/${encodeURIComponent(context.room_id)}`;
  const json = async (url, options = {}) => {
    const response = await env.fetch(url, { credentials: "same-origin", ...options });
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || "request_failed");
    return data;
  };
  const status = async (message) => {
    if (!context?.room_id) return;
    const expected = generation, id = ++request;
    try {
      const data = await json(path());
      if (expected !== generation || id !== request) return;
      staged = data.staged; enabled = data.enabled; maxBytes = data.max_file_bytes || maxBytes;
      emit({ staged, message: message ?? (enabled ? "" : "Uploads are disabled."), progress: 0 });
    } catch (error) { if (expected === generation && id === request) emit({ message: message ?? error.message }); }
  };
  const reset = () => { generation++; request++; const old = xhr; xhr = null; context = null; staged = null; pending = false; token = null; enabled = false; old?.abort(); return generation; };
  const open = value => {
    reset(); context = value;
    if (context.room_id && context.can_control && context.connected) void status();
    return generation;
  };
  const choose = () => {
    if (!context?.can_control || !enabled || staged || pending) return;
    const expected = generation;
    const input = env.document.createElement("input");
    input.type = "file"; input.accept = "video/mp4,video/webm";
    input.onchange = () => { if (expected === generation && input.files?.[0]) void upload(input.files[0]); };
    input.click();
  };
  const upload = async file => {
    const expected = generation;
    if (!context?.can_control || staged || pending) return;
    if (!file.size || file.size > maxBytes || !/\.(mp4|webm)$/i.test(file.name)) {
      emit({ message: "Choose an MP4 (H.264/AAC) or WebM (VP8, VP9 or AV1 with Opus) within the room upload limit." }); return;
    }
    pending = true; request++;
    try {
      const session = await json("/room-session");
      if (expected !== generation) return;
      token = session.csrf_token;
      const req = xhr = new env.XMLHttpRequest();
      req.open("POST", path());
      for (const [key, value] of Object.entries({ "content-type": "application/octet-stream", "x-video-filename": encodeURIComponent(file.name), "x-video-size": String(file.size), "x-csrf-token": token })) req.setRequestHeader(key, value);
      const valid = () => expected === generation && xhr === req;
      const failed = message => { if (!valid()) return; xhr = null; pending = false; emit({ message }); void status(message); };
      req.upload.onprogress = event => { if (valid()) emit({ progress: event.lengthComputable ? Math.round(event.loaded / event.total * 100) : 0, message: "Uploading and validating…" }); };
      req.onload = () => {
        if (!valid()) return;
        try {
          const data = JSON.parse(req.responseText);
          if (req.status < 200 || req.status >= 300) throw new Error(data.error || "upload_failed");
          xhr = null; pending = false; staged = data;
          emit({ staged, progress: 100, completed: true, message: "Upload ready. Opening video…" });
        } catch (error) { failed(`${error.message}. Choose a file to retry.`); }
      };
      req.onerror = () => failed("Upload failed. Choose a file to retry.");
      req.onabort = () => failed("Upload cancelled.");
      req.send(file);
    } catch (error) { if (expected === generation) { pending = false; emit({ message: error.message }); } }
  };
  const cancelRequest = async () => {
    if (!context) return;
    const url = path(), guards = context.guards;
    generation++; request++; const expected = generation, old = xhr; xhr = null; pending = false; old?.abort();
    // Publish the new correlation before any asynchronous callback.
    emit({ message: "Cancelling upload…" });
    let message = "Upload cancelled.";
    try {
      const csrf = token || (await json("/room-session")).csrf_token;
      if (expected !== generation) return;
      await json(url, { method: "DELETE", headers: { "content-type": "application/json", "x-csrf-token": csrf }, body: JSON.stringify(guards) });
    } catch (error) { message = error.message; }
    if (expected === generation) void status(message);
  };
  const cancel = () => { void cancelRequest(); return generation; };
  env.addEventListener?.("pagehide", reset);
  return { open, choose, cancel, reset, status };
}
export default (globalThis.ReviewVideoUpload ||= createVideoUpload());
