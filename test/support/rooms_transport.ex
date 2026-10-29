defmodule ReviewProject.RoomsTransport do
  @moduledoc false
  use GenServer

  def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
  @impl true
  def init(parent), do: {:ok, parent}
  @impl true
  def handle_info(event, parent) do
    send(parent, {self(), event})
    {:noreply, parent}
  end
end
