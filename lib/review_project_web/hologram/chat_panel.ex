defmodule ReviewProjectWeb.Hologram.ChatPanel do
  @moduledoc "Browser-local chat scaffold. Messages reset on reload and are not broadcast or persisted."
  use Hologram.Component
  use Hologram.JS

  js_import :scrollChatToLatest, from: "../../../assets/js/workspace.js"

  @impl Component
  def init(_props, component, _server) do
    put_state(component, draft: "", messages: [], next_id: 1, error: nil)
  end

  @impl Component
  def template do
    ~HOLO"""
    <aside id="chat-panel" class="workspace-card chat-panel" aria-labelledby="chat-heading">
      <div class="panel-heading">
        <div class="flex items-center gap-3">
          <span class="section-number">02</span>
          <h2 id="chat-heading">The conversation</h2>
        </div>
        <span class="chat-count" aria-label="Message count">{length(@messages)}</span>
      </div>

      <div class="chat-session-note"><span class="status-dot" aria-hidden="true"></span>Just you, for now <span>LOCAL CHAT</span></div>

      <div id="chat-messages" class="chat-messages" role="log" aria-label="Chat messages" aria-live="polite" aria-relevant="additions" tabindex="0">
        {%if @messages == []}
          <div id="chat-empty" class="chat-empty">
            <div class="conversation-art" aria-hidden="true"><span></span><span></span><span></span></div>
            <h3>Start with a thought.</h3>
            <p>A question, an observation, a moment worth coming back to. Keep it here.</p>
            <span class="chat-empty-rule" aria-hidden="true"></span>
            <p class="chat-empty-caption">Every good review starts somewhere.</p>
          </div>
        {/if}
        {%for message <- @messages}
          <article id="chat-message-{message.id}" class="chat-message">
            <span class="message-avatar" aria-hidden="true">Y</span>
            <div class="min-w-0">
              <div class="message-meta"><strong>You</strong><span>Only on this device</span></div>
              <p>{message.body}</p>
            </div>
          </article>
        {/for}
      </div>

      <div class="chat-composer-area">
        <form id="chat-form" $submit="send_message">
          <label for="chat-draft" class="field-label">Your message</label>
          <div class="chat-composer">
            <textarea id="chat-draft" name="message" value={@draft} $change="update_draft" placeholder="What caught your attention?" rows="3" maxlength="1000" aria-describedby="chat-help chat-error" aria-invalid={if(@error, do: "true", else: "false")}></textarea>
            <div class="composer-bottom"><span>{String.length(@draft)} / 1000</span><button id="send-message" type="submit" class="primary-button">Send message</button></div>
          </div>
          <p id="chat-error" role="status" class="field-error">{@error}</p>
          <p id="chat-help" class="field-hint">Messages stay in this tab and reset on reload. The latest 100 messages are kept.</p>
        </form>
      </div>
    </aside>
    """
  end

  @impl Component
  def action(:update_draft, %{event: %{value: value}}, component) do
    put_state(component, draft: value, error: nil)
  end

  def action(:send_message, %{event: %{"message" => body}}, component) do
    body = String.trim(body)

    cond do
      body == "" ->
        put_state(component, :error, "Write a message before sending.")

      String.length(body) > 1000 ->
        put_state(component, :error, "Keep your message to 1000 characters or fewer.")

      true ->
        message = %{id: component.state.next_id, body: body}
        messages = Enum.take(component.state.messages ++ [message], -100)

        JS.call(:scrollChatToLatest, [])

        put_state(component,
          messages: messages,
          next_id: component.state.next_id + 1,
          draft: "",
          error: nil
        )
    end
  end
end
