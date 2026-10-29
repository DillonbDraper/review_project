defmodule ReviewProject.Rooms.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: ReviewProject.Rooms.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: ReviewProject.Rooms.SessionSupervisor}
    ]

    # Losing the registry must also stop its coordinators before new ones can start.
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
