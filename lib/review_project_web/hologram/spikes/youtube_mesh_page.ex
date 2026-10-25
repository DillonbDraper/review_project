if Application.compile_env(:review_project, :hologram_spikes, false) do
  defmodule ReviewProjectWeb.Hologram.Spikes.YouTubeMeshPage do
    @moduledoc "Development-only local five-person mesh harness (spike 3A)."
    use Hologram.Page
    alias ReviewProjectWeb.Hologram.Spikes.{SpikeLayout, YouTubeSyncPage}
    route "/dev/spikes/youtube-mesh"
    layout SpikeLayout

    def init(params, component, server),
      do: YouTubeSyncPage.init(Map.put(params, :mesh, true), component, server)

    def template, do: YouTubeSyncPage.template()
    def action(name, params, component), do: YouTubeSyncPage.action(name, params, component)
    def command(name, params, server), do: YouTubeSyncPage.command(name, params, server)
  end
end
