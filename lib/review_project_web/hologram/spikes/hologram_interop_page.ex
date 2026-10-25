if Application.compile_env(:review_project, :hologram_spikes, false) do
  defmodule ReviewProjectWeb.Hologram.Spikes.HologramInteropPage do
    use Hologram.Page
    use Hologram.JS

    alias ReviewProjectWeb.Hologram.Spikes.SpikeLayout

    js_import from: "./canvas_probe.mjs", as: :CanvasProbe
    js_import from: "./reference_probe.mjs", as: :ReferenceProbe
    js_import from: "./webrtc_probe.mjs", as: :WebRTCProbe

    route "/dev/spikes/hologram-interop"

    layout SpikeLayout

    def init(_params, component, _server) do
      put_state(component,
        canvas_ready: false,
        status: "Canvas not initialized",
        width: 0,
        height: 0,
        sample_count: 0,
        stroke_count: 0,
        latest_point_text: "—",
        last_stroke_points: 0,
        strokes: [],
        direct_ref: nil,
        direct_ref_ready: false,
        direct_ref_touch_count: 0,
        direct_ref_action_count: 0,
        direct_ref_age_ms: 0,
        registry_ref_id: "—",
        registry_ref_ready: false,
        registry_ref_touch_count: 0,
        registry_ref_action_count: 0,
        registry_ref_age_ms: 0,
        reference_status: "Reference probes not initialized",
        reference_exercise_result: "—",
        direct_webrtc_ref: nil,
        direct_webrtc_ready: false,
        direct_webrtc_status: "not started",
        direct_webrtc_pc1_state: "—",
        direct_webrtc_pc2_state: "—",
        direct_webrtc_ice_state: "— / —",
        direct_webrtc_channel_state: "—",
        direct_webrtc_pings_sent: 0,
        direct_webrtc_pongs_received: 0,
        direct_webrtc_last_message: "—",
        direct_webrtc_error: "—",
        direct_webrtc_event_count: 0,
        direct_webrtc_last_event: "—",
        direct_webrtc_ice_candidate_events: 0,
        direct_webrtc_connection_state_events: 0,
        direct_webrtc_ice_connection_state_events: 0,
        direct_webrtc_datachannel_events: 0,
        direct_webrtc_message_events: 0,
        registry_webrtc_id: "—",
        registry_webrtc_ready: false,
        registry_webrtc_status: "not started",
        registry_webrtc_pc1_state: "—",
        registry_webrtc_pc2_state: "—",
        registry_webrtc_ice_state: "— / —",
        registry_webrtc_channel_state: "—",
        registry_webrtc_pings_sent: 0,
        registry_webrtc_pongs_received: 0,
        registry_webrtc_last_message: "—",
        registry_webrtc_error: "—",
        registry_webrtc_event_count: 0,
        registry_webrtc_last_event: "—",
        registry_webrtc_ice_candidate_events: 0,
        registry_webrtc_connection_state_events: 0,
        registry_webrtc_ice_connection_state_events: 0,
        registry_webrtc_datachannel_events: 0,
        registry_webrtc_message_events: 0
      )
    end

    def template do
      ~HOLO"""
      <main class="mx-auto flex min-h-screen w-full max-w-6xl flex-col gap-8 px-6 py-10">
        <section class="rounded-3xl border border-white/10 bg-white/[0.04] p-8 shadow-2xl shadow-cyan-950/30">
          <p class="text-sm font-semibold uppercase tracking-[0.32em] text-cyan-300">Phase 0 spike</p>
          <div class="mt-4 flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
            <div>
              <h1 class="text-4xl font-bold tracking-tight text-white md:text-5xl">Hologram interop canvas probe</h1>
              <p class="mt-4 max-w-3xl text-base leading-7 text-slate-300">
                Dev-only page for validating Hologram-driven browser interop before committing to the watch-party drawing architecture.
                This milestone initializes a canvas, renders local strokes, captures normalized points, and can replay the Elixir-side stroke state.
              </p>
            </div>
            <div class="rounded-2xl border border-cyan-300/20 bg-cyan-300/10 px-5 py-4 text-sm text-cyan-100">
              <div class="font-semibold">Status</div>
              <div id="hologram-spike-status" class="mt-1 text-cyan-50">{@status}</div>
            </div>
          </div>
        </section>

        <section class="grid gap-6 lg:grid-cols-[1fr_20rem]">
          <div class="rounded-3xl border border-white/10 bg-slate-900/80 p-4 shadow-xl">
            <canvas
              id="hologram-interop-canvas"
              width="1280"
              height="720"
              class="aspect-video w-full cursor-crosshair rounded-2xl border border-slate-700 bg-slate-950 shadow-inner shadow-black/60"
            ></canvas>
          </div>

          <aside class="flex flex-col gap-4">
            <div class="rounded-3xl border border-white/10 bg-white/[0.04] p-5">
              <h2 class="text-lg font-semibold text-white">Controls</h2>
              <div class="mt-4 grid gap-3">
                <button
                  id="initialize-canvas-button"
                  class="rounded-2xl bg-cyan-400 px-4 py-3 font-semibold text-slate-950 transition hover:-translate-y-0.5 hover:bg-cyan-300"
                  $click="initialize_canvas"
                >
                  Initialize canvas
                </button>
                <button
                  id="replay-canvas-button"
                  class="rounded-2xl border border-white/15 px-4 py-3 font-semibold text-slate-100 transition hover:-translate-y-0.5 hover:border-cyan-300/60 hover:text-cyan-100"
                  $click="replay_canvas"
                >
                  Replay stored strokes
                </button>
                <button
                  id="clear-canvas-button"
                  class="rounded-2xl border border-rose-300/25 px-4 py-3 font-semibold text-rose-100 transition hover:-translate-y-0.5 hover:border-rose-300/70 hover:bg-rose-300/10"
                  $click="clear_canvas"
                >
                  Clear canvas
                </button>
              </div>
            </div>

            <div class="rounded-3xl border border-white/10 bg-white/[0.04] p-5">
              <h2 class="text-lg font-semibold text-white">Telemetry</h2>
              <dl class="mt-4 grid grid-cols-2 gap-3 text-sm">
                <div class="rounded-2xl bg-slate-950/70 p-3">
                  <dt class="text-slate-400">Ready</dt>
                  <dd id="canvas-ready-stat" class="mt-1 font-semibold text-white">{@canvas_ready}</dd>
                </div>
                <div class="rounded-2xl bg-slate-950/70 p-3">
                  <dt class="text-slate-400">Size</dt>
                  <dd id="canvas-size-stat" class="mt-1 font-semibold text-white">{@width}×{@height}</dd>
                </div>
                <div class="rounded-2xl bg-slate-950/70 p-3">
                  <dt class="text-slate-400">Pointer samples</dt>
                  <dd id="sample-count-stat" class="mt-1 font-semibold text-white">{@sample_count}</dd>
                </div>
                <div class="rounded-2xl bg-slate-950/70 p-3">
                  <dt class="text-slate-400">Strokes</dt>
                  <dd id="stroke-count-stat" class="mt-1 font-semibold text-white">{@stroke_count}</dd>
                </div>
                <div class="rounded-2xl bg-slate-950/70 p-3">
                  <dt class="text-slate-400">Last stroke points</dt>
                  <dd id="last-stroke-points-stat" class="mt-1 font-semibold text-white">{@last_stroke_points}</dd>
                </div>
                <div class="rounded-2xl bg-slate-950/70 p-3">
                  <dt class="text-slate-400">Latest normalized point</dt>
                  <dd id="latest-point-stat" class="mt-1 font-semibold text-white">{@latest_point_text}</dd>
                </div>
              </dl>
            </div>
          </aside>
        </section>

        <section class="rounded-3xl border border-white/10 bg-white/[0.04] p-6 shadow-xl">
          <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
            <div>
              <p class="text-sm font-semibold uppercase tracking-[0.28em] text-fuchsia-300">Milestone 3</p>
              <h2 class="mt-2 text-2xl font-bold text-white">Long-lived JS object references</h2>
              <p class="mt-3 max-w-3xl text-sm leading-6 text-slate-300">
                This section validates two object-lifetime strategies: a direct native JS object held in Hologram state, and an opaque registry ID where JS owns the object and Hologram owns the identifier. If the direct counts stop advancing while the registry counts continue, prefer the registry boundary for browser-native objects.
              </p>
            </div>
            <div id="reference-probe-status" class="rounded-2xl border border-fuchsia-300/20 bg-fuchsia-300/10 px-5 py-4 text-sm text-fuchsia-50">
              {@reference_status}
            </div>
          </div>

          <div class="mt-6 grid gap-6 lg:grid-cols-[20rem_1fr]">
            <div class="grid gap-3">
              <button
                id="create-reference-probes-button"
                class="rounded-2xl bg-fuchsia-300 px-4 py-3 font-semibold text-slate-950 transition hover:-translate-y-0.5 hover:bg-fuchsia-200"
                $click="create_reference_probes"
              >
                Create reference probes
              </button>
              <button
                id="touch-reference-probes-button"
                class="rounded-2xl border border-white/15 px-4 py-3 font-semibold text-slate-100 transition hover:-translate-y-0.5 hover:border-fuchsia-300/60 hover:text-fuchsia-100"
                $click="touch_reference_probes"
              >
                Touch once
              </button>
              <button
                id="exercise-reference-probes-button"
                class="rounded-2xl border border-white/15 px-4 py-3 font-semibold text-slate-100 transition hover:-translate-y-0.5 hover:border-fuchsia-300/60 hover:text-fuchsia-100"
                $click="exercise_reference_probes"
              >
                Exercise 50 actions
              </button>
              <button
                id="destroy-reference-probes-button"
                class="rounded-2xl border border-rose-300/25 px-4 py-3 font-semibold text-rose-100 transition hover:-translate-y-0.5 hover:border-rose-300/70 hover:bg-rose-300/10"
                $click="destroy_reference_probes"
              >
                Destroy probes
              </button>
            </div>

            <dl class="grid gap-3 text-sm sm:grid-cols-2 lg:grid-cols-3">
              <div class="rounded-2xl bg-slate-950/70 p-4">
                <dt class="text-slate-400">Direct ref ready</dt>
                <dd id="direct-ref-ready-stat" class="mt-1 font-semibold text-white">{@direct_ref_ready}</dd>
              </div>
              <div class="rounded-2xl bg-slate-950/70 p-4">
                <dt class="text-slate-400">Direct touches / actions</dt>
                <dd id="direct-ref-count-stat" class="mt-1 font-semibold text-white">{@direct_ref_touch_count} / {@direct_ref_action_count}</dd>
              </div>
              <div class="rounded-2xl bg-slate-950/70 p-4">
                <dt class="text-slate-400">Direct age</dt>
                <dd id="direct-ref-age-stat" class="mt-1 font-semibold text-white">{@direct_ref_age_ms}ms</dd>
              </div>
              <div class="rounded-2xl bg-slate-950/70 p-4">
                <dt class="text-slate-400">Registry ref ID</dt>
                <dd id="registry-ref-id-stat" class="mt-1 font-semibold text-white">{@registry_ref_id}</dd>
              </div>
              <div class="rounded-2xl bg-slate-950/70 p-4">
                <dt class="text-slate-400">Registry touches / actions</dt>
                <dd id="registry-ref-count-stat" class="mt-1 font-semibold text-white">{@registry_ref_touch_count} / {@registry_ref_action_count}</dd>
              </div>
              <div class="rounded-2xl bg-slate-950/70 p-4">
                <dt class="text-slate-400">Registry age</dt>
                <dd id="registry-ref-age-stat" class="mt-1 font-semibold text-white">{@registry_ref_age_ms}ms</dd>
              </div>
              <div class="rounded-2xl bg-slate-950/70 p-4 sm:col-span-2 lg:col-span-3">
                <dt class="text-slate-400">Exercise result</dt>
                <dd id="reference-exercise-result-stat" class="mt-1 font-semibold text-white">{@reference_exercise_result}</dd>
              </div>
            </dl>
          </div>
        </section>

        <section class="rounded-3xl border border-white/10 bg-white/[0.04] p-6 shadow-xl">
          <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
            <div>
              <p class="text-sm font-semibold uppercase tracking-[0.28em] text-emerald-300">Milestones 4 & 5</p>
              <h2 class="mt-2 text-2xl font-bold text-white">WebRTC loopback + event callbacks</h2>
              <p class="mt-3 max-w-3xl text-sm leading-6 text-slate-300">
                Same-page two-peer WebRTC loopback with no camera/microphone. The direct path stores a browser object reference in Hologram state; the registry path stores only an opaque ID and keeps the peer connections in JavaScript. Both paths subscribe to native WebRTC/datachannel events and push callback telemetry back into Hologram state.
              </p>
            </div>
          </div>

          <div class="mt-6 grid gap-6 xl:grid-cols-2">
            <div class="rounded-3xl border border-emerald-300/15 bg-slate-950/60 p-5">
              <div class="flex items-start justify-between gap-4">
                <div>
                  <h3 class="text-lg font-semibold text-white">Direct object ref</h3>
                  <p class="mt-1 text-sm text-slate-400">Stores the loopback probe object directly in Hologram state.</p>
                </div>
                <div id="direct-webrtc-status" class="rounded-2xl bg-emerald-300/10 px-3 py-2 text-xs font-semibold text-emerald-100">{@direct_webrtc_status}</div>
              </div>

              <div class="mt-4 grid gap-3 sm:grid-cols-3">
                <button id="create-direct-webrtc-button" class="rounded-2xl bg-emerald-300 px-4 py-3 font-semibold text-slate-950 transition hover:-translate-y-0.5 hover:bg-emerald-200" $click="create_direct_webrtc_loopback">Create</button>
                <button id="send-direct-webrtc-ping-button" class="rounded-2xl border border-white/15 px-4 py-3 font-semibold text-slate-100 transition hover:-translate-y-0.5 hover:border-emerald-300/60 hover:text-emerald-100" $click="send_direct_webrtc_ping">Send ping</button>
                <button id="close-direct-webrtc-button" class="rounded-2xl border border-rose-300/25 px-4 py-3 font-semibold text-rose-100 transition hover:-translate-y-0.5 hover:border-rose-300/70 hover:bg-rose-300/10" $click="close_direct_webrtc_loopback">Close</button>
              </div>

              <dl class="mt-4 grid gap-3 text-sm sm:grid-cols-2">
                <div class="rounded-2xl bg-black/30 p-3"><dt class="text-slate-400">Ready</dt><dd id="direct-webrtc-ready-stat" class="mt-1 font-semibold text-white">{@direct_webrtc_ready}</dd></div>
                <div class="rounded-2xl bg-black/30 p-3"><dt class="text-slate-400">Channel</dt><dd id="direct-webrtc-channel-stat" class="mt-1 font-semibold text-white">{@direct_webrtc_channel_state}</dd></div>
                <div class="rounded-2xl bg-black/30 p-3"><dt class="text-slate-400">PC states</dt><dd id="direct-webrtc-pc-stat" class="mt-1 font-semibold text-white">{@direct_webrtc_pc1_state} / {@direct_webrtc_pc2_state}</dd></div>
                <div class="rounded-2xl bg-black/30 p-3"><dt class="text-slate-400">ICE states</dt><dd id="direct-webrtc-ice-stat" class="mt-1 font-semibold text-white">{@direct_webrtc_ice_state}</dd></div>
                <div class="rounded-2xl bg-black/30 p-3"><dt class="text-slate-400">Ping / pong</dt><dd id="direct-webrtc-ping-stat" class="mt-1 font-semibold text-white">{@direct_webrtc_pings_sent} / {@direct_webrtc_pongs_received}</dd></div>
                <div class="rounded-2xl bg-black/30 p-3"><dt class="text-slate-400">Last message</dt><dd id="direct-webrtc-message-stat" class="mt-1 font-semibold text-white">{@direct_webrtc_last_message}</dd></div>
                <div class="rounded-2xl bg-black/30 p-3"><dt class="text-slate-400">Callback events</dt><dd id="direct-webrtc-event-count-stat" class="mt-1 font-semibold text-white">{@direct_webrtc_event_count}</dd></div>
                <div class="rounded-2xl bg-black/30 p-3"><dt class="text-slate-400">Last callback</dt><dd id="direct-webrtc-last-event-stat" class="mt-1 font-semibold text-white">{@direct_webrtc_last_event}</dd></div>
                <div class="rounded-2xl bg-black/30 p-3"><dt class="text-slate-400">ICE candidates</dt><dd id="direct-webrtc-candidate-events-stat" class="mt-1 font-semibold text-white">{@direct_webrtc_ice_candidate_events}</dd></div>
                <div class="rounded-2xl bg-black/30 p-3"><dt class="text-slate-400">Conn / ICE callbacks</dt><dd id="direct-webrtc-state-events-stat" class="mt-1 font-semibold text-white">{@direct_webrtc_connection_state_events} / {@direct_webrtc_ice_connection_state_events}</dd></div>
                <div class="rounded-2xl bg-black/30 p-3"><dt class="text-slate-400">Datachannel callbacks</dt><dd id="direct-webrtc-datachannel-events-stat" class="mt-1 font-semibold text-white">{@direct_webrtc_datachannel_events}</dd></div>
                <div class="rounded-2xl bg-black/30 p-3"><dt class="text-slate-400">Message callbacks</dt><dd id="direct-webrtc-message-events-stat" class="mt-1 font-semibold text-white">{@direct_webrtc_message_events}</dd></div>
                <div class="rounded-2xl bg-black/30 p-3 sm:col-span-2"><dt class="text-slate-400">Error</dt><dd id="direct-webrtc-error-stat" class="mt-1 font-semibold text-white">{@direct_webrtc_error}</dd></div>
              </dl>
            </div>

            <div class="rounded-3xl border border-emerald-300/15 bg-slate-950/60 p-5">
              <div class="flex items-start justify-between gap-4">
                <div>
                  <h3 class="text-lg font-semibold text-white">Registry + opaque ID</h3>
                  <p class="mt-1 text-sm text-slate-400">Stores peer connections in a JS Map and keeps only an ID in Hologram state.</p>
                </div>
                <div id="registry-webrtc-status" class="rounded-2xl bg-emerald-300/10 px-3 py-2 text-xs font-semibold text-emerald-100">{@registry_webrtc_status}</div>
              </div>

              <div class="mt-4 grid gap-3 sm:grid-cols-3">
                <button id="create-registry-webrtc-button" class="rounded-2xl bg-emerald-300 px-4 py-3 font-semibold text-slate-950 transition hover:-translate-y-0.5 hover:bg-emerald-200" $click="create_registry_webrtc_loopback">Create</button>
                <button id="send-registry-webrtc-ping-button" class="rounded-2xl border border-white/15 px-4 py-3 font-semibold text-slate-100 transition hover:-translate-y-0.5 hover:border-emerald-300/60 hover:text-emerald-100" $click="send_registry_webrtc_ping">Send ping</button>
                <button id="close-registry-webrtc-button" class="rounded-2xl border border-rose-300/25 px-4 py-3 font-semibold text-rose-100 transition hover:-translate-y-0.5 hover:border-rose-300/70 hover:bg-rose-300/10" $click="close_registry_webrtc_loopback">Close</button>
              </div>

              <dl class="mt-4 grid gap-3 text-sm sm:grid-cols-2">
                <div class="rounded-2xl bg-black/30 p-3"><dt class="text-slate-400">ID</dt><dd id="registry-webrtc-id-stat" class="mt-1 font-semibold text-white">{@registry_webrtc_id}</dd></div>
                <div class="rounded-2xl bg-black/30 p-3"><dt class="text-slate-400">Ready</dt><dd id="registry-webrtc-ready-stat" class="mt-1 font-semibold text-white">{@registry_webrtc_ready}</dd></div>
                <div class="rounded-2xl bg-black/30 p-3"><dt class="text-slate-400">Channel</dt><dd id="registry-webrtc-channel-stat" class="mt-1 font-semibold text-white">{@registry_webrtc_channel_state}</dd></div>
                <div class="rounded-2xl bg-black/30 p-3"><dt class="text-slate-400">PC states</dt><dd id="registry-webrtc-pc-stat" class="mt-1 font-semibold text-white">{@registry_webrtc_pc1_state} / {@registry_webrtc_pc2_state}</dd></div>
                <div class="rounded-2xl bg-black/30 p-3"><dt class="text-slate-400">ICE states</dt><dd id="registry-webrtc-ice-stat" class="mt-1 font-semibold text-white">{@registry_webrtc_ice_state}</dd></div>
                <div class="rounded-2xl bg-black/30 p-3"><dt class="text-slate-400">Ping / pong</dt><dd id="registry-webrtc-ping-stat" class="mt-1 font-semibold text-white">{@registry_webrtc_pings_sent} / {@registry_webrtc_pongs_received}</dd></div>
                <div class="rounded-2xl bg-black/30 p-3"><dt class="text-slate-400">Last message</dt><dd id="registry-webrtc-message-stat" class="mt-1 font-semibold text-white">{@registry_webrtc_last_message}</dd></div>
                <div class="rounded-2xl bg-black/30 p-3"><dt class="text-slate-400">Error</dt><dd id="registry-webrtc-error-stat" class="mt-1 font-semibold text-white">{@registry_webrtc_error}</dd></div>
                <div class="rounded-2xl bg-black/30 p-3"><dt class="text-slate-400">Callback events</dt><dd id="registry-webrtc-event-count-stat" class="mt-1 font-semibold text-white">{@registry_webrtc_event_count}</dd></div>
                <div class="rounded-2xl bg-black/30 p-3"><dt class="text-slate-400">Last callback</dt><dd id="registry-webrtc-last-event-stat" class="mt-1 font-semibold text-white">{@registry_webrtc_last_event}</dd></div>
                <div class="rounded-2xl bg-black/30 p-3"><dt class="text-slate-400">ICE candidates</dt><dd id="registry-webrtc-candidate-events-stat" class="mt-1 font-semibold text-white">{@registry_webrtc_ice_candidate_events}</dd></div>
                <div class="rounded-2xl bg-black/30 p-3"><dt class="text-slate-400">Conn / ICE callbacks</dt><dd id="registry-webrtc-state-events-stat" class="mt-1 font-semibold text-white">{@registry_webrtc_connection_state_events} / {@registry_webrtc_ice_connection_state_events}</dd></div>
                <div class="rounded-2xl bg-black/30 p-3"><dt class="text-slate-400">Datachannel callbacks</dt><dd id="registry-webrtc-datachannel-events-stat" class="mt-1 font-semibold text-white">{@registry_webrtc_datachannel_events}</dd></div>
                <div class="rounded-2xl bg-black/30 p-3"><dt class="text-slate-400">Message callbacks</dt><dd id="registry-webrtc-message-events-stat" class="mt-1 font-semibold text-white">{@registry_webrtc_message_events}</dd></div>
              </dl>
            </div>
          </div>
        </section>
      </main>
      """
    end

    def action(:initialize_canvas, _params, component) do
      JS.call(:CanvasProbe, :initialize, ["hologram-interop-canvas", "page"])

      put_state(
        component,
        :status,
        "Initializing canvas… draw in the canvas to collect normalized points"
      )
    end

    def action(:canvas_ready, params, component) do
      put_state(component,
        canvas_ready: true,
        status: "Canvas ready — draw a stroke",
        width: params.width,
        height: params.height,
        sample_count: params.sample_count
      )
    end

    def action(:canvas_stats, params, component) do
      put_state(component,
        sample_count: params.sample_count,
        latest_point_text: params.latest_point_text,
        status: "Drawing locally; Hologram received canvas stats"
      )
    end

    def action(:stroke_recorded, params, component) do
      strokes = component.state.strokes ++ [params.stroke]

      put_state(component,
        strokes: strokes,
        stroke_count: component.state.stroke_count + 1,
        sample_count: params.sample_count,
        latest_point_text: params.latest_point_text,
        last_stroke_points: params.point_count,
        status: "Stored stroke in Hologram state"
      )
    end

    def action(:replay_canvas, _params, component) do
      JS.call(:CanvasProbe, :redraw, ["hologram-interop-canvas", component.state.strokes])

      put_state(component, :status, "Replayed stored Hologram stroke state")
    end

    def action(:clear_canvas, _params, component) do
      JS.call(:CanvasProbe, :clear, ["hologram-interop-canvas"])

      put_state(component,
        status: "Canvas cleared",
        sample_count: 0,
        stroke_count: 0,
        latest_point_text: "—",
        last_stroke_points: 0,
        strokes: []
      )
    end

    def action(:create_reference_probes, _params, component) do
      direct_ref = JS.call(:ReferenceProbe, :createDirect, [])
      [registry_ref_id] = JS.call(:ReferenceProbe, :createRegistryObject, [])

      put_state(component,
        direct_ref: direct_ref,
        direct_ref_ready: true,
        direct_ref_touch_count: 0,
        direct_ref_action_count: 0,
        direct_ref_age_ms: 0,
        registry_ref_id: registry_ref_id,
        registry_ref_ready: true,
        registry_ref_touch_count: 0,
        registry_ref_action_count: 0,
        registry_ref_age_ms: 0,
        reference_status: "Created direct native object and registry-backed object",
        reference_exercise_result: "Ready for touch/exercise"
      )
    end

    def action(:touch_reference_probes, _params, component) do
      if component.state.direct_ref_ready and component.state.registry_ref_ready do
        [direct_touches, direct_actions, direct_age_ms, direct_alive] =
          JS.call(:ReferenceProbe, :touchDirect, [component.state.direct_ref, 1])

        [registry_touches, registry_actions, registry_age_ms, registry_alive] =
          JS.call(:ReferenceProbe, :touchRegistryObject, [component.state.registry_ref_id, 1])

        put_state(component,
          direct_ref_ready: direct_alive,
          direct_ref_touch_count: direct_touches,
          direct_ref_action_count: direct_actions,
          direct_ref_age_ms: direct_age_ms,
          registry_ref_ready: registry_alive,
          registry_ref_touch_count: registry_touches,
          registry_ref_action_count: registry_actions,
          registry_ref_age_ms: registry_age_ms,
          reference_status: "Touched both long-lived JS objects",
          reference_exercise_result: "Single touch succeeded"
        )
      else
        put_state(component, :reference_status, "Create reference probes before touching them")
      end
    end

    def action(:exercise_reference_probes, _params, component) do
      if component.state.direct_ref_ready and component.state.registry_ref_ready do
        JS.call(:ReferenceProbe, :dispatchActions, ["touch_reference_probes", "page", 50])

        put_state(component,
          reference_status: "Queued 50 Hologram actions against the same JS objects",
          reference_exercise_result: "50 touch actions queued"
        )
      else
        put_state(component, :reference_status, "Create reference probes before exercising them")
      end
    end

    def action(:destroy_reference_probes, _params, component) do
      if component.state.direct_ref_ready do
        JS.call(:ReferenceProbe, :destroyDirect, [component.state.direct_ref])
      end

      if component.state.registry_ref_ready do
        JS.call(:ReferenceProbe, :destroyRegistryObject, [component.state.registry_ref_id])
      end

      put_state(component,
        direct_ref: nil,
        direct_ref_ready: false,
        direct_ref_touch_count: 0,
        direct_ref_action_count: 0,
        direct_ref_age_ms: 0,
        registry_ref_id: "—",
        registry_ref_ready: false,
        registry_ref_touch_count: 0,
        registry_ref_action_count: 0,
        registry_ref_age_ms: 0,
        reference_status: "Destroyed reference probes",
        reference_exercise_result: "—"
      )
    end

    def action(:create_direct_webrtc_loopback, _params, component) do
      direct_ref = JS.call(:WebRTCProbe, :createDirect, ["page"])

      put_state(component,
        direct_webrtc_ref: direct_ref,
        direct_webrtc_status: "creating direct loopback",
        direct_webrtc_error: "—",
        direct_webrtc_event_count: 0,
        direct_webrtc_last_event: "—",
        direct_webrtc_ice_candidate_events: 0,
        direct_webrtc_connection_state_events: 0,
        direct_webrtc_ice_connection_state_events: 0,
        direct_webrtc_datachannel_events: 0,
        direct_webrtc_message_events: 0
      )
    end

    def action(:send_direct_webrtc_ping, _params, component) do
      if component.state.direct_webrtc_ref do
        JS.call(:WebRTCProbe, :sendDirectPing, [component.state.direct_webrtc_ref])
        put_state(component, :direct_webrtc_status, "direct ping requested")
      else
        put_state(component, :direct_webrtc_status, "create direct loopback first")
      end
    end

    def action(:close_direct_webrtc_loopback, _params, component) do
      if component.state.direct_webrtc_ref do
        JS.call(:WebRTCProbe, :closeDirect, [component.state.direct_webrtc_ref])
      end

      put_state(component,
        direct_webrtc_ref: nil,
        direct_webrtc_ready: false,
        direct_webrtc_status: "closed",
        direct_webrtc_channel_state: "closed"
      )
    end

    def action(:direct_webrtc_event, params, component) do
      put_state(component,
        direct_webrtc_ready: params.ready,
        direct_webrtc_status: params.status,
        direct_webrtc_pc1_state: params.pc1_state,
        direct_webrtc_pc2_state: params.pc2_state,
        direct_webrtc_ice_state: params.ice_state,
        direct_webrtc_channel_state: params.channel_state,
        direct_webrtc_pings_sent: params.pings_sent,
        direct_webrtc_pongs_received: params.pongs_received,
        direct_webrtc_last_message: params.last_message,
        direct_webrtc_error: params.error,
        direct_webrtc_event_count: params.event_count,
        direct_webrtc_last_event: params.last_event,
        direct_webrtc_ice_candidate_events: params.ice_candidate_events,
        direct_webrtc_connection_state_events: params.connection_state_events,
        direct_webrtc_ice_connection_state_events: params.ice_connection_state_events,
        direct_webrtc_datachannel_events: params.datachannel_events,
        direct_webrtc_message_events: params.message_events
      )
    end

    def action(:create_registry_webrtc_loopback, _params, component) do
      [registry_id] = JS.call(:WebRTCProbe, :createRegistry, ["page"])

      put_state(component,
        registry_webrtc_id: registry_id,
        registry_webrtc_status: "creating registry loopback",
        registry_webrtc_error: "—",
        registry_webrtc_event_count: 0,
        registry_webrtc_last_event: "—",
        registry_webrtc_ice_candidate_events: 0,
        registry_webrtc_connection_state_events: 0,
        registry_webrtc_ice_connection_state_events: 0,
        registry_webrtc_datachannel_events: 0,
        registry_webrtc_message_events: 0
      )
    end

    def action(:send_registry_webrtc_ping, _params, component) do
      if component.state.registry_webrtc_id != "—" do
        JS.call(:WebRTCProbe, :sendRegistryPing, [component.state.registry_webrtc_id])
        put_state(component, :registry_webrtc_status, "registry ping requested")
      else
        put_state(component, :registry_webrtc_status, "create registry loopback first")
      end
    end

    def action(:close_registry_webrtc_loopback, _params, component) do
      if component.state.registry_webrtc_id != "—" do
        JS.call(:WebRTCProbe, :closeRegistry, [component.state.registry_webrtc_id])
      end

      put_state(component,
        registry_webrtc_id: "—",
        registry_webrtc_ready: false,
        registry_webrtc_status: "closed",
        registry_webrtc_channel_state: "closed"
      )
    end

    def action(:registry_webrtc_event, params, component) do
      put_state(component,
        registry_webrtc_ready: params.ready,
        registry_webrtc_status: params.status,
        registry_webrtc_pc1_state: params.pc1_state,
        registry_webrtc_pc2_state: params.pc2_state,
        registry_webrtc_ice_state: params.ice_state,
        registry_webrtc_channel_state: params.channel_state,
        registry_webrtc_pings_sent: params.pings_sent,
        registry_webrtc_pongs_received: params.pongs_received,
        registry_webrtc_last_message: params.last_message,
        registry_webrtc_error: params.error,
        registry_webrtc_event_count: params.event_count,
        registry_webrtc_last_event: params.last_event,
        registry_webrtc_ice_candidate_events: params.ice_candidate_events,
        registry_webrtc_connection_state_events: params.connection_state_events,
        registry_webrtc_ice_connection_state_events: params.ice_connection_state_events,
        registry_webrtc_datachannel_events: params.datachannel_events,
        registry_webrtc_message_events: params.message_events
      )
    end
  end
end
