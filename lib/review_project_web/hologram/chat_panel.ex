defmodule ReviewProjectWeb.Hologram.ChatPanel do
  @moduledoc "Shared room chat, rendered from acknowledged server messages."
  use Hologram.Component
  use Hologram.JS

  alias ReviewProjectWeb.Hologram.RoomUI

  js_import from: "../../../assets/js/room_browser.mjs", as: :Browser

  @impl Component
  def init(_props, component, _server) do
    put_state(component,
      draft: "",
      draft_length: 0,
      messages: [],
      connected: false,
      sending: false,
      uncertain: false,
      status: "Create or join a room to start the conversation.",
      delivery_status: "",
      error: "",
      room_id: "",
      self_id: nil,
      generation: 0,
      history_request: 0,
      send_request: 0
    )
  end

  @impl Component
  def template do
    # Native maxlength counts UTF-16 units; allow 1000 supplementary codepoints.
    ~HOLO"""
    <aside id="chat-panel" class="workspace-card chat-panel" aria-labelledby="chat-heading" data-connected={@connected}>
      <div class="panel-heading">
        <h2 id="chat-heading">Chat</h2>
      </div>

      <div class="chat-session-note"><span class="status-dot" aria-hidden="true"></span><span id="chat-status" role="status">{@status}</span></div>

      <div id="chat-messages" class="chat-messages" role="log" aria-label="Chat messages" aria-live="polite" aria-relevant="additions" tabindex="0">
        {%if @messages == []}
          <div id="chat-empty" class="chat-empty">
            <div class="conversation-art" aria-hidden="true"><span></span><span></span><span></span></div>
            <h3>Chat Space</h3>
            <span class="chat-empty-rule" aria-hidden="true"></span>
            <p class="chat-empty-caption">Talk about the video, or anything else.</p>
          </div>
        {/if}
        {%for message <- @messages}
          <article id="chat-message-{message.id}" class="chat-message" data-sequence={message.sequence} data-own={message.mine}>
            <span class="message-avatar" aria-hidden="true">{message.initial}</span>
            <div class="min-w-0">
              <div class="message-meta"><strong>{message.sender_display_name}</strong>{%if message.mine}<span>You</span>{/if}<time datetime={message.inserted_at}>{message.time}</time></div>
              <p>{message.body}</p>
            </div>
          </article>
        {/for}
      </div>

      <div class="chat-composer-area">
        <form id="chat-form" $submit="send_message">
          <label for="chat-draft" class="field-label">Your message</label>
          <div class="chat-composer">
            <textarea id="chat-draft" name="message" value={@draft} $input="update_draft" placeholder="What caught your attention?" rows="3" maxlength="2000" disabled={!@connected} aria-describedby="chat-draft-count chat-error" aria-invalid={if(@error != "", do: "true", else: "false")}></textarea>
            <div class="composer-bottom"><span id="chat-draft-count">{@draft_length} / 1000</span><button id="send-message" type="submit" class="primary-button" disabled={!@connected || @sending || @draft_length > 1000}>{%if @sending}Sending…{%else}Send message{/if}</button></div>
          </div>
          <p id="chat-delivery-status" role="status" class="field-hint">{@delivery_status}</p>
          <p id="chat-error" role="alert" class="field-error">{@error}</p>
        </form>
      </div>
    </aside>
    """
  end

  @impl Component
  def action(:update_draft, %{event: %{value: value}}, component) do
    put_state(component, draft: value, draft_length: length(String.to_charlist(value)))
  end

  def action(:reset, params, component) do
    component =
      deactivate(
        component,
        Map.get(params, :status, "Create or join a room to start the conversation.")
      )

    component =
      put_state(component,
        messages: [],
        error: "",
        delivery_status: ""
      )

    if params[:resume],
      do: put_action(component, name: :restore, target: "room-controls"),
      else: component
  end

  def action(:activate, params, component) do
    messages =
      params.messages
      |> Enum.map(&decorate(&1, params.self_id))
      |> merge([])

    uncertain = component.state.uncertain or params.uncertain

    component
    |> put_state(
      connected: true,
      sending: false,
      room_id: params.room_id,
      self_id: params.self_id,
      messages: messages,
      generation: component.state.generation + 1,
      uncertain: uncertain,
      status: "Connected",
      delivery_status: if(uncertain, do: "Delivery not confirmed", else: ""),
      error: if(uncertain, do: uncertain_text(), else: "")
    )
    |> show(true)
    |> put_action(
      name: :poll,
      target: "room-controls",
      params: %{generation: params.room_generation},
      delay: 15_000
    )
  end

  def action(:disconnected, params, component) do
    component = deactivate(component, params.status)

    if params[:retry],
      do:
        put_action(component,
          name: :retry,
          target: "room-controls",
          params: %{generation: params.generation},
          delay: 500
        ),
      else: component
  end

  def action(:received, %{message: message}, component) do
    if component.state.connected, do: receive_message(component, message), else: component
  end

  def action(:send_message, %{event: %{"message" => raw}}, component) do
    body = String.trim(raw)

    cond do
      component.state.sending ->
        component

      not component.state.connected ->
        put_state(component, error: "Join the room before sending messages.")

      body == "" ->
        put_state(component, error: "Write a message before sending.")

      length(String.to_charlist(body)) > 1000 ->
        put_state(component, error: "Keep your message to 1000 characters or fewer.")

      String.contains?(body, <<0>>) ->
        put_state(component, error: "Messages cannot contain null characters.")

      true ->
        request = component.state.send_request + 1
        # A reload can discard the acknowledgement without a disconnect action.
        # Persist the uncertainty before sending; clear it only on a known result.
        JS.call(:Browser, :save, [component.state.room_id, %{uncertain_delivery: true}])

        JS.call(:Browser, :push, [
          "chat_send",
          %{body: body},
          "chat-panel",
          "send_result",
          %{generation: component.state.generation, request: request, body: body}
        ])

        component
        |> put_state(
          sending: true,
          send_request: request,
          history_request: component.state.history_request + 1,
          uncertain: false,
          delivery_status: "Sending…",
          error: ""
        )
        |> show()
    end
  end

  def action(:send_result, params, component) do
    if params.generation != component.state.generation or
         params.request != component.state.send_request or not component.state.connected do
      component
    else
      case params.status do
        "ok" ->
          component = receive_message(component, params.result)

          component =
            if String.trim(component.state.draft) == params.body,
              do: put_state(component, draft: "", draft_length: 0),
              else: component

          JS.call(:Browser, :save, [component.state.room_id, %{uncertain_delivery: false}])

          component
          |> put_state(
            sending: false,
            uncertain: false,
            history_request: component.state.history_request + 1,
            error: "",
            delivery_status: "Sent"
          )
          |> show(true)

        "error" ->
          JS.call(:Browser, :save, [component.state.room_id, %{uncertain_delivery: false}])

          component
          |> put_state(
            sending: false,
            uncertain: false,
            delivery_status: "Not sent",
            error: RoomUI.chat_error(params.result)
          )
          |> show()

        "timeout" ->
          component |> unknown_delivery() |> refresh_history()
      end
    end
  end

  def action(:history_result, params, component) do
    if params.generation != component.state.generation or
         params.request != component.state.history_request or not component.state.connected do
      component
    else
      case params.status do
        "ok" ->
          position = position()
          messages = Enum.map(params.result, &decorate(&1, component.state.self_id))

          component
          |> put_state(
            messages: merge(messages, component.state.messages),
            delivery_status:
              "Conversation refreshed. Check whether your message arrived before sending it again."
          )
          |> show(position["bottom"], position)

        _ ->
          component
      end
    end
  end

  defp receive_message(component, raw) do
    position = position()
    message = decorate(raw, component.state.self_id)

    component
    |> put_state(messages: merge(component.state.messages, [message]))
    |> show(position["bottom"], position)
  end

  # A timeout can follow a committed insert. Refresh the conversation for review,
  # retaining the draft and warning; never replay the send automatically.
  defp refresh_history(component) do
    request = component.state.history_request + 1

    JS.call(:Browser, :push, [
      "chat_history",
      %{},
      "chat-panel",
      "history_result",
      %{generation: component.state.generation, request: request}
    ])

    put_state(component, history_request: request)
  end

  defp deactivate(component, status) do
    component = if component.state.sending, do: unknown_delivery(component), else: component

    put_state(component,
      generation: component.state.generation + 1,
      connected: false,
      sending: false,
      status: status
    )
  end

  defp unknown_delivery(component) do
    JS.call(:Browser, :save, [component.state.room_id, %{uncertain_delivery: true}])

    put_state(component,
      sending: false,
      uncertain: true,
      delivery_status: "Delivery not confirmed",
      error: uncertain_text()
    )
  end

  defp uncertain_text,
    do:
      "Your message may have been sent. Check the conversation before sending it again. Your draft is kept."

  defp show(component, bottom \\ false, position \\ nil) do
    JS.call(:Browser, :scroll, [position || position(), bottom])
    component
  end

  defp position do
    case JS.call(:Browser, :viewport, []) do
      value when is_map(value) -> value
      _ -> %{"bottom" => true, "id" => "", "offset" => 0}
    end
  end

  defp decorate(message, self_id) do
    time =
      case JS.call(:Browser, :time, [message.inserted_at]) do
        value when is_binary(value) -> value
        _ -> String.slice(message.inserted_at, 11, 5)
      end

    Map.merge(message, %{
      mine: message.sender_seat_id == self_id,
      initial: String.upcase(String.first(message.sender_display_name) || "?"),
      time: time
    })
  end

  defp merge(left, right),
    do: (left ++ right) |> Enum.uniq_by(& &1.id) |> Enum.sort_by(& &1.sequence)
end
