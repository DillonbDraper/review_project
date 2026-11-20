defmodule ReviewProjectWeb.Hologram.ConferencePanelTest do
  use ExUnit.Case, async: true
  alias Hologram.{Component, Server}
  alias Hologram.Template.Renderer
  alias ReviewProjectWeb.Hologram.ConferencePanel

  test "controls stay hidden before admission and appear with both devices off" do
    component = init()
    assert count(component, "#conference-panel[hidden]") == 1
    component = Component.put_state(component, connected: true)
    assert count(component, "#conference-panel[hidden]") == 0
    assert count(component, "#conference-microphone[aria-pressed=false]") == 1
    assert count(component, "#conference-camera[aria-pressed=false]") == 1
  end

  test "pending and denied devices leave joined controls available" do
    component =
      Component.put_state(init(),
        connected: true,
        microphone: "starting",
        camera_error: "Camera unavailable"
      )

    assert count(component, "#conference-panel[hidden]") == 0
    assert count(component, "#conference-microphone:not([disabled])") == 1
    assert count(component, "#conference-camera:not([disabled])") == 1
  end

  test "blocked playback offers a room audio gesture without capture" do
    component = Component.put_state(init(), connected: true, audio_blocked: true)
    assert count(component, "#conference-enable-audio") == 1
    assert component.state.microphone == "off"
  end

  test "unsupported calling keeps the room available" do
    component = Component.put_state(init(), connected: true, supported: false)
    assert count(component, "#conference-unsupported") == 1
    assert count(component, "#conference-microphone") == 0
  end

  test "named tile containers have stable seat IDs and self is labelled" do
    tiles = [tile("self", "Alex", true), tile("guest", "<script>Sam</script>", false)]
    component = Component.put_state(init(), connected: true, tiles: tiles)
    assert count(component, "#conference-tile-self[data-local=true][data-video=false]") == 1
    assert count(component, "#conference-tile-self .conference-you") == 1
    assert count(component, "#conference-media-guest") == 1
    assert count(component, "#conference-tile-guest .conference-you") == 0
    assert count(component, "#conference-name-guest script") == 0

    assert document(component) |> LazyHTML.query("#conference-name-guest") |> LazyHTML.text() ==
             "<script>Sam</script>"
  end

  test "video and no-video tiles use the same square container" do
    tiles = [
      %{tile("self", "Alex", true) | video?: true, status: "Camera on"},
      tile("guest", "Sam", false)
    ]

    component = Component.put_state(init(), connected: true, tiles: tiles)
    assert count(component, ".conference-tile") == 2
    assert count(component, "#conference-tile-self[data-video=true]") == 1
    assert count(component, "#conference-tile-guest[data-video=false]") == 1
    assert count(component, "#conference-tile-guest .conference-mic-status") == 1
  end

  defp tile(id, name, local?),
    do: %{
      id: id,
      name: name,
      local?: local?,
      video?: false,
      microphone?: false,
      status: "Camera off"
    }

  defp init, do: ConferencePanel.init(%{}, %Component{}, %Server{})

  defp count(component, selector) do
    document(component) |> LazyHTML.query(selector) |> Enum.count()
  end

  defp document(component) do
    {html, _registry, _server} =
      Renderer.render_dom(
        ConferencePanel.template().(component.state),
        %Renderer.Env{},
        %Server{}
      )

    LazyHTML.from_fragment(html)
  end
end
