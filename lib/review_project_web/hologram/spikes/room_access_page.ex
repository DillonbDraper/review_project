if Application.compile_env(:review_project, :hologram_spikes, false) do
  defmodule ReviewProjectWeb.Hologram.Spikes.RoomAccessPage do
    @moduledoc "Authenticated ownership, named guests and automatic playback handoff spike."
    use Hologram.Page
    alias ReviewProjectWeb.Hologram.Spikes.{SpikeLayout, YouTubeSyncPage}
    route "/dev/spikes/room-access"
    layout SpikeLayout

    def init(params, component, server),
      do:
        YouTubeSyncPage.init(
          Map.merge(params, %{mesh: true, manual: true, access: true}),
          component,
          server
        )

    def template, do: YouTubeSyncPage.template()
    def action(name, params, component), do: YouTubeSyncPage.action(name, params, component)
    def command(name, params, server), do: YouTubeSyncPage.command(name, params, server)
  end
end
