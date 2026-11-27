defmodule ReviewProjectWeb.RoomMediaController do
  use ReviewProjectWeb, :controller

  alias ReviewProject.Rooms
  alias ReviewProject.Rooms.Media
  alias ReviewProjectWeb.MediaRange

  @chunk_bytes 262_144

  def index(conn, %{"room_id" => room}) do
    with {:ok, _} <- authorize(conn, room, :media_access),
         {:ok, pid} <- media_pid(),
         staged when not is_tuple(staged) <- media_call(fn -> Media.staged(room, pid) end) do
      conn
      |> private_headers()
      |> json(%{staged: staged, max_file_bytes: max_bytes(), enabled: enabled?()})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def create(conn, %{"room_id" => room}) do
    with {:ok, authority} <- authorize(conn, room, :begin_upload),
         :ok <- content_type(conn, "application/octet-stream"),
         {:ok, name, size} <- upload_headers(conn),
         {:ok, pid} <- media_pid(),
         {:ok, asset} <- media_call(fn -> Media.reserve(room, name, size, pid) end) do
      # This request process owns the reservation. Every failed/aborted path frees it;
      # the service also monitors us if the transport terminates without unwinding.
      try do
        with {:ok, conn} <- receive_body(conn, room, asset.id, authority, pid),
             {:ok, ready} <- media_call(fn -> Media.finish(room, asset.id, pid) end),
             :ok <- same_authority(conn, room, authority) do
          conn |> private_headers() |> json(ready)
        else
          {:error, reason} ->
            media_call(fn -> Media.cancel(room, asset.id, pid) end)
            error(conn, reason)
        end
      catch
        kind, reason ->
          media_call(fn -> Media.cancel(room, asset.id, pid) end)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def delete(conn, %{"room_id" => room}) do
    with {:ok, _} <- authorize(conn, room, :can_upload),
         :ok <- content_type(conn, "application/json"),
         {:ok, body, conn} <-
           read_body(conn, length: 4_096, read_length: 4_096, read_timeout: 5_000),
         {:ok, params} when is_map(params) <- Jason.decode(body),
         {:ok, snapshot} <-
           authorize(conn, room, {:control, Map.put(params, "op", "discard_upload")}) do
      conn |> private_headers() |> json(%{snapshot: snapshot, staged: nil})
    else
      {:more, _, conn} -> error(conn, :too_large)
      {:error, reason} when is_atom(reason) -> error(conn, reason)
      _ -> error(conn, :invalid_request)
    end
  end

  def show(conn, %{"room_id" => room, "asset_id" => id}) do
    with {:ok, _} <- authorize(conn, room, :media_access),
         {:ok, pid} <- media_pid() do
      coordinator = Process.monitor(pid)

      try do
        case media_call(fn -> Media.acquire(room, id, pid) end) do
          {:ok, asset} ->
            try do
              stream(conn, asset, coordinator)
            after
              # stream closes the file before the lease can free the room slot.
              safe_release(room, id, pid)
            end

          {:error, reason} ->
            error(conn, reason)
        end
      after
        Process.demonitor(coordinator, [:flush])
      end
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp safe_release(room, id, pid) do
    Media.release(room, id, pid)
  catch
    :exit, _ -> :ok
  end

  defp media_pid do
    case Process.whereis(Media) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> {:error, :media_unavailable}
    end
  end

  defp media_call(fun) do
    fun.()
  catch
    :exit, _ -> {:error, :media_unavailable}
  end

  defp receive_body(conn, room, id, authority, pid) do
    with :ok <- same_authority(conn, room, authority) do
      case read_body(conn, length: @chunk_bytes, read_length: @chunk_bytes, read_timeout: 15_000) do
        {:more, bytes, conn} ->
          with :ok <- media_call(fn -> Media.append(room, id, bytes, pid) end),
               do: receive_body(conn, room, id, authority, pid)

        {:ok, bytes, conn} ->
          with :ok <- media_call(fn -> Media.append(room, id, bytes, pid) end), do: {:ok, conn}

        {:error, _} ->
          {:error, :upload_interrupted}
      end
    end
  end

  defp same_authority(conn, room, authority) do
    case authorize(conn, room, :can_upload) do
      {:ok, ^authority} -> :ok
      {:ok, _} -> {:error, :stale_authority}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stream(conn, asset, coordinator) do
    conn =
      conn
      |> private_headers()
      |> put_resp_header("content-type", asset.mime)
      |> put_resp_header("accept-ranges", "bytes")
      |> put_resp_header("x-content-type-options", "nosniff")

    case MediaRange.parse(get_req_header(conn, "range"), asset.size) do
      {:ok, status, first, length} ->
        conn = put_resp_header(conn, "content-length", Integer.to_string(length))

        conn =
          if status == 206,
            do:
              put_resp_header(
                conn,
                "content-range",
                "bytes #{first}-#{first + length - 1}/#{asset.size}"
              ),
            else: conn

        if conn.private[:room_media_head] do
          send_resp(conn, status, "")
        else
          case File.open(asset.path, [:read, :binary, :raw]) do
            {:ok, file} ->
              try do
                stream_chunks(send_chunked(conn, status), file, first, length, coordinator)
              after
                File.close(file)
              end

            _ ->
              error(conn, :unavailable)
          end
        end

      :error ->
        conn
        |> put_resp_header("content-range", "bytes */#{asset.size}")
        |> send_resp(416, "")
    end
  end

  defp stream_chunks(conn, _file, _offset, 0, _coordinator), do: conn

  defp stream_chunks(conn, file, offset, remaining, coordinator) do
    receive do
      # Do not return a successful length-delimited response after sending only
      # part of it: terminate the transport so HTTP/1 keepalive cannot desync.
      :media_retired -> exit(:shutdown)
      {:DOWN, ^coordinator, :process, _, _} -> exit(:shutdown)
    after
      0 ->
        case :file.pread(file, offset, min(remaining, @chunk_bytes)) do
          {:ok, bytes} ->
            case chunk(conn, bytes) do
              {:ok, conn} ->
                stream_chunks(
                  conn,
                  file,
                  offset + byte_size(bytes),
                  remaining - byte_size(bytes),
                  coordinator
                )

              {:error, _} ->
                conn
            end

          _ ->
            exit(:shutdown)
        end
    end
  end

  defp upload_headers(conn) do
    with [name] <- get_req_header(conn, "x-video-filename"),
         true <- byte_size(name) <= 2_400,
         name <- URI.decode(name),
         true <- String.valid?(name),
         [size] <- get_req_header(conn, "x-video-size"),
         {size, ""} when size > 0 <- Integer.parse(size) do
      if size <= max_bytes(), do: {:ok, name, size}, else: {:error, :too_large}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp content_type(conn, expected) do
    case get_req_header(conn, "content-type") do
      [value] ->
        if hd(String.split(value, ";")) == expected,
          do: :ok,
          else: {:error, :unsupported_media_type}

      _ ->
        {:error, :unsupported_media_type}
    end
  end

  defp authorize(conn, room, operation),
    do:
      Rooms.media_request(
        conn.assigns.current_scope,
        room,
        get_session(conn, :room_browser_identity),
        operation
      )

  defp max_bytes,
    do:
      Keyword.get(
        Application.get_env(:review_project, :uploaded_video, []),
        :max_file_bytes,
        1_073_741_824
      )

  defp enabled?,
    do: Keyword.get(Application.get_env(:review_project, :uploaded_video, []), :enabled, false)

  defp private_headers(conn), do: put_resp_header(conn, "cache-control", "private, no-store")

  defp error(conn, reason) do
    status =
      cond do
        reason in [:not_joined, :not_controller, :authentication_required] -> 403
        reason in [:not_found, :unavailable, :room_closed] -> 404
        reason in [:uploads_disabled, :media_unavailable] -> 503
        reason == :too_large -> 413
        reason == :unsupported_media_type -> 415
        reason in [:media_busy, :stale_authority, :stale_epoch, :stale_revision] -> 409
        reason in [:quota_exceeded, :too_many_uploads, :insufficient_disk] -> 503
        true -> 422
      end

    conn
    |> delete_resp_header("content-length")
    |> delete_resp_header("content-range")
    |> private_headers()
    |> put_status(status)
    |> json(%{error: reason})
  end
end
