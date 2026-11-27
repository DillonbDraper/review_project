defmodule ReviewProject.Rooms.SessionMediaTest do
  use ReviewProject.DataCase, async: false
  import ReviewProject.RoomsFixtures
  alias ReviewProject.Rooms.{Media, Session}

  setup do
    old = Application.get_env(:review_project, :uploaded_video)
    Application.put_env(:review_project, :uploaded_video, enabled: true)
    root = Path.join(System.tmp_dir!(), Ecto.UUID.generate())

    on_exit(fn ->
      if old,
        do: Application.put_env(:review_project, :uploaded_video, old),
        else: Application.delete_env(:review_project, :uploaded_video)

      File.rm_rf!(root)
    end)

    fixture = room_fixture()
    clock = start_supervised!({Agent, fn -> 0 end})

    media =
      start_supervised!(
        {Media,
         name: nil,
         root: root,
         sweep_interval_ms: 86_400_000,
         free_bytes: fn _ -> {:ok, 2_000_000_000} end,
         probe: fn _ -> {:ok, %{mime: "video/mp4", duration: 60.0}} end}
      )

    session =
      start_supervised!(
        {Session,
         room_id: fixture.room.id,
         name: nil,
         media_server: media,
         maintenance_interval: :infinity,
         clock: fn -> Agent.get(clock, & &1) end}
      )

    owner = transport()
    {:ok, _} = Session.join(session, fixture.scope, nil, fixture.invitation_token, "Owner", owner)
    {:ok, asset} = Media.reserve(fixture.room.id, "clip.mp4", 3, media)
    :ok = Media.append(fixture.room.id, asset.id, "abc", media)
    {:ok, _} = Media.finish(fixture.room.id, asset.id, media)

    {:ok,
     Map.merge(fixture, %{
       session: session,
       clock: clock,
       media: media,
       owner: owner,
       asset: asset
     })}
  end

  test "passive checks do not extend idle retention; begin upload does", c do
    advance(c, 3_599_999)
    assert {:ok, token} = Session.http_request(c.session, c.scope, nil, :can_upload)
    assert {:ok, ^token} = Session.http_request(c.session, c.scope, nil, :begin_upload)
    advance(c, 3_599_999)
    assert {:ok, %{}} = Session.http_request(c.session, c.scope, nil, :media_access)
    assert Media.staged(c.room.id, c.media)
    advance(c, 1)
    Session.maintain(c.session)
    assert nil == Media.staged(c.room.id, c.media)
  end

  test "known playback end anchors idle even across a long clock jump", c do
    assert {:ok, _} =
             control(c, %{"op" => "video", "source" => %{"kind" => "upload", "id" => c.asset.id}})

    assert {:ok, _} = control(c, %{"op" => "play"})
    advance(c, 3_659_999)
    assert {:ok, %{playing: false, position: 60.0}} = Session.maintain(c.session)
    assert Media.staged(c.room.id, c.media)
    advance(c, 1)
    assert {:ok, %{video_source: nil}} = Session.maintain(c.session)
    assert nil == Media.staged(c.room.id, c.media)
  end

  test "discard clears shared selection before readers retire", c do
    assert {:ok, _} =
             control(c, %{"op" => "video", "source" => %{"kind" => "upload", "id" => c.asset.id}})

    assert {:ok, reader} = Media.acquire(c.room.id, c.asset.id, c.media)
    assert {:error, :media_busy} = control(c, %{"op" => "discard_upload"})
    assert_receive :media_retired
    assert {:ok, %{video_source: nil}} = Session.maintain(c.session)
    assert File.exists?(reader.path)
    assert :ok = Media.release(c.room.id, c.asset.id, c.media)
    refute File.exists?(reader.path)
  end

  test "guest HTTP authority follows handoff and owner scope is verified", c do
    identity = browser_identity()
    guest = transport()
    {:ok, _} = Session.join(c.session, nil, identity, c.invitation_token, "Guest", guest)
    assert {:error, :not_controller} = Session.http_request(c.session, nil, identity, :can_upload)

    assert {:error, :not_controller} =
             Session.http_request(c.session, nil, identity, :continue_upload)

    assert {:error, :not_joined} = Session.http_request(c.session, nil, nil, :can_upload)
    assert {:ok, _} = Session.request(c.session, c.scope, c.owner, :leave)
    assert {:error, :not_joined} = Session.http_request(c.session, c.scope, nil, :continue_upload)
    advance(c, 10_000)
    assert {:ok, token} = Session.http_request(c.session, nil, identity, :can_upload)
    assert {:ok, ^token} = Session.http_request(c.session, nil, identity, :continue_upload)
    {:ok, _} = Session.join(c.session, c.scope, nil, nil, "Owner", c.owner)
    assert {:error, :not_controller} = Session.http_request(c.session, nil, identity, :can_upload)

    assert {:error, :not_controller} =
             Session.http_request(c.session, nil, identity, :continue_upload)

    assert {:ok, next} = Session.http_request(c.session, c.scope, nil, :can_upload)
    refute token == next
  end

  test "upload continuation verifies the live seat and authority without database queries", c do
    assert {:ok, token} = Session.http_request(c.session, c.scope, nil, :can_upload)
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:review_project, :repo, :query],
        &__MODULE__.record_query/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    for _ <- 1..10 do
      assert {:ok, ^token} = Session.http_request(c.session, c.scope, nil, :continue_upload)
    end

    assert {:error, :not_joined} = Session.http_request(c.session, nil, nil, :continue_upload)
    refute_receive :upload_query, 0
  end

  def record_query(_event, _measurements, _metadata, parent), do: send(parent, :upload_query)

  test "deliberate activity resets idle but conference reports and snapshots do not", c do
    advance(c, 3_599_999)
    assert {:ok, _} = Session.request(c.session, c.scope, c.owner, :activity)
    advance(c, 3_599_999)
    {:ok, snapshot} = Session.request(c.session, c.scope, c.owner, :snapshot)
    seat = Enum.find(snapshot.seats, &(&1.role == :owner))

    params = %{
      "epoch" => snapshot.epoch,
      "connection_generation" => seat.connection_generation,
      "ready" => true,
      "microphone" => true,
      "camera" => true
    }

    assert {:ok, _} = Session.request(c.session, c.scope, c.owner, {:media, params})
    assert Media.staged(c.room.id, c.media)
    advance(c, 1)
    Session.maintain(c.session)
    assert nil == Media.staged(c.room.id, c.media)
  end

  test "continuous empty boundary resets on rejoin", c do
    assert {:ok, _} = Session.request(c.session, c.scope, c.owner, :leave)
    advance(c, 299_999)
    assert {:ok, _} = Session.join(c.session, c.scope, nil, nil, "Owner", c.owner)
    assert Media.staged(c.room.id, c.media)
    assert {:ok, _} = Session.request(c.session, c.scope, c.owner, :leave)
    advance(c, 299_999)
    Session.maintain(c.session)
    assert Media.staged(c.room.id, c.media)
    advance(c, 1)
    Session.maintain(c.session)
    assert nil == Media.staged(c.room.id, c.media)
  end

  test "missing selected file invalidates the shared source", c do
    assert {:ok, _} =
             control(c, %{"op" => "video", "source" => %{"kind" => "upload", "id" => c.asset.id}})

    assert {:ok, reader} = Media.acquire(c.room.id, c.asset.id, c.media)
    assert :ok = Media.release(c.room.id, c.asset.id, c.media)
    File.rm!(reader.path)
    assert {:ok, %{video_source: nil}} = Session.maintain(c.session)
  end

  defp transport,
    do:
      start_supervised!(
        Supervisor.child_spec({ReviewProject.RoomsTransport, self()}, id: make_ref())
      )

  defp advance(c, ms), do: Agent.update(c.clock, &(&1 + ms))

  defp control(c, command) do
    {:ok, snapshot} = Session.request(c.session, c.scope, c.owner, :snapshot)

    guard = %{
      "epoch" => snapshot.epoch,
      "authority_revision" => snapshot.authority_revision,
      "revision" => snapshot.revision
    }

    Session.request(c.session, c.scope, c.owner, {:control, Map.merge(command, guard)})
  end
end
