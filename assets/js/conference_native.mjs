// Scoped browser handles only. Conference policy and API sequencing live in Elixir.
// Do not pass native objects through Hologram's permanent NativeValue registry.
function bridge() {
  let generation = 0, sequence = 0;
  const groups = new Map(), objects = new Map(), identities = new WeakMap();
  const dispatch = params => globalThis.Hologram?.dispatchAction("native_result", "conference-panel", params);
  const instance = (value, type) => typeof globalThis[type] === "function" && value instanceof globalThis[type];
  const groupFor = name => {
    if (!groups.has(name)) groups.set(name, {objects: new Set(), listeners: [], timers: new Map()});
    return groups.get(name);
  };
  const release = value => {
    if (instance(value, "MediaStream")) value.getTracks().forEach(track => track.stop());
    else if (instance(value, "MediaStreamTrack")) value.stop();
    else if (instance(value, "RTCPeerConnection")) value.close();
    else if (instance(value, "HTMLMediaElement")) { value.srcObject = null; value.remove(); }
  };
  const pack = (value, group) => {
    if (value == null) return null;
    if (Array.isArray(value)) return value.map(item => pack(item, group));
    if (typeof value !== "object") return value;
    if (typeof value.toJSON === "function") return value.toJSON();
    if (Object.getPrototypeOf(value) === Object.prototype) {
      return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, pack(item, group)]));
    }
    const prior = identities.get(value);
    // A sender can still expose an ended, released capture track. Preserve its
    // identity without acquiring it again under the peer's longer lifetime.
    if (prior && (objects.has(prior) || instance(value, "MediaStreamTrack"))) return prior;
    const id = `native:${++sequence}`;
    identities.set(value, id);
    objects.set(id, value);
    group.objects.add(id);
    return id;
  };
  // Retain plain configuration objects without exposing their secrets to saved
  // component state. The caller receives only a scoped, opaque handle.
  const keep = (value, group) => {
    const id = `native:${++sequence}`;
    objects.set(id, value);
    identities.set(value, id);
    group.objects.add(id);
    return id;
  };
  const unpack = value => {
    if (typeof value === "string" && value.startsWith("native:")) {
      if (!objects.has(value)) throw new Error("Released browser handle");
      return objects.get(value);
    }
    if (Array.isArray(value)) return value.map(unpack);
    if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, unpack(item)]));
    return value;
  };
  const receiver = ref => ({window: globalThis, document, mediaDevices: navigator.mediaDevices})[ref] || unpack(ref);
  const execute = command => {
    const args = unpack(command.args || []);
    if (command.op === "new") return new globalThis[command.type](...args);
    const object = receiver(command.ref);
    if (command.op === "get") return command.path.reduce((value, key) => value?.[key], object);
    if (command.op === "set") { object[command.property] = unpack(command.value); return null; }
    return object[command.method](...args);
  };
  const failure = error => ({status: "error", name: error.name || "Error", result: null});
  const close = name => {
    const group = groups.get(name);
    if (!group) return;
    groups.delete(name);
    for (const timer of group.timers.values()) clearTimeout(timer);
    for (const [object, event, callback] of group.listeners) object.removeEventListener(event, callback);
    // Streams may contain tracks owned by another group. Stop only owned tracks;
    // an unresolved capture is handled separately when its promise settles.
    for (const id of group.objects) {
      const value = objects.get(id);
      if (!instance(value, "MediaStream")) release(value);
      objects.delete(id);
    }
    group.listeners.length = 0;
    group.objects.clear();
    group.timers.clear();
  };
  const reset = next => {
    for (const name of [...groups.keys()]) close(name);
    generation = next;
  };
  return {
    reset, close,
    // Resource epochs belong to the document, outside restored component state.
    invalidate(minimum = 0) {
      reset(Math.max(generation, minimum) + 1);
      return generation;
    },
    supported() { return typeof RTCPeerConnection === "function"; },
    current(value) { return value === generation; },
    sync(value, name, command) {
      if (value !== generation) return failure(new Error("Conference ended"));
      const group = groupFor(name);
      try { return {status: "ok", result: command.op === "keep" ? keep(unpack(command.value), group) : pack(execute(command), group)}; }
      catch (error) { return failure(error); }
    },
    cancel(value, name, key) {
      if (value !== generation) return;
      const timers = groups.get(name)?.timers;
      clearTimeout(timers?.get(key));
      timers?.delete(key);
    },
    later(value, name, key, delay, metadata) {
      if (value !== generation) return;
      const group = groupFor(name);
      clearTimeout(group.timers.get(key));
      group.timers.set(key, setTimeout(() => {
        group.timers.delete(key);
        if (value === generation && groups.get(name) === group) {
          dispatch({generation: value, group: name, status: "ok", result: null, now: Date.now(), ...metadata});
        }
      }, delay));
    },
    run(value, name, command, metadata) {
      if (value !== generation) return;
      const group = groupFor(name);
      let pending;
      try { pending = execute(command); }
      catch (error) { dispatch({generation: value, group: name, ...metadata, ...failure(error)}); return; }
      Promise.resolve(pending).then(result => {
        if (value !== generation || groups.get(name) !== group) { release(result); return; }
        // Own capture tracks immediately, before Elixir receives the stream handle.
        if (instance(result, "MediaStream")) result.getTracks().forEach(track => pack(track, group));
        dispatch({generation: value, group: name, ...metadata, status: "ok", result: pack(result, group)});
      }, error => {
        if (value === generation && groups.get(name) === group) dispatch({generation: value, group: name, ...metadata, ...failure(error)});
      });
    },
    listen(value, name, ref, event, fields, metadata) {
      if (value !== generation) return;
      const group = groupFor(name), object = receiver(ref);
      const callback = nativeEvent => {
        if (value !== generation || groups.get(name) !== group) return;
        const result = Object.fromEntries(fields.map(field => [field, pack(nativeEvent[field], group)]));
        dispatch({generation: value, group: name, ...metadata, status: "ok", result});
      };
      object.addEventListener(event, callback);
      group.listeners.push([object, event, callback]);
    },
  };
}

// room_browser is imported by both app.js and lazy Hologram bundles.
export default globalThis.ReviewConferenceNative ||= bridge();
