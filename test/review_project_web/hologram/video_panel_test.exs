defmodule ReviewProjectWeb.Hologram.VideoPanelTest do
  use ExUnit.Case, async: true

  alias Hologram.{Component, Server}
  alias Hologram.Template.Renderer
  alias ReviewProjectWeb.Hologram.VideoPanel

  setup do
    %{component: VideoPanel.init(%{}, %Component{}, %Server{})}
  end

  test "a valid source loads a titled YouTube iframe", %{component: component} do
    params = %{event: %{"source" => "https://youtu.be/M7lc1UVf-VE"}}
    component = VideoPanel.action(:load_video, params, component)
    assert component.state.loading?

    command = component.next_command
    server = VideoPanel.command(command.name, command.params, %Server{})
    action = server.next_action
    component = VideoPanel.action(action.name, action.params, component)
    document = document(component)

    assert document |> LazyHTML.query("#youtube-player") |> LazyHTML.attribute("src") == [
             "https://www.youtube-nocookie.com/embed/M7lc1UVf-VE"
           ]

    assert document |> LazyHTML.query("#youtube-player") |> LazyHTML.attribute("title") == [
             "YouTube video player"
           ]

    assert document |> LazyHTML.query("#video-empty") |> Enum.empty?()
    refute component.state.loading?
  end

  test "an invalid replacement preserves the current player and displays an error", %{
    component: component
  } do
    component =
      VideoPanel.action(
        :video_loaded,
        %{
          video_id: "M7lc1UVf-VE",
          embed_url: "https://www.youtube-nocookie.com/embed/M7lc1UVf-VE"
        },
        component
      )

    server = VideoPanel.command(:resolve_video, %{source: "https://evil.example"}, %Server{})
    action = server.next_action
    component = VideoPanel.action(action.name, action.params, component)
    document = document(component)

    assert document |> LazyHTML.query("#youtube-player") |> Enum.count() == 1
    assert document |> LazyHTML.query("#video-source[aria-invalid='true']") |> Enum.count() == 1
    assert document |> LazyHTML.query("#video-error") |> LazyHTML.text() != ""
    refute component.state.loading?
  end

  defp document(component) do
    {html, _registry, _server} =
      Renderer.render_dom(VideoPanel.template().(component.state), %Renderer.Env{}, %Server{})

    LazyHTML.from_fragment(html)
  end
end
