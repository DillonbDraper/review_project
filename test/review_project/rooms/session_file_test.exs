defmodule ReviewProject.Rooms.SessionFileTest do
  use ReviewProject.DataCase, async: false
  import ReviewProject.RoomsFixtures
  alias ReviewProject.Rooms.Session

  setup do
    fixture = room_fixture()
    clock = start_supervised!({Agent, fn -> 0 end})

    session =
      start_supervised!(
        {Session,
         room_id: fixture.room.id,
         name: nil,
         maintenance_interval: :infinity,
         clock: fn -> Agent.get(clock, & &1) end}
      )

    owner = transport()
    {:ok, host} = Session.join(session, fixture.scope, nil, nil, "Owner", owner)
    guest = transport()
    identity = browser_identity()

    {:ok, receiver} =
      Session.join(session, nil, identity, fixture.invitation_token, "Guest", guest)

    {:ok,
     Map.merge(fixture, %{
       session: session,
       clock: clock,
       owner: owner,
       host: host,
       guest: guest,
       receiver: receiver,
       identity: identity
     })}
  end

  test "only a guarded controller offer can replace the current source", c do
    params = offer_params(c)

    assert {:error, :not_controller} =
             request(
               c,
               c.guest,
               {:file_offer,
                %{params | "connection_generation" => c.receiver.connection_generation}}
             )

    for {key, value, error} <- [
          {"epoch", "old", :stale_epoch},
          {"revision", -1, :stale_revision},
          {"authority_revision", -1, :stale_authority},
          {"connection_generation", -1, :stale_connection}
        ] do
      assert {:error, ^error} = request(c, c.owner, {:file_offer, Map.put(params, key, value)})
    end

    assert {:ok, first} = request(c, c.owner, {:file_offer, params})
    assert %{kind: "local_file", size: 100, available: true, seat_id: id} = first.video_source
    assert id == c.host.self_id
    assert first.position == 0.0
    refute first.playing
    refute Map.has_key?(first.video_source, :page_id)
    bad = put_in(offer_params(c), ["metadata", "size"], 1_073_741_825)
    assert {:error, :unsupported_media} = request(c, c.owner, {:file_offer, bad})
    assert snapshot(c).video_source == first.video_source
    assert {:ok, second} = request(c, c.owner, {:file_offer, offer_params(c)})
    refute second.video_source.id == first.video_source.id
    assert second.video_source.generation == first.video_source.generation + 1
  end

  test "file signaling works with devices off, only between source and live receivers", c do
    {:ok, selected} = request(c, c.owner, {:file_offer, offer_params(c)})

    data = %{
      "type" => "description",
      "negotiation_id" => "n",
      "description" => %{"type" => "offer", "sdp" => "bounded"}
    }

    params = peer_params(c, selected)
    assert {:ok, %{}} = request(c, c.owner, {:file_signal, Map.put(params, "data", data)})
    guest = c.guest
    assert_receive {^guest, {:room_file_signal, %{data: ^data, source_id: source_id}}}
    assert source_id == selected.video_source.id

    assert {:error, :invalid_signal} =
             request(
               c,
               c.owner,
               {:file_signal,
                Map.put(
                  params,
                  "data",
                  put_in(data, ["description", "sdp"], String.duplicate("x", 65_537))
                )}
             )

    assert {:ok, %{}} = request(c, c.owner, {:file_reset, params})

    assert {:error, :invalid_signal} =
             request(c, c.owner, {:file_signal, Map.put(params, "data", data)})

    assert {:ok, %{}} =
             request(
               c,
               c.owner,
               {:file_signal, params |> Map.put("peer_generation", 1) |> Map.put("data", data)}
             )

    other = transport()

    {:ok, other_reply} =
      Session.join(c.session, nil, browser_identity(), c.invitation_token, "Other", other)

    sideways =
      params
      |> Map.put("to", other_reply.self_id)
      |> Map.put("connection_generation", c.receiver.connection_generation)
      |> Map.put("to_connection_generation", other_reply.connection_generation)
      |> Map.put("data", data)

    assert {:error, :invalid_signal} = request(c, c.guest, {:file_signal, sideways})
    assert {:ok, _} = request(c, c.owner, {:file_offer, offer_params(c)})
    assert {:error, :stale_source} = request(c, c.owner, {:file_ice, params})
  end

  test "source departure pauses, same document restores delivery, controller explicitly resumes",
       c do
    {:ok, selected} = request(c, c.owner, {:file_offer, offer_params(c)})
    assert {:ok, _} = control(c, c.owner, %{"op" => "play"})
    advance(c, 2500)
    assert {:ok, _} = request(c, c.owner, :leave)
    paused = snapshot(c)
    assert paused.position == 2.5
    refute paused.playing
    refute paused.video_source.available
    {:ok, rejoin} = Session.join(c.session, c.scope, nil, nil, "Owner", c.owner)

    params =
      file_guards(c, selected)
      |> Map.put("connection_generation", rejoin.connection_generation)
      |> Map.put("available", true)

    assert {:error, :invalid_source} =
             request(
               c,
               c.owner,
               {:file_available, Map.put(params, "page_id", "another-document")}
             )

    assert {:error, :source_unavailable} = control(c, c.owner, %{"op" => "play"})

    assert {:ok, restored} =
             request(c, c.owner, {:file_available, Map.put(params, "page_id", "document")})

    refute restored.playing
    assert restored.position == 2.5
    assert {:ok, %{playing: true}} = control(c, c.owner, %{"op" => "play"})
  end

  test "guest supplier survives host reclaim and a failed receiver does not pause playback", c do
    assert {:ok, _} = request(c, c.owner, :leave)
    advance(c, 10_000)

    guest_params =
      offer_params(c) |> Map.put("connection_generation", c.receiver.connection_generation)

    {:ok, selected} = request(c, c.guest, {:file_offer, guest_params})
    {:ok, _} = Session.join(c.session, c.scope, nil, nil, "Owner", c.owner)
    assert snapshot(c).controller_id == c.host.self_id
    assert snapshot(c).video_source.seat_id == c.receiver.self_id
    assert {:ok, %{playing: true}} = control(c, c.owner, %{"op" => "play"})
    # The controller is a receiver; its disappearance leaves the supplying guest playing.
    assert {:ok, _} = request(c, c.owner, :leave)
    assert snapshot(c).playing
    assert snapshot(c).video_source.id == selected.video_source.id
  end

  test "replacement seat cannot retain availability and cleanup expires only the share session",
       c do
    {:ok, _} = request(c, c.owner, {:file_offer, offer_params(c)})
    replacement = transport()
    {:ok, _} = Session.join(c.session, c.scope, nil, nil, "Owner", replacement)
    refute snapshot(c).video_source.available
    assert {:error, :not_joined} = request(c, c.owner, {:file_offer, offer_params(c)})
    advance(c, 3_599_999)
    assert snapshot(c).video_source
    advance(c, 1)
    assert {:ok, %{video_source: nil, connected_count: 2}} = Session.maintain(c.session)
    assert {:ok, _} = request(c, c.guest, :history)
  end

  test "empty cleanup expires only the share", c do
    {:ok, _} = request(c, c.owner, {:file_offer, offer_params(c)})
    assert {:ok, _} = request(c, c.owner, :leave)
    assert {:ok, _} = request(c, c.guest, :leave)
    advance(c, 299_999)
    assert snapshot(c).video_source
    advance(c, 1)
    assert {:ok, %{video_source: nil}} = Session.maintain(c.session)
  end

  test "re-admission and availability restoration do not extend idle retention", c do
    {:ok, selected} = request(c, c.owner, {:file_offer, offer_params(c)})
    assert {:ok, _} = request(c, c.owner, :leave)
    advance(c, 3_599_999)
    {:ok, rejoined} = Session.join(c.session, c.scope, nil, nil, "Owner", c.owner)

    params =
      file_guards(c, selected)
      |> Map.put("connection_generation", rejoined.connection_generation)
      |> Map.put("page_id", "document")
      |> Map.put("available", true)

    assert {:ok, _} = request(c, c.owner, {:file_available, params})
    advance(c, 1)
    assert {:ok, %{video_source: nil, connected_count: 2}} = Session.maintain(c.session)
  end

  test "the known playback end anchors idle cleanup across delayed maintenance", c do
    {:ok, _} = request(c, c.owner, {:file_offer, offer_params(c)})
    assert {:ok, _} = control(c, c.owner, %{"op" => "play"})
    advance(c, 3_659_999)

    assert {:ok, %{playing: false, position: 60.0, video_source: %{kind: "local_file"}}} =
             Session.maintain(c.session)

    advance(c, 1)
    assert {:ok, %{video_source: nil}} = Session.maintain(c.session)
  end

  defp transport,
    do:
      start_supervised!(
        Supervisor.child_spec({ReviewProject.RoomsTransport, self()}, id: make_ref())
      )

  defp advance(c, ms), do: Agent.update(c.clock, &(&1 + ms))
  defp request(c, pid, op), do: Session.request(c.session, c.scope, pid, op)
  defp snapshot(c), do: elem(Session.maintain(c.session), 1)

  defp offer_params(c) do
    current = snapshot(c)

    %{
      "epoch" => current.epoch,
      "authority_revision" => current.authority_revision,
      "revision" => current.revision,
      "connection_generation" => c.host.connection_generation,
      "page_id" => "document",
      "metadata" => %{
        "name" => "clip.mp4",
        "size" => 100,
        "duration" => 60.0,
        "mime" => "video/mp4",
        "video_codec" => "h264",
        "audio_codec" => "aac",
        "codec" => "video/mp4; codecs=\"avc1.42E01E, mp4a.40.2\""
      }
    }
  end

  defp file_guards(c, selected),
    do: %{
      "epoch" => selected.epoch,
      "connection_generation" => c.host.connection_generation,
      "source_id" => selected.video_source.id,
      "source_generation" => selected.video_source.generation
    }

  defp peer_params(c, selected),
    do:
      Map.merge(file_guards(c, selected), %{
        "to" => c.receiver.self_id,
        "to_connection_generation" => c.receiver.connection_generation,
        "peer_generation" => 0
      })

  defp control(c, pid, command) do
    {:ok, current} = request(c, pid, :snapshot)

    guards = %{
      "epoch" => current.epoch,
      "authority_revision" => current.authority_revision,
      "revision" => current.revision
    }

    request(c, pid, {:control, Map.merge(command, guards)})
  end
end
