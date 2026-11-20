defmodule ReviewProjectWeb.RoomConferenceChannelTest do
  use ReviewProject.DataCase, async: false

  import Phoenix.ChannelTest
  import ReviewProject.RoomsFixtures
  alias ReviewProject.Accounts
  alias ReviewProject.Rooms.Session
  alias ReviewProjectWeb.{RoomChannel, RoomSocket}

  @endpoint ReviewProjectWeb.Endpoint

  setup do
    fixture = room_fixture()
    clock = start_supervised!({Agent, fn -> 0 end})

    start_supervised!(
      {Session,
       room_id: fixture.room.id,
       clock: fn -> Agent.get(clock, & &1) end,
       maintenance_interval: :infinity}
    )

    Map.put(fixture, :clock, clock)
  end

  test "admitted receive-only guests exchange targeted signals with server-assigned identity",
       ctx do
    first = join_room(ctx)
    second = join_room(ctx)
    enable(first)
    snapshot = enable(second)
    assert snapshot.roster_revision > second.reply.snapshot.roster_revision
    seat = Enum.find(snapshot.seats, &(&1.id == second.reply.self_id))
    assert seat.conference == %{ready: true, microphone: false, camera: false, generation: 1}
    assert seat.connection_generation == second.reply.connection_generation

    ref =
      push(first.socket, "conference_signal", Map.put(signal(first, second), "from", "forged"))

    assert_reply ref, :ok, %{}

    assert_push "conference_signal", %{
      from: from,
      connection_generation: 1,
      conference_generation: 1,
      to_connection_generation: 1,
      to_conference_generation: 1
    }

    assert from == first.reply.self_id
  end

  test "device state is independent of conference readiness and invalid state is refused", ctx do
    guest = join_room(ctx)
    snapshot = enable(guest, %{microphone: true, camera: false})
    assert Enum.find(snapshot.seats, &(&1.id == guest.reply.self_id)).conference.microphone
    snapshot = enable(guest, %{microphone: false, camera: true})
    assert Enum.find(snapshot.seats, &(&1.id == guest.reply.self_id)).conference.camera
    assert Enum.find(snapshot.seats, &(&1.id == guest.reply.self_id)).conference.generation == 1

    assert enable(guest, %{microphone: false, camera: true}).roster_revision ==
             snapshot.roster_revision

    for state <- [%{ready: "true"}, %{camera: nil}, %{ready: false, microphone: true}] do
      ref = push(guest.socket, "conference_state", Map.merge(state_payload(guest), state))
      assert_reply ref, :error, %{reason: "invalid_conference_state"}
    end

    ref = push(guest.socket, "chat_send", %{body: "Still in the room"})
    assert_reply ref, :ok, %{body: "Still in the room"}
  end

  test "signaling requires both members to have initialized their receivers", ctx do
    first = join_room(ctx)
    second = join_room(ctx)
    enable(first)
    ref = push(first.socket, "conference_signal", signal(first, second))
    assert_reply ref, :error, %{reason: "invalid_signal"}
    refute_push "conference_signal", _
  end

  test "stale epochs and connection generations are refused", ctx do
    first = join_room(ctx)
    second = join_room(ctx)
    enable(first)
    enable(second)

    for {field, value, reason} <- [
          {"epoch", Ecto.UUID.generate(), "stale_epoch"},
          {"connection_generation", 99, "stale_connection"},
          {"conference_generation", 99, "invalid_signal"},
          {"to_connection_generation", 99, "invalid_signal"},
          {"to_conference_generation", 99, "invalid_signal"}
        ] do
      ref = push(first.socket, "conference_signal", Map.put(signal(first, second), field, value))
      assert_reply ref, :error, %{reason: ^reason}
    end
  end

  test "self, cross-room and disconnected recipients cannot receive signals", ctx do
    first = join_room(ctx)
    second = join_room(ctx)
    enable(first)
    enable(second)
    other_room = room_fixture()

    start_supervised!(
      Supervisor.child_spec({Session, room_id: other_room.room.id}, id: :other_room)
    )

    other = join_room(other_room)
    enable(other)

    for target <- [first, other] do
      ref = push(first.socket, "conference_signal", signal(first, target))
      assert_reply ref, :error, %{reason: "invalid_signal"}
    end

    ref = push(second.socket, "leave", %{})
    assert_reply ref, :ok, %{}
    ref = push(first.socket, "conference_signal", signal(first, second))
    assert_reply ref, :error, %{reason: "invalid_signal"}
  end

  test "tab replacement clears media state and invalidates old-generation signaling", ctx do
    first = join_room(ctx)
    old = join_room(ctx)
    enable(first)
    enable(old, %{camera: true})
    replacement = join_room(ctx, old.identity)
    seat = Enum.find(replacement.reply.snapshot.seats, &(&1.id == old.reply.self_id))
    refute seat.conference.ready
    refute seat.conference.camera
    assert replacement.reply.connection_generation == old.reply.connection_generation + 1
    enable(replacement)

    ref = push(first.socket, "conference_signal", signal(first, old))
    assert_reply ref, :error, %{reason: "invalid_signal"}
    ref = push(first.socket, "conference_signal", signal(first, replacement))
    assert_reply ref, :ok, %{}
    assert_push "conference_signal", %{to_connection_generation: 2}
  end

  test "reinitializing the conference rejects delayed signals within the same room connection",
       ctx do
    first = join_room(ctx)
    second = join_room(ctx)
    enable(first)
    enable(second)
    enable(second, %{ready: false})
    snapshot = enable(second)
    assert Enum.find(snapshot.seats, &(&1.id == second.reply.self_id)).conference.generation == 3

    ref = push(first.socket, "conference_signal", signal(first, second))
    assert_reply ref, :error, %{reason: "invalid_signal"}

    ref =
      push(
        first.socket,
        "conference_signal",
        Map.put(signal(first, second), "to_conference_generation", 3)
      )

    assert_reply ref, :ok, %{}
  end

  test "malformed and oversized descriptions and candidates never reach the recipient", ctx do
    first = join_room(ctx)
    second = join_room(ctx)
    enable(first)
    enable(second)

    for data <- [
          %{"type" => "description", "description" => %{"type" => "offer", "sdp" => "v=0"}},
          %{
            "type" => "description",
            "negotiation_id" => "offer",
            "description" => %{"type" => "offer", "sdp" => String.duplicate("x", 65_537)}
          },
          %{
            "type" => "candidate",
            "negotiation_id" => "offer",
            "candidate" => %{"candidate" => String.duplicate("x", 4097)}
          },
          %{
            "type" => "candidate",
            "negotiation_id" => "offer",
            "candidate" => %{"candidate" => "example", "sdpMid" => 1}
          },
          %{
            "type" => "candidate",
            "negotiation_id" => "offer",
            "candidate" => %{"candidate" => "example", "extra" => true}
          },
          %{
            "type" => "description",
            "negotiation_id" => "offer",
            "description" => %{"type" => "rollback", "sdp" => "v=0"}
          }
        ] do
      ref = push(first.socket, "conference_signal", Map.put(signal(first, second), "data", data))
      assert_reply ref, :error, %{reason: "invalid_signal"}
    end

    refute_push "conference_signal", _
  end

  test "signaling bursts are bounded and the allowance recovers without losing membership", ctx do
    first = join_room(ctx)
    second = join_room(ctx)
    enable(first)
    enable(second)

    for _ <- 1..256 do
      ref = push(first.socket, "conference_signal", signal(first, second))
      assert_reply ref, :ok, %{}
    end

    ref = push(first.socket, "conference_signal", signal(first, second))
    assert_reply ref, :error, %{reason: "rate_limited"}
    Agent.update(ctx.clock, &(&1 + 10_000))
    ref = push(first.socket, "conference_signal", signal(first, second))
    assert_reply ref, :ok, %{}
  end

  test "revoked account sessions cannot update conference state", ctx do
    host = join_room(ctx, browser_identity(), ctx.scope)
    Accounts.delete_user_session_token(host.socket.assigns.session_token)
    ref = push(host.socket, "conference_state", state_payload(host))
    assert_reply ref, :error, %{reason: "session_expired"}
    assert_push "room_ended", %{reason: "session_expired"}
  end

  test "peer reset coordinates both ends and rejects delayed signals and duplicate resets", ctx do
    first = join_room(ctx)
    second = join_room(ctx)
    enable(first)
    enable(second)
    ref = push(first.socket, "conference_reset", signal(first, second))
    assert_reply ref, :ok, %{}
    assert_push "conference_peer", %{from: from, peer_generation: 1}
    assert from in [first.reply.self_id, second.reply.self_id]
    assert_push "conference_peer", %{peer_generation: 1}
    ref = push(second.socket, "conference_reset", signal(second, first))
    assert_reply ref, :error, %{reason: "stale_peer"}
    ref = push(first.socket, "conference_signal", signal(first, second))
    assert_reply ref, :error, %{reason: "invalid_signal"}

    ref =
      push(
        first.socket,
        "conference_signal",
        Map.put(signal(first, second), "peer_generation", 1)
      )

    assert_reply ref, :ok, %{}
    assert_push "conference_signal", %{peer_generation: 1}

    for generation <- 1..3 do
      ref =
        push(
          first.socket,
          "conference_reset",
          Map.put(signal(first, second), "peer_generation", generation)
        )

      assert_reply ref, :ok, %{}
    end

    ref =
      push(first.socket, "conference_reset", Map.put(signal(first, second), "peer_generation", 4))

    assert_reply ref, :error, %{reason: "rate_limited"}
  end

  test "ICE access checks membership generations and has an independent rate limit", ctx do
    guest = join_room(ctx)
    payload = state_payload(guest)
    ref = push(guest.socket, "conference_ice", %{payload | epoch: "obsolete"})
    assert_reply ref, :error, %{reason: "stale_epoch"}

    for _ <- 1..6 do
      ref = push(guest.socket, "conference_ice", payload)
      assert_reply ref, :ok, %{servers: [], refresh_after: nil}
    end

    ref = push(guest.socket, "conference_ice", payload)
    assert_reply ref, :error, %{reason: "rate_limited"}
    Agent.update(ctx.clock, &(&1 + 10_000))
    ref = push(guest.socket, "conference_ice", payload)
    assert_reply ref, :ok, %{}
    ref = push(guest.socket, "chat_send", %{body: "Room remains usable"})
    assert_reply ref, :ok, %{}
  end

  test "nonmember processes cannot request relay credentials or reset another pair", ctx do
    guest = join_room(ctx)

    assert {:error, :not_joined} =
             ReviewProject.Rooms.request(nil, ctx.room.id, {:ice, state_payload(guest)})

    assert {:error, :not_joined} =
             ReviewProject.Rooms.request(nil, ctx.room.id, {:reset_peer, %{}})
  end

  test "revoked sessions cannot obtain ICE configuration", ctx do
    host = join_room(ctx, browser_identity(), ctx.scope)
    Accounts.delete_user_session_token(host.socket.assigns.session_token)
    ref = push(host.socket, "conference_ice", state_payload(host))
    assert_reply ref, :error, %{reason: "session_expired"}
  end

  defp join_room(ctx, identity \\ browser_identity(), scope \\ nil) do
    token = if scope, do: Accounts.generate_user_session_token(scope.user)
    assigns = %{current_scope: scope, session_token: token, browser_identity: identity}

    assert {:ok, reply, socket} =
             subscribe_and_join(
               socket(RoomSocket, nil, assigns),
               RoomChannel,
               "room:#{ctx.room.id}",
               %{invitation: ctx.invitation_token, display_name: "Participant"}
             )

    %{reply: reply, socket: socket, identity: identity}
  end

  defp state_payload(guest) do
    %{
      epoch: guest.reply.snapshot.epoch,
      connection_generation: guest.reply.connection_generation,
      ready: true,
      microphone: false,
      camera: false
    }
  end

  defp enable(guest, changes \\ %{}) do
    ref = push(guest.socket, "conference_state", Map.merge(state_payload(guest), changes))
    assert_reply ref, :ok, snapshot
    snapshot
  end

  defp signal(from, to) do
    %{
      "epoch" => from.reply.snapshot.epoch,
      "connection_generation" => from.reply.connection_generation,
      "conference_generation" => 1,
      "peer_generation" => 0,
      "to" => to.reply.self_id,
      "to_connection_generation" => to.reply.connection_generation,
      "to_conference_generation" => 1,
      "data" => %{
        "type" => "description",
        "negotiation_id" => "test-offer",
        "description" => %{"type" => "offer", "sdp" => "v=0\r\n"}
      }
    }
  end
end
