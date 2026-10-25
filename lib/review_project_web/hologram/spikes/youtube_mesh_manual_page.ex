if Application.compile_env(:review_project, :hologram_spikes, false) do
  defmodule ReviewProjectWeb.Hologram.Spikes.YouTubeMeshManualPage do
    @moduledoc "Development-only physical-device mesh test (spike 3B)."
    use Hologram.Page
    alias ReviewProjectWeb.Hologram.Spikes.{SpikeLayout, YouTubeSyncPage}
    route "/dev/spikes/youtube-mesh-manual"
    layout SpikeLayout

    def init(params, component, server),
      do: YouTubeSyncPage.init(Map.merge(params, %{mesh: true, manual: true}), component, server)

    def template, do: YouTubeSyncPage.template()
    def action(name, params, component), do: YouTubeSyncPage.action(name, params, component)
    def command(name, params, server), do: YouTubeSyncPage.command(name, params, server)
  end
end
