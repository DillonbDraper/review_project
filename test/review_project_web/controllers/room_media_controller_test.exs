defmodule ReviewProjectWeb.RoomMediaControllerTest do
  use ReviewProjectWeb.ConnCase, async: false
  @moduletag :capture_log

  import ReviewProject.RoomsFixtures
  alias ReviewProject.Rooms.{Media, Session}

  setup %{conn: conn} do
    fixture = room_fixture()
    identity = browser_identity()
    transport = start_supervised!({ReviewProject.RoomsTransport, self()})

    session =
      start_supervised!({Session, room_id: fixture.room.id, maintenance_interval: :infinity})

    {:ok, joined} = Session.join(session, fixture.scope, identity, nil, "Owner", transport)
    # Only replace the local probe option; exercise the real bounded disk service.
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

    conn =
      conn
      |> log_in_user(fixture.scope.user)
      |> init_test_session(%{room_browser_identity: identity})

    {:ok,
     Map.merge(fixture, %{
       conn: conn,
       session: session,
       joined: joined,
       transport: transport,
       identity: identity
     })}
  end

  test "raw upload becomes ready without selecting and serves private full, range and HEAD",
       ctx do
    conn = upload(ctx, "0123456789")
    assert %{"id" => id, "status" => "ready", "name" => "clip.mp4"} = json_response(conn, 200)
    refute Map.has_key?(json_response(conn, 200), "path")

    assert {:ok, %{video_id: nil}} =
             Session.request(ctx.session, ctx.scope, ctx.transport, :snapshot)

    path = "/room-media/#{ctx.room.id}/#{id}"
    response = get(recycle(conn), path)
    assert response.status == 200
    assert response.resp_body == "0123456789"
    assert get_resp_header(response, "cache-control") == ["private, no-store"]
    assert get_resp_header(response, "content-type") == ["video/mp4"]

    response = conn |> recycle() |> put_req_header("range", "bytes=2-5") |> get(path)
    assert response.status == 206
    assert response.resp_body == "2345"
    assert get_resp_header(response, "content-range") == ["bytes 2-5/10"]

    response = conn |> recycle() |> put_req_header("range", "bytes=-3") |> get(path)
    assert response.resp_body == "789"
    response = conn |> recycle() |> head(path)
    assert response.status == 200
    assert response.resp_body == ""
    assert get_resp_header(response, "content-length") == ["10"]

    response = conn |> recycle() |> put_req_header("range", "bytes=10-") |> get(path)
    assert response.status == 416
    assert get_resp_header(response, "content-range") == ["bytes */10"]
  end

  test "cross-room, anonymous and departed guests cannot stream", ctx do
    conn = upload(ctx, "hello")
    %{"id" => id} = json_response(conn, 200)
    path = "/room-media/#{ctx.room.id}/#{id}"
    assert build_conn() |> get(path) |> json_response(403) == %{"error" => "not_joined"}
    other = room_fixture(ctx.scope)
    response = conn |> recycle() |> get("/room-media/#{other.room.id}/#{id}")
    assert json_response(response, 403) == %{"error" => "not_joined"}

    guest =
      start_supervised!(Supervisor.child_spec({ReviewProject.RoomsTransport, self()}, id: :guest))

    identity = browser_identity()
    {:ok, _} = Session.join(ctx.session, nil, identity, ctx.invitation_token, "Guest", guest)
    guest_conn = build_conn() |> init_test_session(%{room_browser_identity: identity})
    assert guest_conn |> get(path) |> response(200) == "hello"
    assert {:ok, _} = Session.request(ctx.session, nil, guest, :leave)
    assert guest_conn |> get(path) |> json_response(403) == %{"error" => "not_joined"}
  end

  test "unauthorized malformed multipart is rejected without parsing its body", ctx do
    conn = build_conn() |> put_req_header("content-type", "multipart/form-data; boundary=missing")
    result = post(conn, "/room-media/#{ctx.room.id}", "not a multipart body")
    assert json_response(result, 403) == %{"error" => "not_joined"}
    assert {_, %{req_body: "not a multipart body"}} = result.adapter
    assert Media.staged(ctx.room.id) == nil
  end

  test "controller rejects multipart and claimed overflow before staging", ctx do
    result =
      ctx.conn
      |> put_req_header("content-type", "multipart/form-data; boundary=missing")
      |> post("/room-media/#{ctx.room.id}", "bad")

    assert json_response(result, 415) == %{"error" => "unsupported_media_type"}
    result = upload(ctx, "a", "1073741825")
    assert json_response(result, 413) == %{"error" => "too_large"}
    assert Media.staged(ctx.room.id) == nil
  end

  test "mismatched actual bytes clean the slot and do not replace YouTube", ctx do
    snapshot = ctx.joined.snapshot

    command = %{
      "op" => "video",
      "video_id" => "M7lc1UVf-VE",
      "epoch" => snapshot.epoch,
      "authority_revision" => snapshot.authority_revision,
      "revision" => snapshot.revision
    }

    assert {:ok, _} = Session.request(ctx.session, ctx.scope, ctx.transport, {:control, command})
    assert upload(ctx, "too long", "1") |> json_response(413) == %{"error" => "too_large"}
    assert Media.staged(ctx.room.id) == nil
    assert upload(ctx, "short", "10") |> json_response(422) == %{"error" => "size_mismatch"}
    assert Media.staged(ctx.room.id) == nil

    assert {:ok, %{video_id: "M7lc1UVf-VE"}} =
             Session.request(ctx.session, ctx.scope, ctx.transport, :snapshot)
  end

  test "status is passive and guarded DELETE releases the sole staged slot", ctx do
    conn = upload(ctx, "video")
    %{"id" => id} = json_response(conn, 200)
    response = conn |> recycle() |> get("/room-media/#{ctx.room.id}")

    assert %{"staged" => %{"id" => ^id}, "max_file_bytes" => 1_073_741_824, "enabled" => true} =
             json_response(response, 200)

    assert upload(ctx, "another") |> json_response(409) == %{"error" => "media_busy"}
    assert {:ok, snapshot} = Session.request(ctx.session, ctx.scope, ctx.transport, :snapshot)
    params = Map.take(snapshot, [:epoch, :authority_revision, :revision])

    response =
      conn
      |> recycle()
      |> put_req_header("content-type", "application/json")
      |> delete("/room-media/#{ctx.room.id}", Jason.encode!(params))

    assert %{"staged" => nil} = json_response(response, 200)
    assert Media.staged(ctx.room.id) == nil
  end

  test "media mutation retains real CSRF protection", ctx do
    conn =
      ctx.conn
      |> put_private(:plug_skip_csrf_protection, false)
      |> put_req_header("content-type", "application/octet-stream")

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      post(conn, "/room-media/#{ctx.room.id}", "video")
    end

    bootstrap = ctx.conn |> get("/room-session")
    %{"csrf_token" => csrf} = json_response(bootstrap, 200)

    result =
      bootstrap
      |> recycle()
      |> put_private(:plug_skip_csrf_protection, false)
      |> put_req_header("x-csrf-token", csrf)
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("x-video-filename", "clip.mp4")
      |> put_req_header("x-video-size", "5")
      |> post("/room-media/#{ctx.room.id}", "video")

    assert %{"status" => "ready"} = json_response(result, 200)
  end

  test "retired HTTP readers close and release before unwinding", ctx do
    result = upload(ctx, "video")
    %{"id" => id} = json_response(result, 200)
    send(self(), :media_retired)
    assert catch_exit(get(recycle(result), "/room-media/#{ctx.room.id}/#{id}")) == :shutdown
    # Release ran even though the length-delimited response was aborted.
    assert :ok = Media.discard(ctx.room.id)
    assert Media.staged(ctx.room.id) == nil
  end

  test "multiple chunks stay bounded and successful ready files retain the room slot", ctx do
    body = String.duplicate("v", 600_000)
    result = upload(ctx, body)
    assert %{"size" => 600_000, "status" => "ready"} = json_response(result, 200)
    assert %{size: 600_000, status: :ready} = Media.staged(ctx.room.id)
  end

  test "multi-chunk upload verifies durable room state only at upload boundaries", ctx do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:review_project, :repo, :query],
        &__MODULE__.record_room_query/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert %{"status" => "ready"} =
             upload(ctx, String.duplicate("v", 2_000_000)) |> json_response(200)

    # Admission, after receiving, and after validation; independent of chunk count.
    for _ <- 1..3, do: assert_receive(:room_open_query)
    refute_receive :room_open_query, 0
  end

  test "durable closure during validation rejects completion even before its notification", ctx do
    :sys.replace_state(Media, fn s ->
      probe = fn _ ->
        {:ok, _} =
          ReviewProject.Rooms.Store.close_room(ctx.scope, ctx.room.id, DateTime.utc_now())

        {:ok, %{mime: "video/mp4", duration: 10.0}}
      end

      %{s | opts: Keyword.put(s.opts, :probe, probe)}
    end)

    assert %{"error" => "room_closed"} = upload(ctx, "video") |> json_response(404)
    assert Media.staged(ctx.room.id) == nil
  end

  def record_room_query(_event, _measurements, %{source: "rooms"}, parent),
    do: send(parent, :room_open_query)

  def record_room_query(_event, _measurements, _metadata, _parent), do: :ok

  test "authority loss during validation rejects completion and frees ready bytes", ctx do
    :sys.replace_state(Media, fn s ->
      probe = fn _ ->
        {:ok, _} = Session.request(ctx.session, ctx.scope, ctx.transport, :leave)
        {:ok, %{mime: "video/mp4", duration: 10.0}}
      end

      %{s | opts: Keyword.put(s.opts, :probe, probe)}
    end)

    result = upload(ctx, "video")
    assert json_response(result, 403) == %{"error" => "not_joined"}
    assert Media.staged(ctx.room.id) == nil
  end

  test "stale or oversized discard JSON never removes a ready file", ctx do
    result = upload(ctx, "video")
    assert %{"id" => id} = json_response(result, 200)
    conn = ctx.conn |> put_req_header("content-type", "application/json")

    result =
      delete(
        conn,
        "/room-media/#{ctx.room.id}",
        Jason.encode!(%{epoch: "old", authority_revision: 1, revision: 1})
      )

    assert json_response(result, 409) == %{"error" => "stale_epoch"}
    result = delete(conn, "/room-media/#{ctx.room.id}", String.duplicate(" ", 5_000))
    assert json_response(result, 413) == %{"error" => "too_large"}
    assert %{id: ^id} = Media.staged(ctx.room.id)
  end

  defp upload(ctx, body, size \\ nil) do
    ctx.conn
    |> put_req_header("content-type", "application/octet-stream")
    |> put_req_header("x-video-filename", "clip.mp4")
    |> put_req_header("x-video-size", size || Integer.to_string(byte_size(body)))
    |> post("/room-media/#{ctx.room.id}", body)
  end
end
