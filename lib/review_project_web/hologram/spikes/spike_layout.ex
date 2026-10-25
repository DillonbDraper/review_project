if Application.compile_env(:review_project, :hologram_spikes, false) do
  defmodule ReviewProjectWeb.Hologram.Spikes.SpikeLayout do
    use Hologram.Component

    alias Hologram.UI.Runtime

    def template do
      ~HOLO"""
      <!DOCTYPE html>
      <html lang="en">
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <title>Hologram Interop Spike</title>
          <link rel="stylesheet" href="/assets/css/app.css" />
          <Runtime />
        </head>
        <body class="min-h-screen bg-slate-950 text-slate-100 antialiased">
          <slot />
        </body>
      </html>
      """
    end
  end
end
