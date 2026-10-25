if Application.compile_env(:review_project, :hologram_spikes, false) do
  defmodule ReviewProjectWeb.Hologram.Spikes.YouTubePage do
    @moduledoc """
    Development-only, single-player YouTube viability spike. No room or sync state.
    The JS facade owns the official player and its lifecycle; Hologram keeps telemetry.
    """
    use Hologram.Page
    use Hologram.JS

    alias ReviewProjectWeb.Hologram.Spikes.SpikeLayout

    js_import from: "./youtube_probe.mjs", as: :YouTubeProbe

    route "/dev/spikes/youtube"
    layout SpikeLayout

    def init(_params, component, _server) do
      put_state(component,
        session_id: "",
        source: "M7lc1UVf-VE",
        seconds: "10",
        status: "Choose a video, then create the player.",
        ready: false,
        player_state: "not created",
        video_id: "",
        position: 0,
        duration: 0,
        error: "",
        blocked: false,
        events: 0
      )
    end

    def template do
      ~HOLO"""
      <main id="youtube-spike" class="mx-auto flex min-h-screen w-full max-w-5xl flex-col gap-6 px-6 py-10">
        <header>
          <p class="text-xs font-semibold uppercase tracking-[0.25em] text-cyan-300">Release viability · spike 1</p>
          <h1 class="mt-3 text-4xl font-semibold tracking-tight">Watch together, starting with YouTube</h1>
          <p class="mt-4 max-w-2xl leading-7 text-slate-300">Try a video, enable playback on this device, and test the controls. This experiment uses one local player; shared playback comes next.</p>
        </header>

        <section class="rounded-2xl border border-white/10 bg-slate-900 p-5 shadow-xl">
          <label for="youtube-source" class="block text-sm font-medium text-slate-200">YouTube link or video ID</label>
          <input id="youtube-source" type="text" value={@source} $input="source_changed" class="mt-2 w-full rounded-xl border border-slate-600 bg-slate-950 px-4 py-3 text-white outline-none transition focus:border-cyan-300 focus:ring-2 focus:ring-cyan-300/20" />
          <div class="mt-4 flex flex-wrap gap-3">
            <button id="youtube-create" $click="create" class="rounded-xl bg-cyan-300 px-4 py-3 font-semibold text-slate-950 transition hover:bg-cyan-200">Create / replace player</button>
            <button id="youtube-cue" $click="cue" class="rounded-xl border border-slate-600 px-4 py-3 transition hover:border-cyan-300">Change video</button>
            <button id="youtube-destroy" $click="destroy" class="rounded-xl border border-rose-300/30 px-4 py-3 text-rose-200 transition hover:bg-rose-300/10">Remove player</button>
          </div>
        </section>

        <section aria-label="Video player" class="rounded-2xl border border-white/10 bg-black p-3">
          <div id="youtube-player-host" class="aspect-video min-h-[200px] w-full"></div>
        </section>

        <section class="rounded-2xl border border-white/10 bg-slate-900 p-5">
          <p id="youtube-status" role="status" aria-live="polite" class="text-slate-200">{@status}</p>
          <p id="youtube-error" role="alert" class="mt-2 text-rose-200">{@error}</p>
          {%if @blocked}
            <p id="youtube-blocked" class="mt-2 text-amber-200">Your browser blocked playback. Click Enable playback, or press Play inside the video.</p>
          {/if}
          <div class="mt-4 flex flex-wrap items-end gap-3">
            <button id="youtube-play" $click="play" disabled={!@ready} class="rounded-xl bg-cyan-300 px-4 py-3 font-semibold text-slate-950 transition hover:bg-cyan-200 disabled:cursor-not-allowed disabled:opacity-40">Enable playback / Play</button>
            <button id="youtube-pause" $click="pause" disabled={!@ready} class="rounded-xl border border-slate-600 px-4 py-3 transition hover:border-cyan-300 disabled:opacity-40">Pause</button>
            <div>
              <label for="youtube-seconds" class="block text-xs text-slate-300">Seek to seconds</label>
              <input id="youtube-seconds" type="number" min="0" step="1" value={@seconds} $input="seconds_changed" class="mt-1 w-32 rounded-xl border border-slate-600 bg-slate-950 px-3 py-3 text-white outline-none focus:border-cyan-300" />
            </div>
            <button id="youtube-seek" $click="seek" disabled={!@ready} class="rounded-xl border border-slate-600 px-4 py-3 transition hover:border-cyan-300 disabled:opacity-40">Seek</button>
          </div>
          <a id="youtube-leave" href="/dev/spikes/hologram-interop" class="mt-5 inline-block text-sm text-cyan-200 underline underline-offset-4">Leave this experiment</a>
        </section>

        <details class="rounded-2xl border border-white/10 p-5" open>
          <summary class="cursor-pointer text-sm font-semibold text-slate-300">Experiment telemetry</summary>
          <dl class="mt-4 grid grid-cols-2 gap-4 text-sm sm:grid-cols-3">
            <div><dt class="text-slate-400">Ready</dt><dd id="youtube-ready">{@ready}</dd></div>
            <div><dt class="text-slate-400">State</dt><dd id="youtube-state">{@player_state}</dd></div>
            <div><dt class="text-slate-400">Video</dt><dd id="youtube-video">{@video_id}</dd></div>
            <div><dt class="text-slate-400">Position / duration (s)</dt><dd><span id="youtube-position">{@position}</span> / <span id="youtube-duration">{@duration}</span></dd></div>
            <div><dt class="text-slate-400">Callbacks</dt><dd id="youtube-events">{@events}</dd></div>
            <div><dt class="text-slate-400">Resource ID</dt><dd id="youtube-session">{@session_id}</dd></div>
          </dl>
        </details>
      </main>
      """
    end

    def action(:create, _params, component) do
      id = JS.call(:YouTubeProbe, :create, [])
      put_state(component, session_id: id)
    end

    def action(:source_changed, %{event: %{value: value}}, component) do
      put_state(component, source: value)
    end

    def action(:seconds_changed, %{event: %{value: value}}, component) do
      put_state(component, seconds: value)
    end

    def action(:destroy, _params, component) do
      JS.call(:YouTubeProbe, :destroy, [component.state.session_id])
      component
    end

    def action(:cue, _params, component) do
      JS.call(:YouTubeProbe, :control, [component.state.session_id, "cue"])
      component
    end

    def action(:play, _params, component) do
      JS.call(:YouTubeProbe, :control, [component.state.session_id, "play"])
      component
    end

    def action(:pause, _params, component) do
      JS.call(:YouTubeProbe, :control, [component.state.session_id, "pause"])
      component
    end

    def action(:seek, _params, component) do
      JS.call(:YouTubeProbe, :control, [component.state.session_id, "seek"])
      component
    end

    def action(:youtube_event, params, component) do
      put_state(component,
        ready: params.ready,
        status: params.status,
        player_state: params.player_state,
        video_id: params.video_id,
        position: params.position,
        duration: params.duration,
        error: params.error,
        blocked: params.blocked,
        events: params.events
      )
    end
  end
end
