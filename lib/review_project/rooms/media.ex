defmodule ReviewProject.Rooms.Media do
  @moduledoc "Node-local, ephemeral private media staging. The root must be exclusive to this service."
  use GenServer

  @defaults [
    max_file_bytes: 1_073_741_824,
    max_total_bytes: 1_073_741_824,
    max_uploads: 1,
    min_free_bytes: 1_073_741_824,
    probe_timeout_ms: 15_000,
    upload_timeout_ms: 120_000,
    sweep_interval_ms: 10_000,
    max_chunk_bytes: 1_048_576,
    free_check_bytes: 33_554_432,
    free_check_interval_ms: 1_000
  ]

  def start_link(opts \\ []) do
    opts = Keyword.merge(Application.get_env(:review_project, :uploaded_video, []), opts)
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def reserve(room, name, size, server \\ __MODULE__),
    do: GenServer.call(server, {:reserve, room, name, size})

  def append(room, id, bytes, server \\ __MODULE__),
    do: GenServer.call(server, {:append, room, id, bytes})

  def finish(room, id, server \\ __MODULE__),
    do: GenServer.call(server, {:finish, room, id}, :infinity)

  def cancel(room, id, server \\ __MODULE__), do: GenServer.call(server, {:cancel, room, id})
  def ready(room, id, server \\ __MODULE__), do: GenServer.call(server, {:ready, room, id})
  def staged(room, server \\ __MODULE__), do: GenServer.call(server, {:staged, room})
  def acquire(room, id, server \\ __MODULE__), do: GenServer.call(server, {:acquire, room, id})
  def release(room, id, server \\ __MODULE__), do: GenServer.call(server, {:release, room, id})
  def discard(room, server \\ __MODULE__), do: GenServer.call(server, {:discard, room})
  def sweep(server \\ __MODULE__), do: GenServer.call(server, :sweep)

  @impl true
  def init(opts) do
    opts = Keyword.merge(@defaults, opts)

    root =
      Keyword.get(opts, :root, Path.join(System.tmp_dir!(), "review-project-media"))
      |> Path.expand()

    # Reject symlinks in every existing component, not just the final directory.
    Enum.reduce(Path.split(root), "", fn part, parent ->
      path = if parent == "", do: part, else: Path.join(parent, part)

      case File.lstat(path) do
        {:ok, %{type: :directory}} -> :ok
        {:error, :enoent} -> :ok
        _ -> raise ArgumentError, "media root must contain only real directories"
      end

      path
    end)

    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    # Retained reader descriptors survive coordinator death. Never unlink those
    # or admit another reservation until they close (Linux, fail closed).
    cleanup_orphans(root, %{})

    state = %{
      opts: opts,
      root: root,
      files: %{},
      disk_space: nil,
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    }

    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_call({:reserve, room, name, size}, {pid, _}, s) do
    used = Enum.sum(Enum.map(s.files, fn {_, a} -> a.size end))
    uploads = Enum.count(s.files, fn {_, a} -> a.status in [:uploading, :validating] end)

    cond do
      not cleanup_orphans(s.root, s.files) ->
        {:reply, {:error, :media_busy}, s}

      Map.has_key?(s.files, room) ->
        {:reply, {:error, :media_busy}, s}

      not is_integer(size) or size <= 0 or size > s.opts[:max_file_bytes] ->
        {:reply, {:error, :too_large}, s}

      used + size > s.opts[:max_total_bytes] ->
        {:reply, {:error, :quota_exceeded}, s}

      uploads >= s.opts[:max_uploads] ->
        {:reply, {:error, :too_many_uploads}, s}

      true ->
        reserve_file(s, room, name, size, pid)
    end
  end

  def handle_call({:staged, room}, _, s),
    do: {:reply, if(s.files[room], do: public(s.files[room]), else: nil), s}

  def handle_call({:discard, room}, _, s) do
    s = retire(s, room)
    {:reply, if(s.files[room], do: {:error, :media_busy}, else: :ok), s}
  end

  def handle_call(:sweep, _, s), do: {:reply, :ok, expire(s)}

  def handle_call({action, room, id}, {pid, _} = from, s) do
    case s.files[room] do
      %{id: ^id} = a -> action(action, room, a, pid, from, s)
      _ -> {:reply, {:error, :not_found}, s}
    end
  end

  def handle_call({:append, room, id, bytes}, {pid, _}, s) do
    case s.files[room] do
      %{id: ^id, owner: ^pid, status: :uploading} = a when is_binary(bytes) ->
        cond do
          byte_size(bytes) > s.opts[:max_chunk_bytes] ->
            {:reply, {:error, :chunk_too_large}, s}

          a.received + byte_size(bytes) > a.size ->
            {:reply, {:error, :too_large}, retire(s, room)}

          true ->
            append_bytes(s, room, a, bytes)
        end

      %{id: ^id} ->
        {:reply, {:error, :not_owner_or_state}, s}

      _ ->
        {:reply, {:error, :not_found}, s}
    end
  end

  defp reserve_file(s, room, name, size, pid) do
    needed = size + Enum.sum(Enum.map(s.files, fn {_, a} -> a.size - a.received end))
    {enough?, s} = refresh_disk_space(s, needed)

    if enough? do
      id = Ecto.UUID.generate()
      path = Path.join(s.root, id <> ".stage")

      case File.open(path, [:write, :binary, :exclusive]) do
        {:ok, io} ->
          File.chmod!(path, 0o600)

          a = %{
            id: id,
            name: safe_name(name),
            size: size,
            received: 0,
            path: path,
            io: io,
            owner: pid,
            owner_ref: Process.monitor(pid),
            readers: %{},
            status: :uploading,
            touched: s.clock.(),
            probe: nil,
            pending: nil
          }

          {:reply, {:ok, public(a)}, put(s, room, a)}

        _ ->
          {:reply, {:error, :disk_error}, s}
      end
    else
      {:reply, {:error, :insufficient_disk}, s}
    end
  end

  defp append_bytes(s, room, a, bytes) do
    {enough?, s} = space_for_append(s, byte_size(bytes))

    if enough? do
      case IO.binwrite(a.io, bytes) do
        :ok ->
          space = %{
            s.disk_space
            | remaining: s.disk_space.remaining - byte_size(bytes),
              spent: s.disk_space.spent + byte_size(bytes)
          }

          {:reply, :ok,
           put(%{s | disk_space: space}, room, %{
             a
             | received: a.received + byte_size(bytes),
               touched: s.clock.()
           })}

        _ ->
          {:reply, {:error, :disk_error}, retire(s, room)}
      end
    else
      {:reply, {:error, :insufficient_disk}, retire(s, room)}
    end
  end

  defp action(:cancel, room, %{owner: pid}, pid, _, s), do: {:reply, :ok, retire(s, room)}

  defp action(:finish, room, %{owner: pid, status: :uploading} = a, pid, from, s) do
    if a.received == a.size do
      {enough?, s} = refresh_disk_space(s, 0)

      if enough? do
        File.close(a.io)
        parent = self()
        probe = Keyword.get(s.opts, :probe, &ReviewProject.Rooms.MediaProbe.probe/1)

        {worker, ref} =
          spawn_monitor(fn -> send(parent, {:probed, room, a.id, probe.(a.path)}) end)

        timer =
          Process.send_after(self(), {:probe_timeout, room, a.id}, s.opts[:probe_timeout_ms])

        {:noreply,
         put(s, room, %{
           a
           | io: nil,
             status: :validating,
             probe: {worker, ref, timer},
             pending: from
         })}
      else
        {:reply, {:error, :insufficient_disk}, retire(s, room)}
      end
    else
      {:reply, {:error, :size_mismatch}, retire(s, room)}
    end
  end

  defp action(:ready, room, %{status: :ready} = a, _, _, s) do
    if available?(a),
      do: {:reply, {:ok, public(a)}, s},
      else: {:reply, {:error, :unavailable}, retire(s, room)}
  end

  defp action(:acquire, room, %{status: :ready} = a, pid, _, s) do
    if Map.has_key?(a.readers, pid) do
      {:reply, {:error, :already_acquired}, s}
    else
      case available?(a) do
        true ->
          {:reply, {:ok, Map.put(public(a), :path, a.path)},
           put(s, room, %{a | readers: Map.put(a.readers, pid, Process.monitor(pid))})}

        _ ->
          {:reply, {:error, :unavailable}, retire(s, room)}
      end
    end
  end

  defp action(:release, room, a, pid, _, s) do
    {ref, readers} = Map.pop(a.readers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    s = put(s, room, %{a | readers: readers})
    {:reply, :ok, if(a.status == :retiring, do: retire(s, room), else: s)}
  end

  defp action(_, _, _, _, _, s), do: {:reply, {:error, :not_owner_or_state}, s}

  @impl true
  def handle_info({:probed, room, id, result}, s) do
    case s.files[room] do
      %{id: ^id, status: :validating} = a ->
        stop_probe(a)

        result = if Process.info(a.owner) == nil, do: {:error, :owner_gone}, else: result

        case result do
          {:ok, %{mime: mime, duration: duration}}
          when mime in ["video/mp4", "video/webm"] and is_number(duration) and duration > 0 ->
            Process.demonitor(a.owner_ref, [:flush])

            a =
              Map.merge(a, %{
                status: :ready,
                mime: mime,
                duration: duration,
                probe: nil,
                pending: nil,
                owner_ref: nil
              })

            GenServer.reply(s.files[room].pending, {:ok, public(a)})
            {:noreply, put(s, room, a)}

          _ ->
            {:noreply, retire(s, room)}
        end

      _ ->
        {:noreply, s}
    end
  end

  def handle_info({:probe_timeout, room, id}, s) do
    case s.files[room] do
      %{id: ^id, status: :validating} -> {:noreply, retire(s, room)}
      _ -> {:noreply, s}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, _}, s) do
    s =
      Enum.reduce(s.files, s, fn {room, a}, acc ->
        cond do
          a.owner_ref == ref ->
            retire(acc, room)

          a.probe != nil and elem(a.probe, 1) == ref ->
            retire(acc, room)

          a.readers[pid] == ref ->
            acc = put(acc, room, %{a | readers: Map.delete(a.readers, pid)})
            if a.status == :retiring, do: retire(acc, room), else: acc

          true ->
            acc
        end
      end)

    {:noreply, s}
  end

  def handle_info(:sweep, s) do
    schedule(s)
    {:noreply, expire(s)}
  end

  defp retire(s, room) do
    case s.files[room] do
      nil ->
        s

      a ->
        if a.io, do: File.close(a.io)
        stop_probe(a)
        if a.pending, do: GenServer.reply(a.pending, {:error, :validation_failed})
        if a.owner_ref, do: Process.demonitor(a.owner_ref, [:flush])
        Enum.each(a.readers, fn {pid, _} -> send(pid, :media_retired) end)
        a = %{a | status: :retiring, io: nil, probe: nil, pending: nil, owner_ref: nil}

        if map_size(a.readers) == 0 and File.rm(a.path) in [:ok, {:error, :enoent}] do
          %{s | files: Map.delete(s.files, room)}
        else
          put(s, room, a)
        end
    end
  end

  defp stop_probe(%{probe: nil}), do: :ok

  defp stop_probe(%{probe: {pid, ref, timer}}) do
    Process.cancel_timer(timer)
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
  end

  defp expire(s),
    do:
      Enum.reduce(s.files, s, fn {room, a}, acc ->
        if a.status == :retiring or
             (a.status in [:uploading, :validating] and
                s.clock.() - a.touched >= s.opts[:upload_timeout_ms]),
           do: retire(acc, room),
           else: acc
      end)

  defp schedule(s), do: Process.send_after(self(), :sweep, s.opts[:sweep_interval_ms])
  defp put(s, room, a), do: %{s | files: Map.put(s.files, room, a)}
  defp public(a), do: Map.take(a, [:id, :name, :size, :status, :mime, :duration])

  defp safe_name(name) when is_binary(name) do
    name =
      if(String.valid?(name), do: name, else: "video")
      |> String.replace("\\", "/")
      |> Path.basename()
      |> String.replace(~r/[\x00-\x1f\x7f]/u, "")
      |> String.slice(0, 200)

    if name in ["", ".", ".."], do: "video", else: name
  end

  defp safe_name(_), do: "video"

  defp available?(a) do
    case File.lstat(a.path) do
      {:ok, %{type: :regular, size: size}} -> size == a.size
      _ -> false
    end
  end

  # HTTP readers must monitor the coordinator before acquire and close before
  # release. /proc is a restart fence, including descriptors to unlinked files.
  # The exclusive root must not be shared with another OS process or node.
  defp cleanup_orphans(root, files) do
    with {:ok, descriptors} <- File.ls("/proc/self/fd"),
         {:ok, entries} <- File.ls(root) do
      known = MapSet.new(Enum.map(files, fn {_, a} -> a.path end))

      open =
        Enum.flat_map(descriptors, fn fd ->
          case File.read_link("/proc/self/fd/" <> fd) do
            {:ok, path} -> [String.replace_suffix(path, " (deleted)", "")]
            _ -> []
          end
        end)
        |> MapSet.new()

      orphans =
        entries
        |> Enum.filter(&String.ends_with?(&1, ".stage"))
        |> Enum.map(&Path.join(root, &1))
        |> Enum.reject(&MapSet.member?(known, &1))

      removed =
        Enum.map(orphans, fn path ->
          not MapSet.member?(open, path) and File.rm(path) in [:ok, {:error, :enoent}]
        end)

      # Re-scan after unlink: a pre-restart acquire may have opened between
      # the first descriptor snapshot and unlink. Once unlinked no new open
      # through that stale path can succeed.
      Enum.all?(removed) and no_orphan_descriptors?(root, known)
    else
      _ -> false
    end
  end

  defp no_orphan_descriptors?(root, known) do
    case File.ls("/proc/self/fd") do
      {:ok, descriptors} ->
        Enum.all?(descriptors, fn fd ->
          case File.read_link("/proc/self/fd/" <> fd) do
            {:ok, path} ->
              path = String.replace_suffix(path, " (deleted)", "")
              not String.starts_with?(path, root <> "/") or MapSet.member?(known, path)

            {:error, :enoent} ->
              true

            _ ->
              false
          end
        end)

      _ ->
        false
    end
  end

  defp space_for_append(s, needed) do
    space = s.disk_space

    # Account for every written byte between fresh filesystem observations.
    # Bound both bytes and age so unrelated disk use is noticed during uploads.
    if space == nil or s.clock.() - space.checked_at >= s.opts[:free_check_interval_ms] or
         space.spent + needed > s.opts[:free_check_bytes] or
         space.remaining < s.opts[:min_free_bytes] + needed do
      refresh_disk_space(s, needed)
    else
      {true, s}
    end
  end

  defp refresh_disk_space(s, needed) do
    check = Keyword.get(s.opts, :free_bytes, &__MODULE__.free_bytes/1)

    case check.(s.root) do
      {:ok, bytes} when is_integer(bytes) and bytes >= 0 ->
        space = %{remaining: bytes, spent: 0, checked_at: s.clock.()}
        {bytes >= s.opts[:min_free_bytes] + needed, %{s | disk_space: space}}

      _ ->
        {false, %{s | disk_space: nil}}
    end
  end

  @doc false
  def free_bytes(root) do
    case System.cmd("df", ["-Pk", root], stderr_to_stdout: true) do
      {output, 0} ->
        with [_, line | _] <- String.split(output, "\n", trim: true),
             [_, _, _, available | _] <- String.split(line),
             {bytes, ""} <- Integer.parse(available),
             do: {:ok, bytes * 1024},
             else: (_ -> {:error, :disk_unknown})

      _ ->
        {:error, :disk_unknown}
    end
  rescue
    _ -> {:error, :disk_unknown}
  end
end
