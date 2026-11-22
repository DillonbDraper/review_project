defmodule ReviewProjectWeb.Hologram.WatchPage do
  @moduledoc "Video review workspace with conferencing, playback, and chat."
  use Hologram.Page

  alias ReviewProjectWeb.Hologram.{
    AccountMenu,
    ChatPanel,
    ConferencePanel,
    RoomPanel,
    UserAuth,
    VideoPanel,
    WorkspaceLayout
  }

  route "/"
  layout WorkspaceLayout

  middleware UserAuth, :mount_current_scope

  @impl Page
  def init(_params, component, _server), do: put_state(component, room_id: "")

  @impl Page
  def template do
    ~HOLO"""
    <header class="workspace-header">
      <div class="workspace-shell flex items-center justify-between gap-4">
          <span class="brand-mark" aria-hidden="true">r</span>
        <div class="workspace-header-actions">
          <AccountMenu cid="account-menu" />
        </div>
      </div>
    </header>

    <main id="workspace" class="workspace-shell">
      <RoomPanel cid="room-controls" room_id={@room_id} />

      <div class="workspace-grid">
        <ConferencePanel cid="conference-panel" />
        <VideoPanel cid="video-panel" room_id={@room_id} />
        <ChatPanel cid="chat-panel" />
      </div>

      <footer class="workspace-footer">
      </footer>
    </main>
    """
  end
end
