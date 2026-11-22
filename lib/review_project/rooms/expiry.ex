defmodule ReviewProject.Rooms.Expiry do
  @moduledoc "Periodically closes rooms whose persisted abandonment deadline has passed."
  use GenServer
  require Logger

  def start_link(opts) do
    if Keyword.get(opts, :enabled, true) do
      name = Keyword.get(opts, :name, __MODULE__)
      GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
    else
      :ignore
    end
  end

  @doc false
  def sweep(server), do: GenServer.call(server, :sweep)

  @impl true
  def init(opts) do
    state = %{
      interval: Keyword.get(opts, :interval, :timer.minutes(1)),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0)
    }

    {:ok, state, {:continue, :sweep}}
  end

  @impl true
  def handle_continue(:sweep, state) do
    sweep_rooms(state)
    schedule(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep_rooms(state)
    schedule(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:sweep, _from, state), do: {:reply, sweep_rooms(state), state}

  defp sweep_rooms(state) do
    {:ok, ReviewProject.Rooms.expire_abandoned_rooms(state.clock.())}
  rescue
    error ->
      Logger.error("Room expiry sweep failed: #{Exception.message(error)}")
      {:error, :sweep_failed}
  end

  defp schedule(%{interval: :infinity}), do: :ok
  defp schedule(state), do: Process.send_after(self(), :sweep, state.interval)
end
