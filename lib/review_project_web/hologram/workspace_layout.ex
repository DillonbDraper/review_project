defmodule ReviewProjectWeb.Hologram.WorkspaceLayout do
  @moduledoc "The Hologram document layout for the video workspace."
  use Hologram.Component

  alias ReviewProjectWeb.Hologram.FlashGroup

  @impl Component
  def template do
    ~HOLO"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="description" content="A focused workspace for watching videos, collecting thoughts, and making room for ideas." />
        <meta name="referrer" content="strict-origin-when-cross-origin" />
        <title>Video workspace · Review</title>
        <link rel="stylesheet" href={asset_path("assets/css/app.css")} />
        <Hologram.UI.Runtime />
      </head>
      <body class="review-workspace">
        <a href="#workspace" class="skip-link">Skip to workspace</a>
        <FlashGroup cid="flash-group" />
        <slot />
      </body>
    </html>
    """
  end
end
