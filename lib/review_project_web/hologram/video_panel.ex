defmodule ReviewProjectWeb.Hologram.VideoPanel do
  @moduledoc "Shared controls and client-side playback policy, independent of the native player."
  use Hologram.Component
  use Hologram.JS

  alias ReviewProject.VideoSource
  alias ReviewProjectWeb.Hologram.PlaybackState

  prop :room_id, :string, default: ""
  js_import from: "../../../assets/js/playback_native.mjs", as: :Player
  js_import from: "../../../assets/js/room_browser.mjs", as: :Browser
  js_import from: "../../../assets/js/playback_info.js", as: :PlaybackInfo

  @impl Component
  def init(props, component, _server) do
    state = PlaybackState.new(Map.get(props, :room_id, ""))

    put_state(
      component,
      Map.merge(PlaybackState.view(state), %{playback: state, switch_open: false})
    )
  end

  @impl Component
  def template do
    ~HOLO"""
    <section id="video-panel" class="workspace-card" aria-label="Video player" data-connected={@connected} data-controller={@can_control} data-playing={@playing} data-timeline-at={@timeline_at} data-rtt={@rtt}>
      <header class="video-header">
        {%if @video_id}
          <div class="video-source-controls">
            <input id="current-video-source" class="workspace-input" type="text" value="https://www.youtube.com/watch?v={@video_id}" readonly aria-label="Current video URL" />
            <button id="open-switch-video" type="button" class="secondary-button" $click="open_switch" disabled={!@can_control || @loading? || @busy} aria-haspopup="dialog" aria-controls="switch-video-dialog">Switch video</button>
          </div>
        {%else}
          <form id="video-source-form" $submit="load_video">
            <label for="video-source" class="sr-only">YouTube link</label>
            <div class="video-source-controls">
              <input id="video-source" name="source" type="text" value={@source} $input="update_source" placeholder="Paste Youtube link here to get started" maxlength="2048" required disabled={!@can_control || @loading? || @busy} aria-describedby="video-error" aria-invalid={if(@playback_error != "", do: "true", else: "false")} class="workspace-input" />
              <button id="load-video" type="submit" class="primary-button" disabled={!@can_control || @loading? || @busy}>{%if @loading? || @busy}Loading…{%else}Load video{/if}</button>
            </div>
          </form>
        {/if}
        <p id="video-error" role="status" class="field-error" hidden={@switch_open}>{@playback_error}</p>
      </header>
      <div id="video-stage" class="video-stage">
        <div id="video-player-host" class="video-player-host"></div>
        {%if !@video_id}
          <div id="video-empty" class="video-empty">
            <span class="video-orbit" aria-hidden="true"><span class="play-shape"></span></span>
            <span class="video-empty-kicker">GOOD IDEAS START WITH A CLOSER LOOK</span>
            <h3>Something worth watching.</h3>
            <p>{%if @can_control}Paste a YouTube link above to bring it into your workspace.{%else}Join the room and follow the selected video.{/if}</p>
          </div>
        {/if}
      </div>
      <div class="playback-controls" aria-label="Playback controls">
        <div class="playback-toolbar">
          <button id="video-play-pause" type="button" class="primary-button" $click="toggle" disabled={!@can_control || !@video_id || @busy || !@ready || @unsupported}>
            {%if @ended}Replay{%else}{%if @playing}Pause{%else}Play{/if}{/if}
          </button>
          <span id="video-time" class="playback-time" aria-live="off">{@elapsed} <span aria-hidden="true">/</span> {@total}</span>
          <span id="video-authority" class="playback-authority">{%if @can_control}You control playback{%else}Controlled by {@controller_name}{/if}</span>
        </div>
        <label class="sr-only" for="video-seek">Seek video</label>
        <input id="video-seek" class="playback-seek" type="range" min="0" max={@duration} step="0.1" value={@position} $input={:preview_seek, generation: @player_generation} $change.debounce(200)={:seek, generation: @player_generation, authority_revision: @authority_revision, revision: @playback_revision} disabled={!@can_control || !@ready || @duration <= 0 || @busy} aria-valuetext={@elapsed} />
        <div class="playback-local-controls">
          <button id="video-mute" type="button" class="secondary-button" $click="mute" disabled={!@ready} aria-pressed={if(@muted, do: "true", else: "false")}>{%if @muted}Unmute video{%else}Mute video{/if}</button>
          <label for="video-volume">Volume <span class="sr-only">on this device</span></label>
          <input id="video-volume" type="range" min="0" max="100" step="1" value={@volume} $input="volume" disabled={!@ready} aria-label="Video volume on this device" />
          {%if @video_id && (!@enabled || @blocked)}
            <window $resize="position_playback_info" $scroll="position_playback_info" />
            <div class="playback-enable-controls">
              <button id="video-enable" type="button" class="secondary-button" $click="enable" disabled={!@ready || !@connected || @unsupported}>Enable playback on this device</button>
              <button id="video-enable-info" type="button" class="playback-info-button" popovertarget="video-enable-explanation" aria-label="Why enable playback on this device?" $click="playback_info_clicked">
                <span class="hero-information-circle size-5" aria-hidden="true"></span>
              </button>
              <div id="video-enable-explanation" class="playback-info-popover" popover="auto">Some browsers may need explicit approval to allow syncing video playback</div>
            </div>
          {/if}
          {%if @player_error != ""}
            <button id="video-retry" type="button" class="secondary-button" $click="retry" disabled={!@connected}>Retry playback</button>
          {/if}
        </div>
        <p id="video-playback-status" class="field-hint" role="status">{@playback_status}</p>
        <p id="video-player-error" class="field-error" role="status">{@player_error}</p>
      </div>
      <dialog id="switch-video-dialog" class="room-dialog" aria-labelledby="switch-video-heading" $key_down.escape.prevent_default="close_switch">
        <div class="room-dialog-heading">
          <span class="eyebrow">UP NEXT</span>
          <button id="close-switch-video" type="button" class="dialog-close" $click="close_switch" aria-label="Close switch video">Close</button>
        </div>
        <h2 id="switch-video-heading">Switch video</h2>
        <p class="room-dialog-description">Choose what to watch next. Your current video stays until the new link is accepted.</p>
        <form id="switch-video-form" $submit="load_video">
          <label for="switch-video-source" class="field-label">YouTube link</label>
          <input id="switch-video-source" name="source" type="text" value={@source} $input="update_source" placeholder="Paste a YouTube link" maxlength="2048" required autofocus disabled={!@can_control || @loading? || @busy} aria-describedby="switch-video-error" aria-invalid={if(@playback_error != "", do: "true", else: "false")} class="workspace-input" />
          <p id="switch-video-error" role="status" class="field-error">{@playback_error}</p>
          <button id="switch-video-submit" type="submit" class="primary-button room-submit" disabled={!@can_control || @loading? || @busy}>{%if @loading? || @busy}Loading…{%else}Load video{/if}</button>
        </form>
      </dialog>
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

  def action(:playback_info_clicked, _params, component) do
    # The native click default opens/closes the popover after this action returns.
    put_action(component, name: :position_playback_info, delay: 1)
  end

  def action(:position_playback_info, _params, component) do
    JS.call(:PlaybackInfo, :position, [])
    component
  end

  def action(:update_source, %{event: %{value: value}}, component),
    do: transition(component, :source, %{value: value})

  def action(:load_video, %{event: %{"source" => source}}, component),
    do: transition(component, :select, %{source: source})

  def action(:open_switch, _params, component) do
    if component.state.can_control and component.state.video_id != nil and
         not component.state.loading? and not component.state.busy do
      JS.call(:Browser, :dialog, ["switch-video-dialog", true])

      component
      |> transition(:source, %{value: ""})
      |> put_state(:switch_open, true)
    else
      component
    end
  end

  def action(:close_switch, _params, component) do
    JS.call(:Browser, :dialog, ["switch-video-dialog", false])
    put_state(component, :switch_open, false)
  end

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
    previous = component.state.playback
    {state, effects} = PlaybackState.event(previous, event, params)

    selection_pending? =
      previous.loading or (previous.pending != nil and previous.pending.command.op == "video")

    selection_finished? =
      selection_pending? and not state.loading and state.pending == nil and state.error == ""

    video_changed? =
      state.desired != nil and state.desired.video_id != component.state.video_id

    component = put_state(component, Map.put(PlaybackState.view(state), :playback, state))

    component =
      if component.state.switch_open and
           (selection_finished? or video_changed? or not component.state.can_control) do
        action(:close_switch, %{}, component)
      else
        component
      end

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
