if Application.compile_env(:review_project, :hologram_spikes, false) do
  defmodule ReviewProjectWeb.Hologram.Spikes.MembraneWebrtcPage do
    @moduledoc """
    Phase 0 integration spike: Hologram <-> Membrane WebRTC seam.

    This page is the missing link between two earlier spikes:

      * the Hologram interop spike proved Hologram can drive browser-native
        WebRTC objects (client side), and
      * the raw `membrane_webrtc_plugin` echo spike proved the Membrane media
        engine (server side) — but that one used LiveView's `Live.Capture` /
        `Live.Player` convenience components for signaling.

    Here the browser PeerConnection is owned entirely by a Hologram-driven JS
    facade (`membrane_webrtc_probe.mjs`), signaling rides
    `Membrane.WebRTC.PhoenixSignaling` (a plain Phoenix socket, no LiveView), and
    the Membrane echo pipeline is started server-side by a Hologram `command`.
    Proving this seam de-risks the real Phase 1 player, where a Hologram drawing
    canvas will overlay this same Membrane-delivered video.

    Dev-only: requires `HOLOGRAM_START=1` (e.g. `mix holo`).
    """

    use Hologram.Page
    use Hologram.JS

    require Logger

    alias ReviewProject.MediaSpikes.EchoSessions
    alias ReviewProjectWeb.Hologram.Spikes.SpikeLayout

    js_import from: "./membrane_webrtc_probe.mjs", as: :MembraneWebRTCProbe
    js_import from: "./canvas_probe.mjs", as: :CanvasProbe

    route "/dev/spikes/hologram-webrtc"

    layout SpikeLayout

    def init(_params, component, _server) do
      put_state(component,
        base_id: "—",
        session_started: false,
        status: "Idle — click Start echo session",
        ready: false,
        capture_state: "—",
        capture_ice: "—",
        player_state: "—",
        player_ice: "—",
        capture_audio_pkts: 0,
        capture_video_pkts: 0,
        player_audio_pkts: 0,
        player_video_pkts: 0,
        player_video_frames: 0,
        error: "—",
        event_count: 0,
        last_event: "—",
        # Drawing overlay (Hologram-owned canvas on top of the live Membrane video)
        drawing_ready: false,
        drawing_status: "Drawing off",
        stroke_count: 0,
        sample_count: 0,
        latest_point_text: "—",
        strokes: []
      )
    end

    def template do
      ~HOLO"""
      <main class="mx-auto flex min-h-screen w-full max-w-6xl flex-col gap-8 px-6 py-10">
        <section class="rounded-3xl border border-white/10 bg-white/[0.04] p-8 shadow-2xl shadow-cyan-950/30">
          <p class="text-sm font-semibold uppercase tracking-[0.32em] text-cyan-300">Phase 0 spike</p>
          <div class="mt-4 flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
            <div>
              <h1 class="text-4xl font-bold tracking-tight text-white md:text-5xl">Hologram ↔ Membrane WebRTC</h1>
              <p class="mt-4 max-w-3xl text-base leading-7 text-slate-300">
                A Hologram-owned browser PeerConnection negotiates with the Membrane
                <code class="rounded bg-black/40 px-1.5 py-0.5 text-cyan-200">Source</code>/<code class="rounded bg-black/40 px-1.5 py-0.5 text-cyan-200">Sink</code>
                echo pipeline over <code class="rounded bg-black/40 px-1.5 py-0.5 text-cyan-200">PhoenixSignaling</code> — no LiveView.
                The pipeline is started server-side by a Hologram command. Audio + video echo.
              </p>
            </div>
            <div class="rounded-2xl border border-cyan-300/20 bg-cyan-300/10 px-5 py-4 text-sm text-cyan-100">
              <div class="font-semibold">Status</div>
              <div id="membrane-status" class="mt-1 text-cyan-50">{@status}</div>
              <div class="mt-1 text-xs text-cyan-200/70">session: {@base_id}</div>
            </div>
          </div>

          <div class="mt-6 flex gap-3">
            <button
              id="start-membrane-session"
              class="rounded-2xl bg-cyan-400 px-5 py-3 font-semibold text-slate-950 transition hover:-translate-y-0.5 hover:bg-cyan-300"
              $click="start_session"
            >
              Start echo session
            </button>
            <button
              id="stop-membrane-session"
              class="rounded-2xl border border-rose-300/25 px-5 py-3 font-semibold text-rose-100 transition hover:-translate-y-0.5 hover:border-rose-300/70 hover:bg-rose-300/10"
              $click="stop_session"
            >
              Stop
            </button>
          </div>
        </section>

        <section class="grid gap-6 lg:grid-cols-2">
          <div class="rounded-3xl border border-white/10 bg-slate-900/80 p-5 shadow-xl">
            <h2 class="text-xl font-semibold text-white">Capture preview</h2>
            <p class="text-sm text-slate-400">Browser → Membrane.Source</p>
            <div class="mt-4 aspect-video overflow-hidden rounded-2xl border border-white/10 bg-black">
              <video id="membrane-capture" class="h-full w-full object-cover" autoplay muted playsinline></video>
            </div>
            <dl class="mt-4 grid grid-cols-2 gap-3 text-sm">
              <div class="rounded-2xl bg-slate-950/70 p-3"><dt class="text-slate-400">Conn / ICE</dt><dd id="capture-conn-stat" class="mt-1 font-semibold text-white">{@capture_state} / {@capture_ice}</dd></div>
              <div class="rounded-2xl bg-slate-950/70 p-3"><dt class="text-slate-400">Pkts sent a/v</dt><dd id="capture-pkts-stat" class="mt-1 font-semibold text-white">{@capture_audio_pkts} / {@capture_video_pkts}</dd></div>
            </dl>
          </div>

          <div class="rounded-3xl border border-white/10 bg-slate-900/80 p-5 shadow-xl">
            <div class="flex items-start justify-between gap-4">
              <div>
                <h2 class="text-xl font-semibold text-white">Echoed player + drawing</h2>
                <p class="text-sm text-slate-400">Membrane.Sink → Browser, Hologram canvas overlay</p>
              </div>
              <div id="drawing-status" class="rounded-2xl bg-fuchsia-300/10 px-3 py-2 text-xs font-semibold text-fuchsia-100">{@drawing_status}</div>
            </div>
            <div class="relative mt-4 aspect-video overflow-hidden rounded-2xl border border-white/10 bg-black">
              <video id="membrane-player" class="absolute inset-0 h-full w-full object-cover" autoplay muted playsinline></video>
              <canvas id="membrane-overlay" class="absolute inset-0 h-full w-full cursor-crosshair touch-none"></canvas>
            </div>
            <div class="mt-4 grid grid-cols-3 gap-3">
              <button
                id="enable-drawing"
                class="rounded-2xl bg-fuchsia-300 px-4 py-2.5 text-sm font-semibold text-slate-950 transition hover:-translate-y-0.5 hover:bg-fuchsia-200"
                $click="enable_drawing"
              >
                Enable drawing
              </button>
              <button
                id="replay-drawing"
                class="rounded-2xl border border-white/15 px-4 py-2.5 text-sm font-semibold text-slate-100 transition hover:-translate-y-0.5 hover:border-fuchsia-300/60 hover:text-fuchsia-100"
                $click="replay_drawing"
              >
                Replay
              </button>
              <button
                id="clear-drawing"
                class="rounded-2xl border border-rose-300/25 px-4 py-2.5 text-sm font-semibold text-rose-100 transition hover:-translate-y-0.5 hover:border-rose-300/70 hover:bg-rose-300/10"
                $click="clear_drawing"
              >
                Clear
              </button>
            </div>
            <dl class="mt-4 grid grid-cols-2 gap-3 text-sm">
              <div class="rounded-2xl bg-slate-950/70 p-3"><dt class="text-slate-400">Conn / ICE</dt><dd id="player-conn-stat" class="mt-1 font-semibold text-white">{@player_state} / {@player_ice}</dd></div>
              <div class="rounded-2xl bg-slate-950/70 p-3"><dt class="text-slate-400">Pkts recv a/v</dt><dd id="player-pkts-stat" class="mt-1 font-semibold text-white">{@player_audio_pkts} / {@player_video_pkts}</dd></div>
              <div class="rounded-2xl bg-slate-950/70 p-3"><dt class="text-slate-400">Frames decoded</dt><dd id="player-frames-stat" class="mt-1 font-semibold text-white">{@player_video_frames}</dd></div>
              <div class="rounded-2xl bg-slate-950/70 p-3"><dt class="text-slate-400">Ready</dt><dd id="ready-stat" class="mt-1 font-semibold text-white">{@ready}</dd></div>
              <div class="rounded-2xl bg-slate-950/70 p-3"><dt class="text-slate-400">Strokes (Hologram state)</dt><dd id="stroke-count-stat" class="mt-1 font-semibold text-white">{@stroke_count}</dd></div>
              <div class="rounded-2xl bg-slate-950/70 p-3"><dt class="text-slate-400">Pointer samples / latest</dt><dd id="sample-stat" class="mt-1 font-semibold text-white">{@sample_count} / {@latest_point_text}</dd></div>
            </dl>
          </div>
        </section>

        <section class="rounded-3xl border border-white/10 bg-white/[0.04] p-6 shadow-xl">
          <h2 class="text-lg font-semibold text-white">Seam telemetry</h2>
          <dl class="mt-4 grid gap-3 text-sm sm:grid-cols-3">
            <div class="rounded-2xl bg-slate-950/70 p-3"><dt class="text-slate-400">Callback events</dt><dd id="event-count-stat" class="mt-1 font-semibold text-white">{@event_count}</dd></div>
            <div class="rounded-2xl bg-slate-950/70 p-3"><dt class="text-slate-400">Last event</dt><dd id="last-event-stat" class="mt-1 font-semibold text-white">{@last_event}</dd></div>
            <div class="rounded-2xl bg-slate-950/70 p-3"><dt class="text-slate-400">Error</dt><dd id="error-stat" class="mt-1 font-semibold text-white">{@error}</dd></div>
          </dl>
        </section>
      </main>
      """
    end

    # --- Client actions ---

    def action(:start_session, _params, component) do
      base_id = JS.call(:MembraneWebRTCProbe, :newId, [])
      JS.call(:MembraneWebRTCProbe, :connect, [base_id])

      component
      |> put_state(
        base_id: base_id,
        session_started: true,
        status: "Starting echo session…",
        error: "—"
      )
      |> put_command(:start_session, %{base_id: base_id})
    end

    def action(:stop_session, _params, component) do
      base_id = component.state.base_id

      if component.state.session_started do
        JS.call(:MembraneWebRTCProbe, :disconnect, [base_id])
      end

      component
      |> put_state(session_started: false, status: "Stopped", ready: false)
      |> put_command(:stop_session, %{base_id: base_id})
    end

    def action(:membrane_webrtc_event, params, component) do
      put_state(component,
        status: params.status,
        ready: params.ready,
        capture_state: params.capture_state,
        capture_ice: params.capture_ice,
        player_state: params.player_state,
        player_ice: params.player_ice,
        capture_audio_pkts: params.capture_audio_pkts,
        capture_video_pkts: params.capture_video_pkts,
        player_audio_pkts: params.player_audio_pkts,
        player_video_pkts: params.player_video_pkts,
        player_video_frames: params.player_video_frames,
        error: params.error,
        event_count: params.event_count,
        last_event: params.last_event
      )
    end

    # --- Drawing overlay actions (Hologram canvas over the live Membrane video) ---

    def action(:enable_drawing, _params, component) do
      JS.call(:CanvasProbe, :initialize, ["membrane-overlay", "page"])

      put_state(component,
        drawing_ready: true,
        drawing_status: "Drawing on — draw over the video"
      )
    end

    def action(:canvas_ready, _params, component) do
      put_state(component, drawing_status: "Drawing on — draw over the video")
    end

    def action(:canvas_stats, params, component) do
      put_state(component,
        sample_count: params.sample_count,
        latest_point_text: params.latest_point_text
      )
    end

    def action(:stroke_recorded, params, component) do
      put_state(component,
        strokes: component.state.strokes ++ [params.stroke],
        stroke_count: component.state.stroke_count + 1,
        sample_count: params.sample_count,
        latest_point_text: params.latest_point_text,
        drawing_status: "Stored stroke in Hologram state"
      )
    end

    def action(:replay_drawing, _params, component) do
      JS.call(:CanvasProbe, :redraw, ["membrane-overlay", component.state.strokes])
      put_state(component, drawing_status: "Replayed strokes from Hologram state")
    end

    def action(:clear_drawing, _params, component) do
      JS.call(:CanvasProbe, :clear, ["membrane-overlay"])

      put_state(component,
        strokes: [],
        stroke_count: 0,
        sample_count: 0,
        latest_point_text: "—",
        drawing_status: "Cleared"
      )
    end

    # --- Server commands ---

    def command(:start_session, %{base_id: base_id}, server) do
      case EchoSessions.start_session(base_id) do
        {:ok, _pipeline_pid} ->
          :ok

        {:error, reason} ->
          Logger.error("[MembraneWebrtcPage] start_session failed: #{inspect(reason)}")
      end

      server
    end

    def command(:stop_session, %{base_id: base_id}, server) do
      EchoSessions.stop_session(base_id)
      server
    end
  end
end
