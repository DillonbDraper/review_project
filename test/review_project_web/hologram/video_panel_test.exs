defmodule ReviewProjectWeb.Hologram.VideoPanelTest do
  use ExUnit.Case, async: true
  alias Hologram.{Component, Server}
  alias Hologram.Template.Renderer
  alias ReviewProjectWeb.Hologram.VideoPanel

  defp select(component, source) do
    component = VideoPanel.action(:load_video, %{event: %{"source" => source}}, component)
    command = component.next_command
    server = VideoPanel.command(command.name, command.params, %Server{})
    action = server.next_action
    VideoPanel.action(action.name, action.params, component)
  end

  test "solo selection retains a stable native-owned host and accessible controls" do
    component =
      VideoPanel.init(%{}, %Component{}, %Server{}) |> select("https://youtu.be/M7lc1UVf-VE")

    document = document(component)
    assert component.state.video_id == "M7lc1UVf-VE"
    assert Enum.count(LazyHTML.query(document, "#video-player-host")) == 1
    assert Enum.empty?(LazyHTML.query(document, "#video-empty"))

    assert LazyHTML.attribute(LazyHTML.query(document, "#open-youtube"), "href") == [
             "https://www.youtube.com/watch?v=M7lc1UVf-VE"
           ]

    assert Enum.count(LazyHTML.query(document, "#video-play-pause")) == 1
    assert Enum.count(LazyHTML.query(document, "#video-seek[aria-valuetext]")) == 1
    refute component.state.loading?
  end

  test "invalid replacements preserve selection and live/playlist-only input is explained" do
    component = VideoPanel.init(%{}, %Component{}, %Server{}) |> select("M7lc1UVf-VE")

    for source <- [
          "https://evil.example",
          "https://youtube.com/live/M7lc1UVf-VE",
          "https://youtube.com/playlist?list=123"
        ] do
      invalid = select(component, source)
      assert invalid.state.video_id == component.state.video_id
      document = document(invalid)
      assert Enum.count(LazyHTML.query(document, "#video-player-host")) == 1
      assert Enum.count(LazyHTML.query(document, "#video-source[aria-invalid='true']")) == 1
      assert LazyHTML.text(LazyHTML.query(document, "#video-error")) != ""
    end
  end

  test "room playback is unavailable before admission and forged selection events do not resolve" do
    component = VideoPanel.init(%{room_id: "room"}, %Component{}, %Server{})
    assert Enum.count(LazyHTML.query(document(component), "#load-video[disabled]")) == 1
    assert Enum.count(LazyHTML.query(document(component), "#video-play-pause[disabled]")) == 1
    attempted = VideoPanel.action(:load_video, %{event: %{"source" => "M7lc1UVf-VE"}}, component)
    assert attempted.next_command == nil
    assert attempted.state.video_id == nil
  end

  test "stale source resolution cannot replace a newer player generation" do
    component = VideoPanel.init(%{}, %Component{}, %Server{})
    component = VideoPanel.action(:load_video, %{event: %{"source" => "M7lc1UVf-VE"}}, component)

    stale =
      VideoPanel.action(
        :source_resolved,
        %{request: 1, generation: -1, video_id: "M7lc1UVf-VE"},
        component
      )

    assert stale.state.video_id == nil
  end

  defp document(component) do
    {html, _, _} =
      Renderer.render_dom(VideoPanel.template().(component.state), %Renderer.Env{}, %Server{})

    LazyHTML.from_fragment(html)
  end
end
