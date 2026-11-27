defmodule ReviewProjectWeb.RoomMediaTransportTest do
  use ReviewProjectWeb.ConnCase, async: false
  @moduletag :capture_log

  import ReviewProject.RoomsFixtures
  alias ReviewProject.Rooms.{Media, Session}

  setup do
    fixture = room_fixture()
    identity = browser_identity()
    transport = start_supervised!({ReviewProject.RoomsTransport, self()})

    session =
      start_supervised!({Session, room_id: fixture.room.id, maintenance_interval: :infinity})

    {:ok, _} = Session.join(session, nil, identity, fixture.invitation_token, "Guest", transport)

    old_probe = :sys.get_state(Media).opts[:probe]

    :sys.replace_state(Media, fn s ->
      %{
        s
        | opts:
            Keyword.put(s.opts, :probe, fn _ -> {:ok, %{mime: "video/mp4", duration: 10.0}} end)
      }
    end)

    on_exit(fn ->
      Media.discard(fixture.room.id)

      :sys.replace_state(Media, fn s ->
        %{
          s
          | opts:
              if(old_probe,
                do: Keyword.put(s.opts, :probe, old_probe),
                else: Keyword.delete(s.opts, :probe)
              )
        }
      end)
    end)

    # Produce the same signed cookie consumed by the endpoint, not a ConnTest session.
    options =
      Plug.Session.init(store: :cookie, key: "_review_project_key", signing_salt: "tUuLBbjG")

    conn = %{build_conn() | secret_key_base: @endpoint.config(:secret_key_base)}

    conn =
      conn
      |> Plug.Session.call(options)
      |> fetch_session()
      |> put_session(:room_browser_identity, identity)
      |> send_resp(200, "")

    cookie = "_review_project_key=" <> conn.resp_cookies["_review_project_key"].value

    server = start_supervised!({Bandit, plug: @endpoint, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    {:ok, room: fixture.room, cookie: cookie, port: port}
  end

  test "signed private HTTP GET, HEAD and byte ranges retain length-delimited semantics", ctx do
    id = ready(ctx, "0123456789")
    url = "http://127.0.0.1:#{ctx.port}/room-media/#{ctx.room.id}/#{id}"

    request = fn method, headers ->
      Req.request!(
        url: url,
        method: method,
        headers: [{"cookie", ctx.cookie} | headers],
        retry: false
      )
    end

    assert Req.get!(url, retry: false).status == 403

    assert Req.get!(url, headers: [{"cookie", ctx.cookie <> "tampered"}], retry: false).status ==
             403

    full = request.(:get, [])
    assert full.status == 200
    assert full.body == "0123456789"
    assert full.headers["content-length"] == ["10"]
    assert full.headers["cache-control"] == ["private, no-store"]
    assert full.headers["content-type"] == ["video/mp4"]
    refute Map.has_key?(full.headers, "transfer-encoding")

    head = request.(:head, [])
    assert head.status == 200
    assert head.body == ""
    assert head.headers["content-length"] == ["10"]

    for {range, body, content_range} <- [
          {"bytes=2-5", "2345", "bytes 2-5/10"},
          {"bytes=-3", "789", "bytes 7-9/10"}
        ] do
      response = request.(:get, [{"range", range}])
      assert response.status == 206
      assert response.body == body
      assert response.headers["content-length"] == [Integer.to_string(byte_size(body))]
      assert response.headers["content-range"] == [content_range]
    end

    unsatisfied = request.(:get, [{"range", "bytes=10-"}])
    assert unsatisfied.status == 416
    assert unsatisfied.body == ""
    assert unsatisfied.headers["content-range"] == ["bytes */10"]
    assert unsatisfied.headers["content-length"] == ["0"]
  end

  for cause <- [:retirement, :coordinator_death] do
    test "#{cause} after partial delivery closes the real HTTP transport", ctx do
      id = ready(ctx, "v")
      # Sparse bytes exceed transport buffering without allocating a large fixture.
      size = 64 * 1024 * 1024
      asset = :sys.get_state(Media).files[ctx.room.id]
      {:ok, file} = :file.open(String.to_charlist(asset.path), [:read, :write, :binary, :raw])
      :ok = :file.pwrite(file, size - 1, <<0>>)
      :ok = :file.close(file)
      :sys.replace_state(Media, fn s -> put_in(s, [:files, ctx.room.id, :size], size) end)

      {:ok, socket} =
        :gen_tcp.connect({127, 0, 0, 1}, ctx.port, [:binary, active: false, recbuf: 4096], 5_000)

      on_exit(fn -> :gen_tcp.close(socket) end)
      path = "/room-media/#{ctx.room.id}/#{id}"

      :ok =
        :gen_tcp.send(
          socket,
          "GET #{path} HTTP/1.1\r\nHost: localhost\r\nCookie: #{ctx.cookie}\r\n\r\n"
        )

      {headers, initial} = receive_headers(socket, "")
      assert headers =~ "HTTP/1.1 200"
      assert String.downcase(headers) =~ "content-length: #{size}"
      {:ok, first} = :gen_tcp.recv(socket, 1, 5_000)
      assert byte_size(initial <> first) > 0

      coordinator = Process.whereis(Media)
      [reader] = Map.keys(:sys.get_state(coordinator).files[ctx.room.id].readers)
      monitor = Process.monitor(reader)
      # Freeze the backpressured request before delivering the lifecycle event.
      :erlang.suspend_process(reader)

      try do
        case unquote(cause) do
          :retirement ->
            assert {:error, :media_busy} = Media.discard(ctx.room.id)

          :coordinator_death ->
            ref = Process.monitor(coordinator)
            Process.exit(coordinator, :kill)
            assert_receive {:DOWN, ^ref, :process, ^coordinator, :killed}, 5_000
        end
      after
        :erlang.resume_process(reader)
      end

      # A pipelined next request must not become a successful keepalive response.
      _ =
        :gen_tcp.send(
          socket,
          "HEAD #{path} HTTP/1.1\r\nHost: localhost\r\nCookie: #{ctx.cookie}\r\n\r\n"
        )

      {received, extra_response?} = drain(socket, byte_size(initial <> first), false)
      assert received < size
      refute extra_response?
      assert_receive {:DOWN, ^monitor, :process, ^reader, _}, 5_000
      if unquote(cause) == :retirement, do: assert(Media.staged(ctx.room.id) == nil)
    end
  end

  defp ready(ctx, bytes) do
    {:ok, asset} = Media.reserve(ctx.room.id, "clip.mp4", byte_size(bytes))
    :ok = Media.append(ctx.room.id, asset.id, bytes)
    {:ok, _} = Media.finish(ctx.room.id, asset.id)
    asset.id
  end

  defp receive_headers(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [headers, body] ->
        {headers, body}

      [_] ->
        {:ok, bytes} = :gen_tcp.recv(socket, 0, 5_000)
        receive_headers(socket, acc <> bytes)
    end
  end

  defp drain(socket, count, extra?) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, bytes} ->
        drain(
          socket,
          count + byte_size(bytes),
          extra? or :binary.match(bytes, "HTTP/1.1") != :nomatch
        )

      {:error, reason} when reason in [:closed, :econnreset] ->
        {count, extra?}

      other ->
        flunk("expected aborted transport, got #{inspect(other)}")
    end
  end
end
