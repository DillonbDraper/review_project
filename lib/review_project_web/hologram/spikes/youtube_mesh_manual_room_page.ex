if Application.compile_env(:review_project, :hologram_spikes, false) do
  defmodule ReviewProjectWeb.Hologram.Spikes.YouTubeMeshManualRoomPage do
    @moduledoc "LAN invitation route for the manual physical-device mesh test."
    use Hologram.Page
    alias ReviewProjectWeb.Hologram.Spikes.{SpikeLayout, YouTubeSyncPage}
    route "/dev/spikes/youtube-mesh-manual/room/:room"
    param :room, :string
    layout SpikeLayout

    def init(params, component, server),
      do: YouTubeSyncPage.init(Map.merge(params, %{mesh: true, manual: true}), component, server)

    def template, do: YouTubeSyncPage.template()
    def action(name, params, component), do: YouTubeSyncPage.action(name, params, component)
    def command(name, params, server), do: YouTubeSyncPage.command(name, params, server)
  end
end
