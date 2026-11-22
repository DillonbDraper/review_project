defmodule ReviewProjectWeb.Hologram.ConferencePanel do
  @moduledoc "Conference controls and client-side Elixir orchestration."
  use Hologram.Component
  alias ReviewProjectWeb.Hologram.{ConferenceBrowser, ConferenceState}

  @impl Component
  def init(_props, component, _server) do
    state = ConferenceState.new()
    put_state(component, Map.put(ConferenceState.view(state), :conference, state))
  end

  @impl Component
  def template do
    ~HOLO"""
    <section id="conference-panel" hidden={!@connected} aria-label="Room participants" class="workspace-card conference-panel">
      <div id="conference-tiles" class="conference-tiles" aria-label="Call participants">
        {%for tile <- @tiles}
          <article id="conference-tile-{tile.id}" class="conference-tile" data-seat-id={tile.id} data-local={if(tile.local?, do: "true", else: "false")} data-video={if(tile.video?, do: "true", else: "false")} aria-labelledby="conference-name-{tile.id}">
            <div id="conference-media-{tile.id}" class="conference-media" aria-hidden="true"></div>
            <span id="conference-video-status-{tile.id}" class="conference-video-status">{tile.status}</span>
            {%if !tile.microphone?}<span class="conference-mic-status">Mic off</span>{/if}
            <div class="conference-caption">
              <span id="conference-name-{tile.id}" class="conference-name" title={tile.name}>{tile.name}</span>
              {%if tile.local?}<span class="conference-you">You</span>{/if}
            </div>
          </article>
        {/for}
      </div>
      <div class="conference-controls">
      {%if @supported}
        <div class="conference-buttons">
          <button id="conference-microphone" type="button" class="secondary-button" $click="toggle_microphone" aria-pressed={if(@microphone == "on", do: "true", else: "false")} disabled={!@connected}>
            {%if @microphone == "starting"}Cancel microphone request{%else}{%if @microphone == "on"}Mute microphone{%else}Turn on microphone{/if}{/if}
          </button>
          <button id="conference-camera" type="button" class="secondary-button" $click="toggle_camera" aria-pressed={if(@camera == "on", do: "true", else: "false")} disabled={!@connected}>
            {%if @camera == "starting"}Cancel camera request{%else}{%if @camera == "on"}Turn off camera{%else}Turn on camera{/if}{/if}
          </button>
          {%if @audio_blocked}
            <button id="conference-enable-audio" type="button" class="primary-button" $click="enable_audio">Enable room audio</button>
          {/if}
          {%if @retry_available}
            <button id="conference-retry" type="button" class="secondary-button" $click="retry_call">Retry call connection</button>
          {/if}
        </div>
      {%else}
        <p id="conference-unsupported" role="status" class="field-hint">Calling is unavailable in this browser. You can still use the room and chat.</p>
      {/if}
      <p id="conference-microphone-error" role="status" class="field-error">{@microphone_error}</p>
      <p id="conference-camera-error" role="status" class="field-error">{@camera_error}</p>
      <p id="conference-error" role="status" class="field-error">{@error}</p>
      <p id="conference-network-error" role="status" class="field-error">{@ice_error}</p>
      </div>
      <div id="conference-audio" hidden></div>
    </section>
    """
  end

  @impl Component
  def action(:toggle_microphone, _params, component),
    do: transition(component, :toggle, %{kind: "audio"})

  def action(:toggle_camera, _params, component),
    do: transition(component, :toggle, %{kind: "video"})

  def action(:sync_tiles, params, component) do
    state = ConferenceBrowser.sync_tiles(component.state.conference)
    component = put_state(component, :conference, state)
    %{component | next_action: Map.get(params, :next_action)}
  end

  def action(:ice_result, params, component) do
    state = component.state.conference

    if state.connected and state.generation == params.generation and
         state.ice_request == params.request do
      {event, data} = ConferenceBrowser.retain_ice(state, params)
      transition(component, event, data)
    else
      component
    end
  end

  def action(event, params, component), do: transition(component, event, params)

  defp transition(component, event, params) do
    {state, effects} = ConferenceState.event(component.state.conference, event, params)
    component = put_state(component, Map.put(ConferenceState.view(state), :conference, state))

    Enum.reduce(effects, component, fn effect, component ->
      Enum.reduce(
        ConferenceBrowser.perform(component.state.conference, effect),
        component,
        fn {event, params}, component -> transition(component, event, params) end
      )
    end)
    |> put_action(name: :sync_tiles, params: %{next_action: Map.get(params, :next_action)})
  end
end
