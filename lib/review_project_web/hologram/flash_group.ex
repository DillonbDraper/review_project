defmodule ReviewProjectWeb.Hologram.FlashGroup do
  @moduledoc """
  Shows Phoenix flash messages on Hologram pages.

  Phoenix controllers keep the flash in the session when they redirect, such as
  after log in and log out, which land on the watch page. Hologram pages don't
  run Phoenix's flash plug, so this component shows the info and error messages
  once and clears them, rather than leaving them for the next Phoenix page.
  """
  use Hologram.Component

  @impl Component
  def init(_props, component, server) do
    flash = get_session(server, "phoenix_flash", %{})

    messages =
      for {kind, role} <- [{"info", "status"}, {"error", "alert"}], is_binary(flash[kind]) do
        %{kind: kind, role: role, text: flash[kind]}
      end

    {put_state(component, :messages, messages), delete_session(server, "phoenix_flash")}
  end

  @impl Component
  def template do
    ~HOLO"""
    <div id="flash-group" class="workspace-flash-group" aria-live="polite">
      {%for message <- @messages}
        <div id="flash-{message.kind}" class="workspace-flash workspace-flash-{message.kind}" role={message.role}>
          <p>{message.text}</p>
          <button type="button" class="workspace-flash-close" $click={:dismiss, kind: message.kind} aria-label="Close">
            <span class="hero-x-mark size-4" aria-hidden="true"></span>
          </button>
        </div>
      {/for}
    </div>
    """
  end

  @impl Component
  def action(:dismiss, %{kind: kind}, component) do
    put_state(component, :messages, Enum.reject(component.state.messages, &(&1.kind == kind)))
  end
end
