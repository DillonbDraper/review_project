defmodule ReviewProject.UUIDCompat.MixProject do
  use Mix.Project

  def project do
    [
      app: :uuid,
      version: "1.1.8",
      elixir: "~> 1.19",
      deps: [{:elixir_uuid, "~> 1.2"}]
    ]
  end

  def application, do: []
end
