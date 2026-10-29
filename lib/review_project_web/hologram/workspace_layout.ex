defmodule ReviewProjectWeb.Hologram.WorkspaceLayout do
  @moduledoc "The Hologram document layout for the video workspace."
  use Hologram.Component

  alias ReviewProjectWeb.Hologram.{FlashGroup, UserAuth}

  @impl Component
  def init(_props, component, server) do
    # Follow Phoenix's manifest configuration instead of Hologram's preference
    # for any fingerprinted file left in priv/static by a production build.
    stylesheet_path = ReviewProjectWeb.Endpoint.static_path("/assets/css/app.css")
    script_path = ReviewProjectWeb.Endpoint.static_path("/assets/js/app.js")
    {csrf_token, server} = UserAuth.csrf_token(server)

    {put_state(component,
       stylesheet_path: stylesheet_path,
       script_path: script_path,
       csrf_token: csrf_token
     ), server}
  end

  @impl Component
  def template do
    ~HOLO"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <meta name="description" content="A focused workspace for watching videos, collecting thoughts, and making room for ideas." />
        <meta name="referrer" content="strict-origin-when-cross-origin" />
        <title>Video workspace · Review</title>
        <link rel="stylesheet" href={@stylesheet_path} />
        <script defer src={@script_path}></script>
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
