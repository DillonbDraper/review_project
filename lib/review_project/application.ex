defmodule ReviewProject.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ReviewProjectWeb.Telemetry,
      ReviewProject.Repo,
      {DNSCluster, query: Application.get_env(:review_project, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ReviewProject.PubSub},
      ReviewProject.Rooms.Supervisor,
      # Start a worker by calling: ReviewProject.Worker.start_link(arg)
      # {ReviewProject.Worker, arg},
      # Start to serve requests, typically the last entry
      ReviewProjectWeb.Endpoint
    ]

    # Phase 0 spike-only: pipeline session manager for the Hologram WebRTC spike.
    children =
      if Application.get_env(:review_project, :hologram_spikes, false) do
        children ++
          [
            ReviewProject.MediaSpikes.EchoSessions,
            ReviewProject.SyncSpikes.Rooms,
            ReviewProject.OwnershipSpikes.Rooms
          ]
      else
        children
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ReviewProject.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ReviewProjectWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
