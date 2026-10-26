defmodule ReviewProjectWeb.Hologram.WatchPage do
  @moduledoc "Video review scaffold with independently owned player, chat, and whiteboard."
  use Hologram.Page

  alias ReviewProjectWeb.Hologram.{
    AccountMenu,
    ChatPanel,
    UserAuth,
    VideoPanel,
    WhiteboardPanel,
    WorkspaceLayout
  }

  route "/"
  layout WorkspaceLayout

  middleware UserAuth, :mount_current_scope

  @impl Page
  def template do
    ~HOLO"""
    <header class="workspace-header">
      <div class="workspace-shell flex items-center justify-between gap-4">
        <a id="workspace-home" href="/" class="wordmark" aria-label="Review workspace home">
          <span class="brand-mark" aria-hidden="true">r.</span>
          review<span class="wordmark-divider" aria-hidden="true"></span><span class="wordmark-label">Workspace</span>
        </a>
        <div class="workspace-header-actions">
          <span class="session-badge"><span class="status-dot" aria-hidden="true"></span>Local session</span>
          <AccountMenu cid="account-menu" />
        </div>
      </div>
    </header>

    <main id="workspace" class="workspace-shell">
      <div class="workspace-intro">
        <div>
          <p class="eyebrow">A SPACE TO LOOK CLOSER</p>
          <h1>Watch. Discuss. Make room for ideas.</h1>
          <p class="intro-description">Bring a video, collect your thoughts, and keep the conversation in view.</p>
        </div>
        <span class="workspace-label">YOUR REVIEW ROOM <span aria-hidden="true">01</span></span>
      </div>

      <div class="workspace-grid">
        <VideoPanel cid="video-panel" />
        <ChatPanel cid="chat-panel" />
        <WhiteboardPanel />
      </div>

      <footer class="workspace-footer">
        <span>A little focus goes a long way.</span>
        <span>Video + conversation + a space to think</span>
      </footer>
    </main>
    """
  end
end
