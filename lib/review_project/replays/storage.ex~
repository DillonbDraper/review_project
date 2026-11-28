defmodule ReviewProject.Replays.Storage do
  @moduledoc "Private, ephemeral replay reservations. Loss of this process restarts room coordinators."
  use GenServer

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def reserve(room, bytes, coordinator, opts \\ [], server \\ __MODULE__),
    do: call(server, {:reserve, room, bytes, coordinator, opts})

  def accept(token, server \\ __MODULE__), do: call(server, {:accept, token})
  def release(token, server \\ __MODULE__), do: call(server, {:release, token})
  def cancel(room, selection), do: call(__MODULE__, {:cancel, room, selection})

  def stats(server \\ __MODULE__), do: call(server, :stats)

  @impl true
  def init(opts) do
    opts = Keyword.merge(Application.get_env(:review_project, :replay_storage, []), opts)

    directory =
      Keyword.get(opts, :directory, Path.join(System.tmp_dir!(), "review-project-replays"))

    # This dedicated directory contains only application-owned ephemeral files.
    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- clean(directory) do
      Process.send_after(self(), :sweep, 30_000)

      {:ok,
       %{
         directory: directory,
         entries: %{},
         max_node: Keyword.get(opts, :max_node, 2),
         max_room: Keyword.get(opts, :max_room, 1),
         headroom: Keyword.get(opts, :headroom, 1_073_741_824),
         free_bytes: Keyword.get(opts, :free_bytes, &free_bytes/1)
       }}
    else
      _ -> {:stop, :storage_unavailable}
    end
  end

  @impl true
  def handle_call({:reserve, room, bytes, coordinator, opts}, {owner, _}, state)
      when is_integer(bytes) and bytes > 0 and is_pid(coordinator) do
    pending = Enum.filter(Map.values(state.entries), &(&1.status == :staged))
    reserved = Enum.reduce(pending, 0, &(&1.bytes + &2))

    result =
      cond do
        length(pending) >= state.max_node ->
          {:error, :busy}

        Enum.count(pending, &(&1.room == room)) >= state.max_room ->
          {:error, :busy}

        true ->
          case state.free_bytes.(state.directory) do
            {:ok, free} when free - reserved - bytes >= state.headroom -> :ok
            {:ok, _} -> {:error, :disk_full}
            _ -> {:error, :storage_unavailable}
          end
      end

    case result do
      :ok ->
        token = Ecto.UUID.generate()
        path = Path.join(state.directory, token <> ".slp")

        case File.open(path, [:write, :binary, :exclusive]) do
          {:ok, file} ->
            File.close(file)

            case File.chmod(path, 0o600) do
              :ok ->
                entry = %{
                  path: path,
                  room: room,
                  bytes: bytes,
                  owner: owner,
                  coordinator: coordinator,
                  status: :staged,
                  selection: Keyword.get(opts, :selection),
                  monitors: [Process.monitor(owner), Process.monitor(coordinator)]
                }

                state = %{state | entries: Map.put(state.entries, token, entry)}
                measure(state)
                {:reply, {:ok, %{token: token, path: path}}, state}

              _ ->
                File.rm(path)
                {:reply, {:error, :storage_unavailable}, state}
            end

          _ ->
            {:reply, {:error, :storage_unavailable}, state}
        end

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:accept, token}, {caller, _}, state) do
    case state.entries[token] do
      %{coordinator: ^caller, status: :staged} = entry ->
        case File.stat(entry.path) do
          {:ok, %{size: size}} when size == entry.bytes ->
            Enum.each(entry.monitors, &Process.demonitor(&1, [:flush]))

            entry = %{
              entry
              | status: :accepted,
                owner: caller,
                monitors: [Process.monitor(caller)]
            }

            state = %{state | entries: Map.put(state.entries, token, entry)}
            measure(state)
            {:reply, {:ok, entry.path}, state}

          _ ->
            {:reply, {:error, :storage_unavailable}, state}
        end

      _ ->
        {:reply, {:error, :stale_selection}, state}
    end
  end

  def handle_call({:release, token}, {caller, _}, state) do
    case state.entries[token] do
      %{status: :accepted, coordinator: coordinator} when coordinator != caller ->
        # A cancelled HTTP request must never delete a published replay.
        {:reply, :ok, state}

      %{owner: owner, coordinator: coordinator} when caller == owner or caller == coordinator ->
        {:reply, :ok, remove(state, token)}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:cancel, room, selection}, {caller, _}, state) do
    state =
      Enum.reduce(state.entries, state, fn {token, entry}, state ->
        if entry.room == room and entry.selection == selection and entry.coordinator == caller and
             entry.status == :staged do
          send(entry.owner, {:replay_cancelled, token})
          remove(state, token)
        else
          state
        end
      end)

    {:reply, :ok, state}
  end

  def handle_call(:stats, _from, state), do: {:reply, measurements(state), state}

  @impl true
  def handle_info(:sweep, state) do
    active = MapSet.new(Enum.map(state.entries, fn {_, entry} -> entry.path end))

    case File.ls(state.directory) do
      {:ok, files} ->
        for name <- files,
            path = Path.join(state.directory, name),
            not MapSet.member?(active, path) do
          case File.rm(path) do
            :ok ->
              :ok

            {:error, :enoent} ->
              :ok

            _ ->
              :telemetry.execute([:review_project, :replay, :cleanup_failure], %{count: 1}, %{})
          end
        end

      _ ->
        :telemetry.execute([:review_project, :replay, :cleanup_failure], %{count: 1}, %{})
    end

    measure(state)
    Process.send_after(self(), :sweep, 30_000)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    state =
      Enum.reduce(state.entries, state, fn {token, entry}, acc ->
        if ref in entry.monitors, do: remove(acc, token), else: acc
      end)

    {:noreply, state}
  end

  defp remove(state, token) do
    {entry, entries} = Map.pop(state.entries, token)
    Enum.each(entry.monitors, &Process.demonitor(&1, [:flush]))

    case File.rm(entry.path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, _} ->
        :telemetry.execute([:review_project, :replay, :cleanup_failure], %{count: 1}, %{})
    end

    state = %{state | entries: entries}
    measure(state)
    state
  end

  defp measurements(state),
    do: %{
      active_transfers: Enum.count(state.entries, fn {_, e} -> e.status == :staged end),
      reserved_bytes: Enum.reduce(state.entries, 0, fn {_, e}, n -> n + e.bytes end),
      stored_bytes:
        Enum.reduce(state.entries, 0, fn {_, e}, n ->
          case File.stat(e.path) do
            {:ok, %{size: bytes}} -> n + bytes
            _ -> n
          end
        end)
    }

  defp measure(state),
    do: :telemetry.execute([:review_project, :replay, :storage], measurements(state), %{})

  defp clean(directory) do
    Enum.reduce_while(File.ls!(directory), :ok, fn name, :ok ->
      case File.rm(Path.join(directory, name)) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # A storage restart must return a service error rather than crashing an HTTP
  # request or logging a coordinator state containing private paths. The room
  # supervisor invalidates dependent coordinators before storage reinitializes.
  defp call(server, message) do
    # Publication transfers ownership atomically; a caller timeout must not
    # abandon an accepted reservation whose reply is merely delayed.
    GenServer.call(server, message, :infinity)
  catch
    :exit, _ -> {:error, :storage_unavailable}
  end

  defp free_bytes(directory) do
    case System.cmd("df", ["-Pk", directory], stderr_to_stdout: true) do
      {output, 0} ->
        case output |> String.split("\n", trim: true) |> List.last() |> String.split() do
          [_, _, _, available | _] -> {:ok, String.to_integer(available) * 1024}
          _ -> {:error, :storage_unavailable}
        end

      _ ->
        {:error, :storage_unavailable}
    end
  rescue
    _ -> {:error, :storage_unavailable}
  end
end
