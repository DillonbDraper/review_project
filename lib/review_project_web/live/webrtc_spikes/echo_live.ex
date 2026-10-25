defmodule ReviewProjectWeb.WebRTCSpikes.EchoLive do
  @moduledoc """
  Browser-facing harness for the raw `membrane_webrtc_plugin` RTC-layer spike.

  This page proves the viability of building on `membrane_webrtc_plugin`
  directly (rather than the higher-level Fishjam/RTC engine). It uses the
  plugin's own `Membrane.WebRTC.Live.Capture` and `Membrane.WebRTC.Live.Player`
  components, which handle browser PeerConnection setup and signaling over the
  LiveView socket, paired with a tiny Membrane pipeline that loops the captured
  media straight back (`Source` -> `Sink`).
  """

  use ReviewProjectWeb, :live_view

  require Logger

  alias Membrane.WebRTC.Live.{Capture, Player}
  alias ReviewProject.MediaSpikes.WebRTCEchoPipeline

  @ice_servers [%{urls: "stun:stun.l.google.com:19302"}]
  @source_ice_port_range 50_000..50_020
  @sink_ice_port_range 50_021..50_040
  @max_notifications 20

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "WebRTC echo spike")
      |> assign(:pipeline_pid, nil)
      |> assign(:pipeline_supervisor_pid, nil)
      |> assign(:source_ice_port_range, @source_ice_port_range)
      |> assign(:sink_ice_port_range, @sink_ice_port_range)
      |> assign(:recent_notifications, [])
      |> assign(:startup_error, nil)

    socket =
      if connected?(socket) do
        start_echo_pipeline(socket)
      else
        socket
      end

    {:ok, socket}
  end

  # Starts the echo pipeline and attaches the plugin's Capture/Player LiveViews,
  # wiring each browser PeerConnection to its Membrane element via a shared
  # `Membrane.WebRTC.Signaling`.
  defp start_echo_pipeline(socket) do
    capture_signaling = Membrane.WebRTC.Signaling.new()
    player_signaling = Membrane.WebRTC.Signaling.new()

    case Membrane.Pipeline.start_link(WebRTCEchoPipeline,
           capture_signaling: capture_signaling,
           player_signaling: player_signaling,
           notify: self(),
           ice_servers: @ice_servers,
           source_ice_port_range: @source_ice_port_range,
           sink_ice_port_range: @sink_ice_port_range
         ) do
      {:ok, supervisor_pid, pipeline_pid} ->
        socket
        |> assign(:pipeline_supervisor_pid, supervisor_pid)
        |> assign(:pipeline_pid, pipeline_pid)
        |> Capture.attach(id: "spike-capture", signaling: capture_signaling)
        |> Player.attach(id: "spike-player", signaling: player_signaling)

      {:error, reason} ->
        Logger.error("Failed to start WebRTC echo spike pipeline: #{inspect(reason)}")
        assign(socket, :startup_error, inspect(reason))
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <main
        id="webrtc-spike-page"
        class="min-h-[80vh] bg-slate-950 px-4 py-8 text-slate-100 sm:px-6 lg:px-8"
      >
        <div class="mx-auto max-w-6xl space-y-8">
          <section class="overflow-hidden rounded-3xl border border-white/10 bg-white/[0.04] shadow-2xl shadow-cyan-950/40">
            <div class="relative p-6 sm:p-8">
              <div class="absolute inset-x-0 top-0 h-px bg-gradient-to-r from-transparent via-cyan-300/70 to-transparent">
              </div>
              <p class="text-sm font-semibold uppercase tracking-[0.35em] text-cyan-300">
                Phase 0 / RTC-layer decision
              </p>
              <div class="mt-4 grid gap-6 lg:grid-cols-[1.2fr_0.8fr] lg:items-end">
                <div>
                  <h1 class="text-3xl font-bold tracking-tight text-white sm:text-5xl">
                    Raw Membrane WebRTC echo spike
                  </h1>
                  <p class="mt-4 max-w-3xl text-base leading-7 text-slate-300">
                    This page sends your browser camera + microphone to
                    <code class="rounded bg-black/40 px-1.5 py-0.5 text-cyan-200">
                      Membrane.WebRTC.Source
                    </code>
                    and loops it back through <code class="rounded bg-black/40 px-1.5 py-0.5 text-cyan-200">Membrane.WebRTC.Sink</code>.
                    Signaling is handled by the plugin's own
                    <code class="rounded bg-black/40 px-1.5 py-0.5 text-cyan-200">Live.Capture</code>
                    / <code class="rounded bg-black/40 px-1.5 py-0.5 text-cyan-200">Live.Player</code>
                    components — the goal is to prove native deps, ICE, DTLS/SRTP,
                    and a fixed server UDP port range on the raw plugin.
                  </p>
                </div>
                <div
                  id="spike-status-card"
                  class="rounded-2xl border border-cyan-300/20 bg-cyan-300/10 p-5"
                >
                  <p class="text-sm font-medium text-cyan-100">Pipeline status</p>
                  <p id="pipeline-status" class="mt-2 text-2xl font-semibold text-white">
                    <%= cond do %>
                      <% @startup_error -> %>
                        Failed
                      <% @pipeline_pid -> %>
                        Running — allow camera access
                      <% true -> %>
                        Connecting LiveView…
                    <% end %>
                  </p>
                  <p class="mt-2 text-sm text-cyan-100/80">
                    Server ICE UDP ranges:
                    <span id="ice-port-range" class="font-mono text-white">
                      source {inspect(@source_ice_port_range)}, sink {inspect(@sink_ice_port_range)}
                    </span>
                  </p>
                </div>
              </div>
            </div>
          </section>

          <%= if @startup_error do %>
            <section
              id="webrtc-startup-error"
              class="rounded-2xl border border-rose-400/30 bg-rose-500/10 p-5 text-rose-100"
            >
              <h2 class="font-semibold">Spike startup failed</h2>
              <p class="mt-2 font-mono text-sm">{@startup_error}</p>
            </section>
          <% end %>

          <section class="grid gap-6 lg:grid-cols-2">
            <div
              id="capture-panel"
              class="rounded-3xl border border-white/10 bg-slate-900/80 p-5 shadow-xl"
            >
              <div class="mb-4">
                <h2 class="text-xl font-semibold text-white">Capture peer</h2>
                <p class="text-sm text-slate-400">Browser → Membrane.Source</p>
              </div>
              <div class="aspect-video overflow-hidden rounded-2xl border border-white/10 bg-black">
                <%= if @pipeline_pid do %>
                  <Capture.live_render
                    socket={@socket}
                    capture_id="spike-capture"
                    class="h-full w-full object-cover"
                  />
                <% end %>
              </div>
            </div>

            <div
              id="player-panel"
              class="rounded-3xl border border-white/10 bg-slate-900/80 p-5 shadow-xl"
            >
              <div class="mb-4">
                <h2 class="text-xl font-semibold text-white">Player peer</h2>
                <p class="text-sm text-slate-400">Membrane.Sink → Browser</p>
              </div>
              <div class="aspect-video overflow-hidden rounded-2xl border border-white/10 bg-black">
                <%= if @pipeline_pid do %>
                  <Player.live_render
                    socket={@socket}
                    player_id="spike-player"
                    class="h-full w-full object-cover"
                  />
                <% end %>
              </div>
            </div>
          </section>

          <section id="webrtc-spike-instructions" class="grid gap-6 lg:grid-cols-[0.9fr_1.1fr]">
            <div class="rounded-3xl border border-white/10 bg-white/[0.04] p-6">
              <h2 class="text-lg font-semibold text-white">Pass criteria</h2>
              <ul class="mt-4 space-y-3 text-sm leading-6 text-slate-300">
                <li class="flex gap-3">
                  <span class="text-cyan-300">1.</span><span>Allow camera + microphone access when the browser prompts.</span>
                </li>
                <li class="flex gap-3">
                  <span class="text-cyan-300">2.</span><span>The capture panel shows your local (mirrored) preview.</span>
                </li>
                <li class="flex gap-3">
                  <span class="text-cyan-300">3.</span><span>The player panel displays the same media looped back through Membrane.</span>
                </li>
                <li class="flex gap-3">
                  <span class="text-cyan-300">4.</span><span>Membrane notifications below show the Source/Sink tracks negotiating and playing.</span>
                </li>
              </ul>
            </div>

            <div class="rounded-3xl border border-white/10 bg-white/[0.04] p-6">
              <h2 class="text-lg font-semibold text-white">Membrane notifications</h2>
              <div id="pipeline-notifications" class="mt-4 space-y-2">
                <div
                  :for={notification <- @recent_notifications}
                  class="rounded-xl bg-black/40 p-3 font-mono text-xs text-slate-300"
                >
                  {notification}
                </div>
                <div
                  :if={@recent_notifications == []}
                  class="rounded-xl bg-black/40 p-3 text-sm text-slate-500"
                >
                  No pipeline notifications yet.
                </div>
              </div>
            </div>
          </section>
        </div>
      </main>
    </Layouts.app>
    """
  end

  @impl true
  def handle_info({:webrtc_echo_pipeline, child, notification}, socket) do
    {:noreply, add_notification(socket, {child, notification})}
  end

  def handle_info({event, child}, socket)
      when event in [:webrtc_echo_pipeline_child_playing, :webrtc_echo_pipeline_child_terminated] do
    {:noreply, add_notification(socket, {event, child})}
  end

  @impl true
  def terminate(_reason, %{assigns: %{pipeline_pid: pipeline_pid}}) when is_pid(pipeline_pid) do
    if Process.alive?(pipeline_pid) do
      Membrane.Pipeline.terminate(pipeline_pid, timeout: 1_000, force?: true)
    end

    :ok
  end

  def terminate(_reason, _socket), do: :ok

  defp add_notification(socket, notification) do
    notification = inspect(notification, pretty: true, limit: 20)

    update(socket, :recent_notifications, fn notifications ->
      [notification | notifications]
      |> Enum.take(@max_notifications)
    end)
  end
end
