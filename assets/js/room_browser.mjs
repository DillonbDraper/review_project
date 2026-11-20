// Native resources only. Hologram owns room/chat state and all recovery policy.
import {Socket} from "../../deps/phoenix/priv/static/phoenix.mjs";
import ConferenceNative from "./conference_native.mjs";

function browser() {
  let host, transport;
  const memory = new Map();
  const dispatch = (action, target, params = {}) => globalThis.Hologram?.dispatchAction(action, target, params);
  const read = id => {
    try { return JSON.parse(sessionStorage.getItem(`review-room:${id}`)) || {}; }
    catch { return memory.get(id) || {}; }
  };
  const save = (id, values) => {
    const next = {...read(id), ...values};
    memory.set(id, next);
    try { sessionStorage.setItem(`review-room:${id}`, JSON.stringify(next)); } catch {}
  };
  const disconnect = () => {
    ConferenceNative.invalidate();
    const prior = transport;
    transport = null;
    prior?.channel.leave();
    prior?.socket.disconnect();
  };
  const mount = () => {
    const next = document.getElementById("room-panel");
    if (next === host) return;
    disconnect();
    host = next;
    if (host) {
      const mounted = host;
      requestAnimationFrame(() => {
        if (host === mounted) dispatch("room_mounted", "room-controls");
      });
    }
  };
  new MutationObserver(mount).observe(document.documentElement, {childList: true, subtree: true});
  globalThis.addEventListener("pagehide", () => disconnect());
  globalThis.addEventListener("pageshow", event => {
    if (event.persisted) { host = null; mount(); }
  });
  queueMicrotask(mount);

  return {
    save, disconnect,
    ready() { if (host) host.dataset.ready = "true"; },
    entry(id) {
      const initial = new URL(performance.getEntriesByType("navigation")[0]?.name || location.href);
      const fragment = location.hash || (initial.pathname === `/rooms/${id}` ? initial.hash : "");
      const invitation = new URLSearchParams(fragment.slice(1)).get("invitation");
      if (invitation) {
        save(id, {invitation});
        history.replaceState(history.state, "", location.pathname + location.search);
      }
      return {...read(id), origin: location.origin};
    },
    navigate(path) { location.assign(path); },
    dialog(id, open) {
      requestAnimationFrame(() => {
        const element = document.getElementById(id);
        if (open && element && !element.open) element.showModal();
        else if (!open) element?.close();
      });
    },
    async copy(id, target, action) {
      const input = document.getElementById(id);
      if (!input) return;
      const mounted = host;
      let copied = false;
      try { await navigator.clipboard.writeText(input.value); copied = true; }
      catch { input.focus(); input.select(); }
      if (host === mounted) dispatch(action, target, {copied});
    },
    async session(generation) {
      const mounted = host;
      const reply = params => {
        if (host === mounted) dispatch("session_result", "room-controls", {generation, ...params});
      };
      if (!navigator.locks) return reply({status: "insecure"});
      try {
        const result = await navigator.locks.request("review-room-session", async () => {
          const response = await fetch("/room-session", {credentials: "same-origin", cache: "no-store"});
          if (!response.ok) throw new Error("Session request failed");
          return response.json();
        });
        reply({status: "ok", result});
      } catch { reply({status: "unavailable"}); }
    },
    connect({generation, path, topic, params, csrf, events}) {
      disconnect();
      const socket = new Socket(path, {params: {_csrf_token: csrf}});
      const channel = socket.channel(topic, params);
      const resource = transport = {socket, channel};
      const report = (type, result = {}) => {
        if (transport === resource) {
          // Release devices before Hologram processes the transport event.
          // Recovery decisions and component-to-component routing live in Elixir.
          if (type === "lost") ConferenceNative.invalidate();
          dispatch("transport", "room-controls", {generation, type, result});
        }
      };
      for (const event of events) channel.on(event, result => report(event, result));
      channel.onError(() => report("lost"));
      channel.onClose(() => report("lost"));
      socket.onClose(() => report("lost"));
      const joining = channel.join();
      joining.receive("ok", result => report("joined", result));
      joining.receive("error", result => report("refused", result));
      joining.receive("timeout", () => report("lost"));
      socket.connect();
    },
    push(event, payload, target, action, metadata) {
      const resource = transport;
      if (!resource) {
        dispatch(action, target, {...metadata, status: "error", result: {reason: "not_joined"}});
        return;
      }
      const pending = resource.channel.push(event, payload);
      for (const status of ["ok", "error", "timeout"]) {
        pending.receive(status, result => {
          if (transport === resource) dispatch(action, target, {...metadata, status, result: result || {}});
        });
      }
    },
    viewport() {
      const log = document.getElementById("chat-messages");
      if (!log) return {bottom: true};
      const top = log.getBoundingClientRect().top;
      const first = [...log.querySelectorAll(".chat-message")].find(el => el.getBoundingClientRect().bottom > top);
      return {bottom: log.scrollHeight - log.scrollTop - log.clientHeight < 60,
        id: first?.id || "", offset: first ? first.getBoundingClientRect().top - top : 0};
    },
    scroll(position, bottom) {
      requestAnimationFrame(() => {
        const log = document.getElementById("chat-messages");
        if (!log) return;
        if (bottom) log.scrollTop = log.scrollHeight;
        else if (position.id) {
          const anchor = document.getElementById(position.id);
          if (anchor) log.scrollTop += anchor.getBoundingClientRect().top - log.getBoundingClientRect().top - position.offset;
        }
      });
    },
    time(iso) { return new Intl.DateTimeFormat(undefined, {hour: "numeric", minute: "2-digit"}).format(new Date(iso)); },
  };
}

// Both app.js and lazy Hologram chunks may import this module. Native resources
// belong to the document, including when Hologram restores a page snapshot.
export default globalThis.ReviewRoomBrowser ||= browser();
