defmodule ReviewProjectWeb.ReplayControllerTest do
  use ReviewProjectWeb.ConnCase, async: false
  import ReviewProject.RoomsFixtures
  alias ReviewProject.Rooms
  alias ReviewProject.Rooms.Session

  setup %{conn: conn} do
    fixture = room_fixture()
    clock = start_supervised!({Agent, fn -> 0 end})

    start_supervised!(
      {Session,
       room_id: fixture.room.id,
       clock: fn -> Agent.get(clock, & &1) end,
       maintenance_interval: 60_000}
    )

    host = start_supervised!({ReviewProject.RoomsTransport, self()}, id: :replay_host)
    guest = start_supervised!({ReviewProject.RoomsTransport, self()}, id: :replay_guest)
    identity = browser_identity()

    {:ok, joined} =
      Rooms.join_room(fixture.scope, fixture.room.id, browser_identity(), nil, "Host", host)

    {:ok, _} =
      Rooms.join_room(nil, fixture.room.id, identity, fixture.invitation_token, "Guest", guest)

    {:ok, %{grant: host_grant}} =
      Rooms.request(fixture.scope, fixture.room.id, :replay_grant, host)

    {:ok, %{grant: guest_grant}} = Rooms.request(nil, fixture.room.id, :replay_grant, guest)
    conn = log_in_user(conn, fixture.scope.user)

    guards =
      Map.take(joined.snapshot, [:epoch, :revision, :authority_revision])
      |> Map.put(:connection_generation, joined.connection_generation)

    Map.merge(fixture, %{
      conn: conn,
      host_grant: host_grant,
      guest_grant: guest_grant,
      host: host,
      guest: guest,
      identity: identity,
      guards: guards,
      clock: clock
    })
  end

  test "private upload selects a paused replay; admitted guests can read; replacement deletes bytes",
       ctx do
    body = fixture("unranked_game1")
    response = upload(ctx.conn, ctx, body)
    snapshot = json_response(response, 200)
    assert snapshot["playing"] == false
    assert snapshot["position"] == 0
    assert snapshot["video_source"]["kind"] == "slippi_replay"
    refute Map.has_key?(snapshot["video_source"], "path")
    id = snapshot["video_source"]["id"]

    guest_conn =
      build_conn()
      |> init_test_session(%{room_browser_identity: ctx.identity})
      |> put_req_header("x-replay-grant", ctx.guest_grant)

    path = "/rooms/#{ctx.room.id}/replay/#{id}"
    assert response(build_conn() |> get(path), 404)
    assert response(guest_conn |> get(path), 200) == body

    assert {:ok, disk_path} =
             Rooms.replay_request(
               nil,
               ctx.room.id,
               ctx.identity,
               {ctx.guest_grant, {:replay_read, id}}
             )

    assert File.exists?(disk_path)
    # The replay survives supplier departure and can be fetched again on reload.
    assert {:ok, _} = Rooms.request(ctx.scope, ctx.room.id, :leave, ctx.host)
    assert response(guest_conn |> get(path), 200) == body

    assert {:ok, rejoined} =
             Rooms.join_room(ctx.scope, ctx.room.id, browser_identity(), nil, "Host", ctx.host)

    command =
      Map.take(rejoined.snapshot, [:epoch, :revision, :authority_revision])
      |> Map.put(:op, "video")
      |> Map.put(:video_id, "M7lc1UVf-VE")
      |> stringify()

    assert {:ok, _} = Rooms.request(ctx.scope, ctx.room.id, {:control, command}, ctx.host)
    refute File.exists?(disk_path)
    assert response(guest_conn |> get(path), 404)
  end

  test "followers, stale connections and stale authority cannot upload", ctx do
    guest = build_conn() |> init_test_session(%{room_browser_identity: ctx.identity})
    assert json_response(upload(guest, ctx, fixture("unranked_game1")), 403)
    stale = %{ctx | guards: Map.put(ctx.guards, :connection_generation, -1)}
    assert json_response(upload(ctx.conn, stale, fixture("unranked_game1")), 409)
    stale = %{ctx | guards: Map.put(ctx.guards, :authority_revision, -1)}
    assert json_response(upload(ctx.conn, stale, fixture("unranked_game1")), 409)
  end

  test "corrupt and incomplete files preserve the previous source", ctx do
    {:ok, snapshot} =
      Rooms.request(
        ctx.scope,
        ctx.room.id,
        {:control,
         Map.merge(stringify(ctx.guards), %{"op" => "video", "video_id" => "M7lc1UVf-VE"})},
        ctx.host
      )

    ctx = %{
      ctx
      | guards:
          Map.merge(ctx.guards, Map.take(snapshot, [:epoch, :revision, :authority_revision]))
    }

    for body <- ["not a replay", fixture("incomplete")] do
      assert json_response(upload(ctx.conn, ctx, body), 422)

      assert {:ok, %{video_id: "M7lc1UVf-VE"}} =
               Rooms.request(ctx.scope, ctx.room.id, :snapshot, ctx.host)
    end
  end

  test "Fountain of Dreams and doubles uploads pass structural validation", ctx do
    for name <- ["FodPlatforms", "doubles"] do
      {:ok, snapshot} = Rooms.request(ctx.scope, ctx.room.id, :snapshot, ctx.host)

      ctx = %{
        ctx
        | guards:
            Map.merge(ctx.guards, Map.take(snapshot, [:epoch, :revision, :authority_revision]))
      }

      assert json_response(upload(ctx.conn, ctx, fixture(name)), 200)["video_source"]["frames"] >
               0
    end
  end

  test "guest controller can upload after handoff and coordinator cleanup removes the replay",
       ctx do
    assert {:ok, _} = Rooms.request(ctx.scope, ctx.room.id, :leave, ctx.host)
    Agent.update(ctx.clock, fn _ -> 10_001 end)
    assert {:ok, snapshot} = Session.maintain(Session.via(ctx.room.id))
    guest = Enum.find(snapshot.seats, &(&1.role == :guest))

    guards =
      Map.take(snapshot, [:epoch, :revision, :authority_revision])
      |> Map.put(:connection_generation, guest.connection_generation)

    conn =
      build_conn()
      |> init_test_session(%{room_browser_identity: ctx.identity})
      |> put_req_header("x-replay-grant", ctx.guest_grant)

    response = upload(conn, %{ctx | guards: guards}, fixture("unranked_game1"))
    id = json_response(response, 200)["video_source"]["id"]

    assert {:ok, path} =
             Rooms.replay_request(
               nil,
               ctx.room.id,
               ctx.identity,
               {ctx.guest_grant, {:replay_read, id}}
             )

    assert File.exists?(path)
    stop_supervised!(Session)
    refute File.exists?(path)
  end

  test "grants are bound to a joined connection", ctx do
    body = fixture("unranked_game1")

    assert json_response(
             upload(put_req_header(ctx.conn, "x-replay-grant", "invalid"), ctx, body),
             403
           )

    replacement = start_supervised!({ReviewProject.RoomsTransport, self()}, id: :replacement)

    {:ok, _} =
      Rooms.join_room(ctx.scope, ctx.room.id, browser_identity(), nil, "Host", replacement)

    assert json_response(upload(ctx.conn, ctx, body), 403)
  end

  test "advertised size mismatch leaves storage clean", ctx do
    selection = start_selection(ctx.conn, ctx)

    conn =
      ctx.conn
      |> put_req_header("x-replay-grant", ctx.host_grant)
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("x-replay-name", "match.slp")
      |> put_req_header("x-replay-selection", selection)
      |> put_req_header("x-replay-size", "2")
      |> put_req_header("x-room-epoch", ctx.guards.epoch)
      |> put_req_header("x-room-revision", to_string(ctx.guards.revision))
      |> put_req_header("x-room-authority", to_string(ctx.guards.authority_revision))
      |> put_req_header("x-seat-generation", to_string(ctx.guards.connection_generation))

    assert json_response(post(conn, "/rooms/#{ctx.room.id}/replay", "too long"), 422)
    assert ReviewProject.Replays.Storage.stats().active_transfers == 0
  end

  test "idle retention ignores polling", ctx do
    snapshot = upload(ctx.conn, ctx, fixture("unranked_game1")) |> json_response(200)
    id = snapshot["video_source"]["id"]

    {:ok, path} =
      Rooms.replay_request(nil, ctx.room.id, ctx.identity, {ctx.guest_grant, {:replay_read, id}})

    Agent.update(ctx.clock, fn _ -> 3_600_001 end)
    assert {:ok, %{video_id: nil}} = Rooms.request(ctx.scope, ctx.room.id, :snapshot, ctx.host)
    refute File.exists?(path)
  end

  test "cancelling a staged selection removes bytes and makes late publication stale", ctx do
    selection = start_selection(ctx.conn, ctx)
    guards = stringify(Map.put(ctx.guards, :selection, selection))

    {:ok, %{coordinator: coordinator}} =
      Rooms.replay_request(
        ctx.scope,
        ctx.room.id,
        nil,
        {ctx.host_grant, {:replay_authorize, guards}}
      )

    {:ok, reservation} =
      ReviewProject.Replays.Storage.reserve(ctx.room.id, 4, coordinator, selection: selection)

    File.write!(reservation.path, "data")

    {:ok, _} =
      Rooms.request(
        ctx.scope,
        ctx.room.id,
        {:replay_cancel, %{"selection" => selection}},
        ctx.host
      )

    assert_receive {:replay_cancelled, token}
    assert token == reservation.token
    refute File.exists?(reservation.path)

    assert {:error, :stale_selection} =
             Rooms.replay_request(
               ctx.scope,
               ctx.room.id,
               nil,
               {ctx.host_grant, {:replay_commit, guards, %{}, reservation.token}}
             )

    assert {:ok, %{video_id: nil}} = Rooms.request(ctx.scope, ctx.room.id, :snapshot, ctx.host)
  end

  test "accepted cancellation reconciles to published replay and empty retention deletes it",
       ctx do
    snapshot = upload(ctx.conn, ctx, fixture("unranked_game1")) |> json_response(200)

    {:ok, path} =
      Rooms.replay_request(
        nil,
        ctx.room.id,
        ctx.identity,
        {ctx.guest_grant, {:replay_read, snapshot["video_source"]["id"]}}
      )

    {:ok, reconciled} =
      Rooms.request(
        ctx.scope,
        ctx.room.id,
        {:replay_cancel, %{"selection" => Ecto.UUID.generate()}},
        ctx.host
      )

    assert reconciled.video_id == snapshot["video_id"]
    assert File.exists?(path)
    {:ok, _} = Rooms.request(ctx.scope, ctx.room.id, :leave, ctx.host)
    {:ok, _} = Rooms.request(nil, ctx.room.id, :leave, ctx.guest)
    Agent.update(ctx.clock, fn _ -> 300_001 end)
    assert {:ok, %{video_id: nil}} = Session.maintain(Session.via(ctx.room.id))
    refute File.exists?(path)
  end

  test "replaced guest admission revokes its HTTP grant", ctx do
    snapshot = upload(ctx.conn, ctx, fixture("unranked_game1")) |> json_response(200)

    replacement =
      start_supervised!({ReviewProject.RoomsTransport, self()}, id: :guest_replacement)

    {:ok, _} =
      Rooms.join_room(nil, ctx.room.id, ctx.identity, ctx.invitation_token, "Guest", replacement)

    assert {:error, :not_joined} =
             Rooms.replay_request(
               nil,
               ctx.room.id,
               ctx.identity,
               {ctx.guest_grant, {:replay_read, snapshot["video_source"]["id"]}}
             )
  end

  defp upload(conn, ctx, body) do
    selection = start_selection(conn, ctx)

    conn
    |> then(fn conn -> if conn.state == :sent, do: recycle(conn), else: conn end)
    |> then(fn conn ->
      if get_req_header(conn, "x-replay-grant") == [],
        do: put_req_header(conn, "x-replay-grant", ctx.host_grant),
        else: conn
    end)
    |> put_req_header("x-replay-selection", selection)
    |> put_req_header("content-type", "application/octet-stream")
    |> put_req_header("x-replay-name", "match.slp")
    |> put_req_header("x-replay-size", to_string(byte_size(body)))
    |> put_req_header("x-room-epoch", ctx.guards.epoch)
    |> put_req_header("x-room-revision", to_string(ctx.guards.revision))
    |> put_req_header("x-room-authority", to_string(ctx.guards.authority_revision))
    |> put_req_header("x-seat-generation", to_string(ctx.guards.connection_generation))
    |> post("/rooms/#{ctx.room.id}/replay", body)
  end

  defp start_selection(conn, ctx) do
    selection = Ecto.UUID.generate()

    pid =
      if get_req_header(conn, "x-replay-grant") == [ctx.guest_grant],
        do: ctx.guest,
        else: ctx.host

    case Rooms.request(ctx.scope, ctx.room.id, :snapshot, pid) do
      {:ok, snapshot} ->
        params =
          Map.take(snapshot, [:epoch, :revision, :authority_revision])
          |> Map.put(:selection, selection)
          |> Map.put(
            :connection_generation,
            Enum.find(snapshot.seats, &(&1.id == snapshot.controller_id)).connection_generation
          )
          |> stringify()

        Rooms.request(ctx.scope, ctx.room.id, {:replay_select, params}, pid)

      _ ->
        :ok
    end

    selection
  end

  defp fixture(name), do: File.read!("test/fixtures/slippi/#{name}.slp.gz") |> :zlib.gunzip()
  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
end
