// Native player handles browser events only. All playback policy is Elixir.
import FileShare from "./file_share_native.mjs";
import { loadAPI, playerError } from "./youtube_api.mjs";
import ReplayUpload, { createReplayPlayer } from "./replay_native.mjs";

export function createPlaybackNative(env = globalThis) {
  let generation = 0,
    resource,
    host;
  const dispatch = (action, params) =>
    env.Hologram?.dispatchAction(action, "video-panel", params);
  const current = (r) => resource === r && !r.suspended && r.host.isConnected;
  const destroy = () => {
    const r = resource;
    resource = null;
    if (!r) return;
    clearInterval(r.timer);
    clearTimeout(r.timeout);
    r.replayAbort?.abort();
    try {
      r.player?.destroy();
    } catch {}
    r.frame?.remove();
    if (r.host)
      Object.assign(r.host.dataset, { resources: "0", ready: "false" });
  };
  const suspend = () => {
    if (!resource) return;
    resource.replayAbort?.abort();
    resource.suspended = true;
    resource.active = false;
    try {
      resource.player?.pauseVideo();
    } catch {}
  };
  const now = () => env.performance.now();
  const finite = (value, fallback) =>
    Number.isFinite(value) ? value : fallback;
  const actualId = (r) => {
    try {
      return new URL(r.player.getVideoUrl()).searchParams.get("v") || "";
    } catch {
      return "";
    }
  };
  const read = () => {
    const r = resource;
    if (!r || !current(r)) return null;
    const ready = r.ready && !r.preparing && actualId(r) === r.videoId;
    let values = {};
    if (r.ready) {
      const muted = r.provider === "slippi_replay" ? r.muted : r.player.isMuted();
      values = {
        position: finite(r.player.getCurrentTime(), 0),
        duration: finite(r.player.getDuration(), 0),
        state: finite(r.player.getPlayerState(), -1),
        playback_rate: finite(r.player.getPlaybackRate?.(), 1),
        volume: r.provider === "slippi_replay" ? r.volume : finite(r.player.getVolume(), r.volume),
        muted: typeof muted === "boolean" ? muted : r.muted,
        video_id: actualId(r),
        live: r.player.getVideoData?.()?.isLive === true,
      };
    }
    return {
      generation: r.generation,
      now: now(),
      ready,
      blocked: r.blocked,
      error: r.error,
      preparing: r.preparing,
      position: 0,
      duration: 0,
      state: -1,
      volume: r.volume,
      muted: r.muted,
      video_id: "",
      live: false,
      seek_count: r.seekCount,
      ...values,
      hidden: env.document.hidden,
      focused: env.document.activeElement === r.frame,
    };
  };
  const sample = (r) => {
    if (!current(r)) return;
    const values = read();
    Object.assign(r.host.dataset, {
      generation: String(r.generation),
      resources: r.frame ? "1" : "0",
      ready: String(values.ready),
      playerState: String(values.state ?? -1),
      position: String(values.position ?? 0),
      sampledAt: String(now()),
      videoId: values.video_id || "",
    });
    dispatch("player_sample", values);
  };
  const start = (active = false, volume = 80, muted = false) => {
    destroy();
    const r = (resource = {
      generation: ++generation,
      host: env.document.getElementById("video-player-host"),
      active,
      suspended: false,
      player: null,
      frame: null,
      ready: false,
      preparing: false,
      videoId: "",
      blocked: false,
      error: "",
      volume,
      muted,
      seekCount: 0,
    });
    if (!r.host) {
      resource = null;
      return generation;
    }
    Object.assign(r.host.dataset, {
      generation: String(generation),
      resources: "0",
      ready: "false",
      playerState: "-1",
      position: "0",
      videoId: "",
    });
    r.timer = setInterval(() => {
      if (current(r) && r.active) sample(r);
    }, 100);
    return generation;
  };
  const load = (expected, videoId, source = null) => {
    const r = resource;
    if (!r || r.generation !== expected || !current(r)) return;
    const priorSample = read();
    if(priorSample) {r.volume=priorSample.volume;r.muted=priorSample.muted;}
    r.replayAbort?.abort();
    (env.ReviewReplayResources || ReplayUpload).retainSource(source);
    r.provider = source?.kind || "youtube";
    if (r.provider === "slippi_replay") {
      r.loadVersion = (r.loadVersion || 0) + 1;
      const version = r.loadVersion;
      clearTimeout(r.timeout);
      r.player?.destroy();
      r.frame?.remove();
      Object.assign(r, {player:null, frame:null, loading:false, videoId, active:true, ready:false, preparing:true, blocked:false, error:""});
      const controller = r.replayAbort = new AbortController();
      const valid = () => current(r) && r.loadVersion === version && !controller.signal.aborted;
      r.timeout = setTimeout(() => {if(valid()){(env.ReviewReplayResources || ReplayUpload).preparationFailed();r.error="Replay preparation timed out.";r.preparing=false;controller.abort();sample(r);}},30_000);
      void createReplayPlayer(r.host, source, videoId, {signal:controller.signal, env, onChange:()=>{if(valid())sample(r);}}).then(player=>{
        if (!valid()) { player.destroy(); return; }
        clearTimeout(r.timeout);
        r.player=player; r.frame=r.host.firstElementChild; r.ready=true; r.preparing=false; sample(r);
      }).catch(error=>{if(valid()){clearTimeout(r.timeout);(env.ReviewReplayResources || ReplayUpload).preparationFailed();r.error=error.message;r.preparing=false;sample(r);}});
      return;
    }
    if (r.frame?.classList?.contains("slippi-player")) {
      r.player?.destroy(); r.frame?.remove();
      Object.assign(r, {player:null,frame:null,ready:false,loading:false});
    }
    if (r.provider === "local_file" || !r.loading || r.frame?.tagName === "VIDEO") r.loadVersion = (r.loadVersion || 0) + 1;
    const version = r.loadVersion;
    const validLoad = () => current(r) && r.loadVersion === version;
    if (source?.kind === "local_file") {
      clearTimeout(r.timeout);
      r.loading = false;
      r.player?.destroy();
      r.frame?.remove();
      const video = env.document.createElement("video");
      r.frame = video;
      video.className = "youtube-player";
      video.controls = true;
      video.playsInline = true;
      video.preload = "metadata";
      let mediaURL;
      // URL creation waits for a controlling worker and the current file generation.
      void (env.ReviewFileShare || FileShare).url(source).then(url => {
        if (validLoad() && r.frame === video) { mediaURL = url; video.src = url; video.load(); }
        else (env.ReviewFileShare || FileShare).revokeURL?.(url);
      }).catch(error => {
        if (validLoad() && r.frame === video) { r.error = error.message; sample(r); }
      });
      r.videoId = videoId;
      r.active = true;
      r.ready = false;
      r.preparing = true;
      r.blocked = false;
      r.error = "";
      const state = () => video.ended ? 0 : video.readyState < 3 && !video.paused ? 3 : video.paused ? 2 : 1;
      r.player = {
        getVideoUrl: () => `https://native.invalid/?v=${encodeURIComponent(videoId)}`,
        getCurrentTime: () => video.currentTime,
        getDuration: () => video.duration,
        getPlayerState: state,
        getPlaybackRate: () => video.playbackRate,
        setPlaybackRate: value => { video.playbackRate = value; },
        getVolume: () => video.volume * 100,
        isMuted: () => video.muted,
        setVolume: value => { video.volume = value / 100; },
        mute: () => { video.muted = true; },
        unMute: () => { video.muted = false; },
        playVideo: () => {
          const pending = video.play();
          pending?.catch(() => { if (current(r) && r.frame === video) { r.blocked = true; sample(r); } });
        },
        pauseVideo: () => video.pause(),
        seekTo: value => { video.currentTime = value; },
        destroy: () => {
          video.pause(); video.removeAttribute("src"); video.load();
          (env.ReviewFileShare || FileShare).revokeURL?.(mediaURL); mediaURL = null;
        },
      };
      video.volume = r.volume / 100;
      video.muted = r.muted;
      for (const event of ["loadedmetadata", "canplay", "play", "pause", "seeking", "seeked", "waiting", "ended", "volumechange", "error"]) {
        video.addEventListener(event, () => {
          if (!current(r) || r.frame !== video) return;
          r.ready = video.readyState >= 1;
          r.preparing = !r.ready;
          if (event === "error") r.error = "This video could not be played. Retry playback or choose another source.";
          if (event === "play") r.blocked = false;
          sample(r);
        });
      }
      for (const event of ["pointerdown", "keydown"]) {
        video.addEventListener(event, input => {
          if (input.isTrusted && validLoad() && r.frame === video) dispatch("player_activity", { generation: r.generation });
        });
      }
      r.host.replaceChildren(video);
      return;
    }
    if (r.frame?.tagName === "VIDEO") {
      r.player.destroy();
      r.frame.remove();
      r.player = null;
      r.frame = null;
      r.ready = false;
      r.loading = false;
    }
    r.videoId = videoId;
    r.active = true;
    r.error = "";
    r.blocked = false;
    r.preparing = true;
    if (r.player && r.ready) {
      r.player.cueVideoById({ videoId, startSeconds: 0 });
      sample(r);
      return;
    }
    if (r.loading) return;
    r.loading = true;
    // Keep promises inside the adapter, out of Hologram's NativeValue registry.
    void (async () => {
      try {
        const YT = await loadAPI();
        if (!validLoad() || r.provider !== "youtube") return;
        const frame = (r.frame = env.document.createElement("iframe"));
        const url = new URL(
          `https://www.youtube-nocookie.com/embed/${r.videoId}`,
        );
        url.search = new URLSearchParams({
          enablejsapi: "1",
          origin: env.location.origin,
          autoplay: "0",
          playsinline: "1",
          controls: "1",
        });
        frame.id = "youtube-player";
        frame.src = url.href;
        frame.title = "YouTube video player";
        frame.className = "youtube-player";
        frame.allow =
          "autoplay; encrypted-media; picture-in-picture; fullscreen";
        frame.referrerPolicy = "strict-origin-when-cross-origin";
        frame.allowFullscreen = true;
        r.host.replaceChildren(frame);
        r.timeout = setTimeout(() => {
          if (validLoad() && !r.ready) {
            r.error = "The player timed out. Retry playback.";
            sample(r);
          }
        }, 30000);
        r.player = new YT.Player(frame, {
          events: {
            onReady: () => {
              if (!validLoad()) return;
              clearTimeout(r.timeout);
              r.ready = true;
              r.player.setVolume(r.volume);
              if (r.muted) r.player.mute();
              r.player.cueVideoById({ videoId: r.videoId, startSeconds: 0 });
              sample(r);
            },
            onStateChange: () => {
              if (validLoad()) {
                const state = r.player.getPlayerState();
                if ([1, 5].includes(state) && actualId(r) === r.videoId)
                  r.preparing = false;
                if (state === 1) r.blocked = false;
                sample(r);
              }
            },
            onAutoplayBlocked: () => {
              if (validLoad()) {
                r.blocked = true;
                sample(r);
              }
            },
            onError: (event) => {
              if (validLoad()) {
                r.error = playerError(event.data);
                sample(r);
              }
            },
          },
        });
      } catch (error) {
        if (validLoad()) {
          r.error = error.message;
          sample(r);
        }
      }
    })();
  };
  const command = (expected, operation, value) => {
    const r = resource;
    if (!r || r.generation !== expected || !current(r)) return;
    if (operation === "volume") r.volume = value;
    if (operation === "mute") r.muted = value;
    if (!r.ready) return;
    if (operation === "play") {
      r.blocked = false;
      r.player.playVideo();
    } else if (operation === "pause") r.player.pauseVideo();
    else if (operation === "seek") {
      r.seekCount++;
      r.player.seekTo(value, true);
    } else if (operation === "rate" && r.provider === "local_file") r.player.setPlaybackRate(value);
    else if (operation === "volume") r.player.setVolume(value);
    else if (operation === "mute") value ? r.player.mute() : r.player.unMute();
  };
  const mount = () => {
    const next = env.document.getElementById("video-player-host");
    if (next === host) return;
    destroy();
    (env.ReviewReplayResources || ReplayUpload).release();
    host = next;
    if (host) {
      const mounted = host;
      env.requestAnimationFrame(() => {
        if (host === mounted) dispatch("player_mounted", {});
      });
    }
  };
  if (env.document) {
    new env.MutationObserver(mount).observe(env.document.documentElement, {
      childList: true,
      subtree: true,
    });
    env.addEventListener("pagehide", () => {
      suspend();
      destroy();
    });
    env.addEventListener("pageshow", (e) => {
      if (e.persisted) {
        host = null;
        mount();
      }
    });
    env.document.addEventListener("visibilitychange", () => {
      if (resource && current(resource))
        dispatch("player_visible", {
          generation: resource.generation,
          now: now(),
          visible: !env.document.hidden,
        });
    });
    env.queueMicrotask(mount);
  }
  return {
    start,
    load,
    command,
    suspend,
    clear: () => {
      if (!resource) return;
      resource.replayAbort?.abort();
      (env.ReviewReplayResources || ReplayUpload).release();
      resource.loadVersion = (resource.loadVersion || 0) + 1;
      clearTimeout(resource.timeout);
      resource.player?.destroy();
      resource.frame?.remove();
      Object.assign(resource, { player: null, frame: null, ready: false, loading: false, videoId: "", active: false });
    },
    now,
    read,
    stop: () => {
      destroy();
      return ++generation;
    },
  };
}
export default (globalThis.ReviewPlaybackNative ||= createPlaybackNative());
