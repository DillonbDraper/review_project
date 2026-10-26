defmodule ReviewProjectWeb.Hologram.ChatPanelTest do
  use ExUnit.Case, async: true

  alias Hologram.{Component, Server}
  alias Hologram.Template.Renderer
  alias ReviewProjectWeb.Hologram.ChatPanel

  setup do
    %{component: ChatPanel.init(%{}, %Component{}, %Server{})}
  end

  test "sending a message displays it and clears the composer", %{component: component} do
    component = ChatPanel.action(:update_draft, %{event: %{value: "A good moment"}}, component)

    component =
      ChatPanel.action(:send_message, %{event: %{"message" => " A good moment "}}, component)

    document = document(component)

    assert document |> LazyHTML.query("#chat-message-1 p") |> LazyHTML.text() == "A good moment"
    assert document |> LazyHTML.query("#chat-empty") |> Enum.empty?()
    assert component.state.draft == ""
    assert component.state.error == nil
  end

  test "blank and oversized messages leave the history unchanged", %{component: component} do
    for message <- ["  \n ", String.duplicate("a", 1001)] do
      result = ChatPanel.action(:send_message, %{event: %{"message" => message}}, component)
      assert result.state.messages == []
      assert result.state.error != nil
    end
  end

  test "message content is rendered as text", %{component: component} do
    body = "<script>alert('test')</script>"
    component = ChatPanel.action(:send_message, %{event: %{"message" => body}}, component)
    document = document(component)

    assert document |> LazyHTML.query("#chat-message-1 script") |> Enum.empty?()
    assert document |> LazyHTML.query("#chat-message-1 p") |> LazyHTML.text() == body
  end

  test "only the latest 100 messages are retained with unique IDs", %{component: component} do
    component =
      Enum.reduce(1..101, component, fn id, acc ->
        ChatPanel.action(:send_message, %{event: %{"message" => "Message #{id}"}}, acc)
      end)

    document = document(component)
    assert document |> LazyHTML.query(".chat-message") |> Enum.count() == 100
    assert document |> LazyHTML.query("#chat-message-1") |> Enum.empty?()
    assert document |> LazyHTML.query("#chat-message-101") |> Enum.count() == 1
  end

  defp document(component) do
    {html, _registry, _server} =
      Renderer.render_dom(ChatPanel.template().(component.state), %Renderer.Env{}, %Server{})

    LazyHTML.from_fragment(html)
  end
end
