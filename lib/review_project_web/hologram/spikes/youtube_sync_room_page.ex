if Application.compile_env(:review_project, :hologram_spikes, false) do
  defmodule ReviewProjectWeb.Hologram.Spikes.YouTubeSyncRoomPage do
    @moduledoc "Room invitation route for the development-only synchronization experiment."
    use Hologram.Page

    alias ReviewProjectWeb.Hologram.Spikes.{SpikeLayout, YouTubeSyncPage}

    route "/dev/spikes/youtube-sync/room/:room"
    param :room, :string
    layout SpikeLayout

    def init(params, component, server), do: YouTubeSyncPage.init(params, component, server)
    def template, do: YouTubeSyncPage.template()
    def action(name, params, component), do: YouTubeSyncPage.action(name, params, component)
    def command(name, params, server), do: YouTubeSyncPage.command(name, params, server)
  end
end
