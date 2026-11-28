defmodule ReviewProjectWeb.ReplayController do
  use ReviewProjectWeb, :controller
  alias ReviewProject.{Rooms, Slippi}
  alias ReviewProject.Replays.Storage

  # Raw body deliberately bypasses multipart spooling; admission precedes reads.
  def create(conn, %{"room_id" => room_id}) do
    guards = %{
      "selection" => header(conn, "x-replay-selection"),
      "epoch" => header(conn, "x-room-epoch"),
      "revision" => integer(header(conn, "x-room-revision")),
      "authority_revision" => integer(header(conn, "x-room-authority")),
      "connection_generation" => integer(header(conn, "x-seat-generation"))
    }

    size = integer(header(conn, "x-replay-size"))
    name = header(conn, "x-replay-name") |> URI.decode()

    with :ok <- validate(size, name, header(conn, "content-type")),
         {:ok, %{coordinator: coordinator}} <- request(conn, room_id, {:replay_authorize, guards}),
         {:ok, reservation} <-
           Storage.reserve(room_id, size, coordinator, selection: guards["selection"]) do
      try do
        result =
          with {:ok, conn} <- receive_file(conn, reservation.path, room_id, guards, size),
               {:ok, metadata} <- validate_file(reservation),
               source =
                 Map.merge(metadata, %{
                   id: Ecto.UUID.generate(),
                   kind: "slippi_replay",
                   name: name,
                   size: size
                 }),
               {:ok, snapshot} <-
                 request(conn, room_id, {:replay_commit, guards, source, reservation.token}) do
            {:ok, conn, snapshot}
          end

        case result do
          {:ok, conn, snapshot} -> json(conn, snapshot)
          {:error, reason} -> failure(conn, reason)
        end
      after
        Storage.release(reservation.token)
      end
    else
      {:error, reason} -> failure(conn, reason)
    end
  end

  def show(conn, %{"room_id" => room_id, "id" => id}) do
    case request(conn, room_id, {:replay_read, id}) do
      {:ok, path} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_content_type("application/octet-stream")
        |> deliver(path)

      _ ->
        send_resp(conn, 404, "Replay unavailable")
    end
  end

  defp deliver(conn, path) do
    send_file(conn, 200, path)
  rescue
    # Replacement can delete a file between admission and opening it. Avoid
    # logging a private path for this expected delivery race.
    File.Error -> send_resp(conn, 404, "Replay unavailable")
  end

  defp validate_file(reservation) do
    task =
      Task.Supervisor.async(ReviewProject.Replays.Tasks, fn ->
        Slippi.inspect_file(reservation.path)
      end)

    receive do
      {ref, result} when ref == task.ref ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ref, :process, _, _} when ref == task.ref ->
        {:error, :invalid_replay}

      {:replay_cancelled, token} when token == reservation.token ->
        Task.shutdown(task, :brutal_kill)
        {:error, :stale_selection}
    after
      30_000 ->
        Task.shutdown(task, :brutal_kill)
        {:error, :invalid_replay}
    end
  end

  defp validate(size, name, content_type) do
    if content_type == "application/octet-stream" and is_integer(size) and size > 0 and
         size <= 9_007_199_254_740_991 and
         String.valid?(name) and byte_size(name) in 1..1024 and
         Regex.match?(~r/\A[^\x00-\x1F\x7F]+\z/u, name) and
         String.ends_with?(String.downcase(name), ".slp"),
       do: :ok,
       else: {:error, :invalid_replay}
  end

  defp receive_file(conn, path, room, guards, size) do
    case File.open(path, [:write, :binary]) do
      {:ok, file} ->
        try do
          receive_body(conn, file, room, guards, size)
        after
          File.close(file)
        end

      _ ->
        {:error, :storage_unavailable}
    end
  end

  defp receive_body(conn, file, room, guards, remaining) do
    with {:ok, _} <- request(conn, room, {:replay_authorize, guards}) do
      case read_body(conn,
             length: min(262_144, remaining + 1),
             read_length: 262_144,
             read_timeout: 15_000
           ) do
        {:ok, bytes, conn} when byte_size(bytes) == remaining ->
          with :ok <- write(file, bytes), do: {:ok, conn}

        {:more, bytes, conn} when byte_size(bytes) <= remaining ->
          with :ok <- write(file, bytes),
               do: receive_body(conn, file, room, guards, remaining - byte_size(bytes))

        _ ->
          {:error, :invalid_replay}
      end
    end
  end

  defp write(file, bytes) do
    case IO.binwrite(file, bytes) do
      :ok -> :ok
      _ -> {:error, :storage_unavailable}
    end
  end

  defp failure(conn, reason) do
    {status, code, message} =
      case reason do
        :invalid_replay ->
          {422, "invalid_replay",
           "Choose a complete .slp replay with supported stage and player data."}

        :busy ->
          {503, "busy", "Replay uploads are busy. Try again shortly."}

        :disk_full ->
          {507, "disk_full", "Replay storage has insufficient free space. Try again later."}

        :storage_unavailable ->
          {503, "storage_failure", "Replay storage is unavailable. Try again later."}

        reason
        when reason in [
               :stale_epoch,
               :stale_authority,
               :stale_revision,
               :stale_connection,
               :stale_selection
             ] ->
          {409, "stale_selection", "Playback changed during selection. Choose the replay again."}

        _ ->
          {403, "not_authorized",
           "Join as the current playback controller before uploading a replay."}
      end

    :telemetry.execute([:review_project, :replay, :upload_failure], %{count: 1}, %{reason: code})
    conn |> put_status(status) |> json(%{code: code, reason: message})
  end

  defp request(conn, room_id, operation),
    do:
      Rooms.replay_request(
        conn.assigns.current_scope,
        room_id,
        get_session(conn, :room_browser_identity),
        {header(conn, "x-replay-grant"), operation}
      )

  defp header(conn, name), do: List.first(get_req_header(conn, name)) || ""

  defp integer(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end
end
