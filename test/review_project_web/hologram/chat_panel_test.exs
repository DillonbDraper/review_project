defmodule ReviewProjectWeb.Hologram.ChatPanelTest do
  use ExUnit.Case, async: true

  alias Hologram.{Component, Server}
  alias Hologram.Template.Renderer
  alias ReviewProjectWeb.Hologram.ChatPanel

  setup do
    %{component: ChatPanel.init(%{}, %Component{}, %Server{})}
  end

  test "the composer is disabled until membership is connected", %{component: component} do
    assert count(component, "#chat-draft[disabled]") == 1
    assert count(component, "#send-message[disabled]") == 1
    assert count(activate(component), "#send-message[disabled]") == 0
  end

  test "acknowledgement and broadcast produce one message and clear only the sent draft", %{
    component: component
  } do
    component =
      component |> activate() |> draft(" A good moment ") |> send_message(" A good moment ")

    assert component.state.sending
    assert send_message(component, "Duplicate").state.send_request == 1
    component = ChatPanel.action(:received, %{message: message(1, "A good moment")}, component)
    component = send_result(component, "ok", message(1, "A good moment"), "A good moment")
    component = ChatPanel.action(:received, %{message: message(1)}, component)
    assert Enum.map(component.state.messages, & &1.id) == ["message-1"]
    assert hd(component.state.messages).mine
    assert component.state.draft == ""
    refute component.state.sending

    pending = component |> draft("First") |> send_message("First") |> draft("Next thought")
    assert send_result(pending, "ok", message(2), "First").state.draft == "Next thought"
  end

  test "disconnect disables sending, retains drafts and records uncertain delivery", %{
    component: component
  } do
    component = component |> activate() |> draft("Unconfirmed") |> send_message("Unconfirmed")
    component = ChatPanel.action(:disconnected, %{status: "Reconnecting"}, component)
    assert component.state.draft == "Unconfirmed"
    assert component.state.uncertain
    assert count(component, "#chat-draft[disabled]") == 1
    assert activate(component).state.uncertain
  end

  test "validation counts codepoints and requires membership", %{component: component} do
    assert send_message(component, "Hello").state.error =~ "Join"
    component = component |> activate() |> draft("😀é")
    assert component.state.draft_length == 3

    assert document(component) |> LazyHTML.query("#chat-draft-count") |> LazyHTML.text() ==
             "3 / 1000"

    for invalid <- [" ", String.duplicate("x", 1001), "bad" <> <<0>>] do
      refute send_message(component, invalid).state.sending
    end

    assert send_message(component, String.duplicate("😀", 1000)).state.sending

    at_limit = draft(component, String.duplicate("😀", 1000))
    assert count(at_limit, "#send-message[disabled]") == 0
    above_limit = draft(component, String.duplicate("😀", 1001))
    assert count(above_limit, "#send-message[disabled]") == 1
    rejected = send_message(above_limit, above_limit.state.draft)
    assert rejected.state.error == "Keep your message to 1000 characters or fewer."
    assert rejected.state.draft == above_limit.state.draft
  end

  test "timeouts refresh the full conversation without replaying the send or clearing the draft",
       %{
         component: component
       } do
    component =
      component |> activate() |> draft("Maybe accepted") |> send_message("Maybe accepted")

    component = send_result(component, "timeout", %{}, "Maybe accepted")
    assert component.state.uncertain
    assert component.state.draft == "Maybe accepted"
    refute component.state.sending
    assert component.state.send_request == 1
    component = history_result(component, [message(1, "Maybe accepted")])
    assert component.state.uncertain
    assert component.state.delivery_status =~ "Conversation refreshed"
    assert component.state.draft == "Maybe accepted"
    assert component.state.send_request == 1
  end

  test "a rejected send explains validation without clearing the draft", %{component: component} do
    component = component |> activate() |> draft("Hello") |> send_message("Hello")

    component =
      send_result(
        component,
        "error",
        %{reason: "validation", errors: %{body: ["is too long"]}},
        "Hello"
      )

    assert component.state.error =~ "Message is too long"
    assert component.state.delivery_status == "Not sent"
    assert component.state.draft == "Hello"
  end

  test "old membership and send callbacks cannot acknowledge a newer draft", %{
    component: component
  } do
    pending = component |> activate() |> draft("First") |> send_message("First")
    stale = result_params(pending, "ok", message(1), "First")

    next =
      pending |> send_result("timeout", %{}, "First") |> draft("Second") |> send_message("Second")

    assert ChatPanel.action(:send_result, stale, next).state.sending
    next = ChatPanel.action(:send_result, stale, next)
    assert next.state.draft == "Second"
    assert send_result(next, "ok", message(2), "Second").state.draft == ""
  end

  test "rejoining refreshes history and ignores old acknowledgements", %{component: component} do
    pending =
      component |> activate([message(1)]) |> draft("Unconfirmed") |> send_message("Unconfirmed")

    stale = result_params(pending, "ok", message(4), "Unconfirmed")

    next =
      ChatPanel.action(:disconnected, %{status: "Reconnecting"}, pending)
      |> activate([message(2), message(3)])

    next = ChatPanel.action(:send_result, stale, next)
    assert Enum.map(next.state.messages, & &1.sequence) == [2, 3]
    assert next.state.draft == "Unconfirmed"
  end

  test "the full conversation stays visible beyond the old display limit", %{component: component} do
    component = activate(component, messages(1..300))
    assert length(component.state.messages) == 300
    assert count(component, "#chat-message-message-1") == 1
    assert count(component, "#chat-message-message-300") == 1
    assert count(component, "#chat-history-controls, #chat-load-older, #chat-load-latest") == 0

    component = ChatPanel.action(:received, %{message: message(301)}, component)
    assert Enum.map(component.state.messages, & &1.sequence) == Enum.to_list(1..301)
  end

  test "an old refresh cannot change a later acknowledged send", %{component: component} do
    component =
      component
      |> activate(messages(1..300))
      |> send_message("Maybe")
      |> send_result("timeout", %{}, "Maybe")

    stale = history_params(component, messages(1..300))

    component =
      component |> send_message("New thought") |> send_result("ok", message(301), "New thought")

    component = ChatPanel.action(:history_result, stale, component)
    assert length(component.state.messages) == 301
    assert component.state.delivery_status == "Sent"
  end

  test "a refresh retains broadcasts that arrived after its database snapshot", %{
    component: component
  } do
    component =
      component
      |> activate(messages(1..300))
      |> send_message("Maybe")
      |> send_result("timeout", %{}, "Maybe")

    component = ChatPanel.action(:received, %{message: message(301)}, component)
    component = history_result(component, messages(1..300))
    assert Enum.map(component.state.messages, & &1.sequence) == Enum.to_list(1..301)
  end

  test "a broadcast already in history appears only once", %{component: component} do
    component = activate(component, messages(1..300))
    component = ChatPanel.action(:received, %{message: message(300)}, component)
    assert length(component.state.messages) == 300
  end

  test "server bodies and names render as plain text", %{component: component} do
    message = %{
      message(1, "<script>alert('test')</script>")
      | sender_display_name: "<b>Guest</b>"
    }

    document = component |> activate([message]) |> document()

    assert document |> LazyHTML.query("#chat-message-message-1 p") |> LazyHTML.text() ==
             message.body

    assert document |> LazyHTML.query("#chat-message-message-1 strong") |> LazyHTML.text() ==
             message.sender_display_name

    assert document |> LazyHTML.query("#chat-messages script, #chat-messages b") |> Enum.empty?()
  end

  defp activate(component, messages \\ []) do
    ChatPanel.action(
      :activate,
      %{
        messages: messages,
        self_id: "self",
        room_id: "room",
        uncertain: false,
        room_generation: 1
      },
      component
    )
  end

  defp draft(component, value),
    do: ChatPanel.action(:update_draft, %{event: %{value: value}}, component)

  defp send_message(component, body),
    do: ChatPanel.action(:send_message, %{event: %{"message" => body}}, component)

  defp result_params(component, status, result, body),
    do: %{
      generation: component.state.generation,
      request: component.state.send_request,
      status: status,
      result: result,
      body: body
    }

  defp send_result(component, status, result, body),
    do: ChatPanel.action(:send_result, result_params(component, status, result, body), component)

  defp history_params(component, messages),
    do: %{
      generation: component.state.generation,
      request: component.state.history_request,
      status: "ok",
      result: messages
    }

  defp history_result(component, messages),
    do: ChatPanel.action(:history_result, history_params(component, messages), component)

  defp messages(range), do: Enum.map(range, &message/1)

  defp message(sequence, body \\ "Message"),
    do: %{
      id: "message-#{sequence}",
      sequence: sequence,
      body: body,
      sender_display_name: "Alex",
      sender_seat_id: "self",
      inserted_at: "2026-10-29T12:00:00Z"
    }

  defp count(component, selector),
    do: document(component) |> LazyHTML.query(selector) |> Enum.count()

  defp document(component) do
    {html, _registry, _server} =
      Renderer.render_dom(ChatPanel.template().(component.state), %Renderer.Env{}, %Server{})

    LazyHTML.from_fragment(html)
  end
end
