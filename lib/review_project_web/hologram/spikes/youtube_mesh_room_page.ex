if Application.compile_env(:review_project, :hologram_spikes, false) do
  defmodule ReviewProjectWeb.Hologram.Spikes.YouTubeMeshRoomPage do
    @moduledoc "Invitation route for the development-only local mesh harness."
    use Hologram.Page
    alias ReviewProjectWeb.Hologram.Spikes.{SpikeLayout, YouTubeSyncPage}
    route "/dev/spikes/youtube-mesh/room/:room"
    param :room, :string
    layout SpikeLayout

    def init(params, component, server),
      do: YouTubeSyncPage.init(Map.put(params, :mesh, true), component, server)

    def template, do: YouTubeSyncPage.template()
    def action(name, params, component), do: YouTubeSyncPage.action(name, params, component)
    def command(name, params, server), do: YouTubeSyncPage.command(name, params, server)
  end
end
