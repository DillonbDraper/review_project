defmodule ReviewProjectWeb.Hologram.VideoPanel do
  @moduledoc "Shared controls and client-side playback policy, independent of the native player."
  use Hologram.Component
  use Hologram.JS

  alias ReviewProject.VideoSource
  alias ReviewProjectWeb.Hologram.PlaybackState

  prop :room_id, :string, default: ""
  js_import from: "../../../assets/js/playback_native.mjs", as: :Player
  js_import from: "../../../assets/js/room_browser.mjs", as: :Browser

  @impl Component
  def init(props, component, _server) do
    state = PlaybackState.new(Map.get(props, :room_id, ""))
    put_state(component, Map.put(PlaybackState.view(state), :playback, state))
  end

  @impl Component
  def template do
    ~HOLO"""
    <section id="video-panel" class="workspace-card" aria-labelledby="video-heading" data-connected={@connected} data-controller={@can_control} data-playing={@playing} data-timeline-at={@timeline_at} data-rtt={@rtt}>
      <div class="panel-heading">
        <div class="flex items-center gap-3"><span class="section-number">01</span><h2 id="video-heading">The video</h2></div>
        {%if @video_id}
          <a id="open-youtube" class="youtube-link" href="https://www.youtube.com/watch?v={@video_id}" target="_blank" rel="noopener noreferrer">Open on YouTube</a>
        {%else}
          <span class="panel-meta">YOUTUBE</span>
        {/if}
      </div>
      <div id="video-stage" class="video-stage">
        <div id="video-player-host" class="video-player-host"></div>
        {%if !@video_id}
          <div id="video-empty" class="video-empty">
            <span class="video-orbit" aria-hidden="true"><span class="play-shape"></span></span>
            <span class="video-empty-kicker">GOOD IDEAS START WITH A CLOSER LOOK</span>
            <h3>Something worth watching.</h3>
            <p>{%if @can_control}Paste a YouTube link below to bring it into your workspace.{%else}Join the room and follow the selected video.{/if}</p>
          </div>
        {/if}
      </div>
      <div class="playback-controls" aria-label="Playback controls">
        <div class="playback-toolbar">
          <button id="video-play-pause" type="button" class="primary-button" $click="toggle" disabled={!@can_control || !@video_id || @busy || !@ready || @unsupported}>
            {%if @ended}Replay{%else}{%if @playing}Pause{%else}Play{/if}{/if}
          </button>
          <span id="video-time" class="playback-time" aria-live="off">{@elapsed} <span aria-hidden="true">/</span> {@total}</span>
          <span id="video-authority" class="playback-authority">{%if @solo}On this device{%else}{%if @can_control}You control playback{%else}Controlled by {@controller_name}{/if}{/if}</span>
        </div>
        <label class="sr-only" for="video-seek">Seek video</label>
        <input id="video-seek" class="playback-seek" type="range" min="0" max={@duration} step="0.1" value={@position} $input={:preview_seek, generation: @player_generation} $change.debounce(200)={:seek, generation: @player_generation, authority_revision: @authority_revision, revision: @playback_revision} disabled={!@can_control || !@ready || @duration <= 0 || @busy} aria-valuetext={@elapsed} />
        <div class="playback-local-controls">
          <button id="video-mute" type="button" class="secondary-button" $click="mute" disabled={!@ready} aria-pressed={if(@muted, do: "true", else: "false")}>{%if @muted}Unmute video{%else}Mute video{/if}</button>
          <label for="video-volume">Volume <span class="sr-only">on this device</span></label>
          <input id="video-volume" type="range" min="0" max="100" step="1" value={@volume} $input="volume" disabled={!@ready} aria-label="Video volume on this device" />
          {%if @video_id && (!@enabled || @blocked)}
            <button id="video-enable" type="button" class="secondary-button" $click="enable" disabled={!@ready || !@connected || @unsupported}>Enable playback on this device</button>
          {/if}
          {%if @player_error != ""}
            <button id="video-retry" type="button" class="secondary-button" $click="retry" disabled={!@connected}>Retry playback</button>
          {/if}
        </div>
        <p id="video-playback-status" class="field-hint" role="status">{@playback_status}</p>
        <p id="video-player-error" class="field-error" role="status">{@player_error}</p>
      </div>
      <div class="video-source-area">
        <form id="video-source-form" $submit="load_video">
          <label for="video-source" class="field-label">YouTube link</label>
          <div class="video-source-controls">
            <input id="video-source" name="source" type="text" value={@source} $change="update_source" placeholder="Paste a YouTube URL or video ID" maxlength="2048" required disabled={!@can_control || @busy} aria-describedby="video-source-help video-error" aria-invalid={if(@playback_error != "", do: "true", else: "false")} class="workspace-input" />
            <button id="load-video" type="submit" class="primary-button" disabled={!@can_control || @loading? || @busy}>{%if @loading?}Loading…{%else}Load video{/if}</button>
          </div>
          <p id="video-error" role="status" class="field-error">{@playback_error}</p>
          <p id="video-source-help" class="field-hint">Individual videos and Shorts. Volume and mute affect only this device.</p>
        </form>
      </div>
    </section>
    """
  end

  @impl Component
  def action(:player_mounted, _params, component) do
    state = component.state.playback

    generation =
      JS.call(:Player, :start, [state.connected, state.sample.volume, state.sample.muted]) ||
        state.generation + 1

    transition(component, :mounted, %{generation: generation})
  end

  def action(:room_event, params, component) do
    state = component.state.playback

    if params.room_generation >= state.room_generation do
      {event, data} =
        case params.kind do
          :joined ->
            generation =
              JS.call(:Player, :start, [true, state.sample.volume, state.sample.muted]) ||
                state.generation + 1

            {:joined, Map.put(params, :generation, generation)}

          :roster ->
            {:room_snapshot, Map.put(params, :generation, state.generation)}

          :stopped ->
            generation =
              JS.call(:Player, :start, [false, state.sample.volume, state.sample.muted]) ||
                state.generation + 1

            {:stopped, Map.put(params, :generation, generation)}
        end

      component = transition(component, event, data)
      %{component | next_action: Map.get(params, :next_action)}
    else
      %{component | next_action: Map.get(params, :next_action)}
    end
  end

  def action(:player_sample, params, component) do
    now = JS.call(:Player, :now, []) || params.now
    if now - params.now <= 500, do: transition(component, :sample, params), else: component
  end

  def action(:player_visible, params, component), do: transition(component, :visible, params)

  def action(:update_source, %{event: %{value: value}}, component),
    do: transition(component, :source, %{value: value})

  def action(:load_video, %{event: %{"source" => source}}, component),
    do: transition(component, :select, %{source: source})

  def action(:source_resolved, params, component), do: transition(component, :resolved, params)
  def action(:source_invalid, params, component), do: transition(component, :invalid, params)

  def action(:snapshot_result, params, component),
    do: transition(component, :snapshot_result, params)

  def action(:control_result, params, component),
    do: transition(component, :control_result, params)

  def action(:toggle, _, component), do: transition(component, :toggle, %{})
  def action(:enable, _, component), do: transition(component, :enable, %{})
  def action(:mute, _, component), do: transition(component, :mute, %{})

  def action(:preview_seek, %{event: %{value: raw}} = params, component),
    do: numeric(component, :preview_seek, :position, raw, params)

  def action(:seek, %{event: %{value: raw}} = params, component),
    do: numeric(component, :seek, :position, raw, params)

  def action(:volume, %{event: %{value: raw}}, component),
    do: numeric(component, :volume, :volume, raw)

  def action(:retry, _, component) do
    state = component.state.playback

    generation =
      JS.call(:Player, :start, [true, state.sample.volume, state.sample.muted]) ||
        state.generation + 1

    transition(component, :mounted, %{generation: generation})
  end

  defp numeric(component, event, key, raw, params \\ %{}) do
    case Float.parse(raw) do
      {number, ""} ->
        transition(
          component,
          event,
          Map.merge(Map.take(params, [:generation, :authority_revision, :revision]), %{
            key => number
          })
        )

      _ ->
        component
    end
  end

  @impl Component
  def command(:resolve_video, params, server) do
    result = VideoSource.youtube_id(params.source)
    live_path = is_binary(params.source) and String.contains?(params.source, "/live/")
    metadata = Map.take(params, [:generation, :request])

    case result do
      {:ok, id} when not live_path ->
        put_action(server, :source_resolved, Map.put(metadata, :video_id, id))

      _ ->
        put_action(server, :source_invalid, metadata)
    end
  end

  defp transition(component, event, params) do
    {state, effects} = PlaybackState.event(component.state.playback, event, params)
    component = put_state(component, Map.put(PlaybackState.view(state), :playback, state))
    Enum.reduce(effects, component, fn effect, component -> perform(component, state, effect) end)
  end

  defp perform(component, state, {:resolve, source, request}),
    do:
      put_command(component, :resolve_video, %{
        source: source,
        request: request,
        generation: state.generation
      })

  defp perform(component, state, {:load, id}) do
    JS.call(:Player, :load, [state.generation, id])
    component
  end

  defp perform(component, state, {:native, operation, value}) do
    JS.call(:Player, :command, [state.generation, operation, value])
    component
  end

  defp perform(component, state, {:snapshot, request}) do
    JS.call(:Browser, :push, [
      "snapshot",
      %{},
      "video-panel",
      "snapshot_result",
      %{generation: state.generation, request: request}
    ])

    component
  end

  defp perform(component, state, {:control, payload, request}) do
    JS.call(:Browser, :push, [
      "control",
      payload,
      "video-panel",
      "control_result",
      %{generation: state.generation, request: request}
    ])

    component
  end
end
