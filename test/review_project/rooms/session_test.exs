defmodule ReviewProject.Rooms.SessionTest do
  use ReviewProject.DataCase, async: false
  import ReviewProject.RoomsFixtures
  alias ReviewProject.Rooms.{Room, Seat, Session, Store}

  setup do
    fixture = room_fixture()
    clock = start_supervised!({Agent, fn -> 0 end})
    base = ~U[2026-10-25 12:00:00.000000Z]

    opts = [
      room_id: fixture.room.id,
      name: nil,
      maintenance_interval: :infinity,
      clock: fn -> Agent.get(clock, & &1) end,
      wall_clock: fn -> DateTime.add(base, Agent.get(clock, & &1), :millisecond) end
    ]

    session = start_supervised!({Session, opts})
    {:ok, Map.merge(fixture, %{session: session, clock: clock, session_opts: opts})}
  end

  test "four guest seats never consume the owner's reserved place", ctx do
    guests = for i <- 1..4, do: guest(ctx, "Guest #{i}")
    assert {:error, :room_full} = join_seat(ctx, nil, transport(), browser_identity(), "Sixth")
    owner = transport()
    assert {:ok, reply} = join_seat(ctx, ctx.scope, owner, nil, "Owner")
    assert reply.snapshot.connected_count == 5
    assert reply.snapshot.seat_count == 5
    assert reply.snapshot.controller_id == reply.self_id
    assert length(guests) == 4
    refute Map.has_key?(reply.snapshot, :owner_id)
    refute Enum.any?(reply.snapshot.seats, &Map.has_key?(&1, :browser_identity_hash))
  end

  test "simultaneous joins serialize without exceeding five total seats", ctx do
    pids = for _ <- 1..6, do: transport()

    results =
      Task.async_stream(pids, fn pid -> join_seat(ctx, nil, pid, browser_identity(), "Guest") end,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 4
    assert Enum.count(results, &(&1 == {:error, :room_full})) == 2
    assert {:ok, %{seat_count: 5, connected_count: 4}} = Session.maintain(ctx.session)
  end

  test "same-browser replacement reuses its seat and revokes the old transport", ctx do
    first = guest(ctx)
    replacement = transport()
    assert {:ok, reply} = join_seat(ctx, nil, replacement, first.identity, "Renamed")
    assert reply.self_id == first.reply.self_id
    assert reply.connection_generation == first.reply.connection_generation + 1
    assert reply.snapshot.seat_count == 2
    assert_receive {pid, {:room_seat_replaced, _}} when pid == first.pid
    assert {:error, :not_joined} = Session.request(ctx.session, nil, first.pid, :snapshot)
    disconnect(ctx.session, first.pid)

    assert {:ok, %{connected_count: 1}} =
             Session.request(ctx.session, nil, replacement, :snapshot)
  end

  test "an owner can replace their seat from another signed-in browser without an invitation",
       ctx do
    first = transport()
    {:ok, one} = join_seat(ctx, ctx.scope, first, nil, "Owner")
    second = transport()

    assert {:ok, two} =
             Session.join(ctx.session, ctx.scope, browser_identity(), nil, "Owner", second)

    assert one.self_id == two.self_id
    assert two.snapshot.controller_id == two.self_id
    assert two.snapshot.connected_count == 1

    assert {:error, :authentication_required} =
             Session.request(ctx.session, nil, second, :snapshot)
  end

  test "guest reservation retains its identity and order for 30 seconds", ctx do
    first = guest(ctx)
    original = Repo.get!(Seat, first.reply.self_id)
    disconnect(ctx.session, first.pid)
    advance(ctx, 29_999)
    assert {:ok, %{seat_count: 2}} = Session.maintain(ctx.session)
    new_pid = transport()
    assert {:ok, reply} = join_seat(ctx, nil, new_pid, first.identity, "Back")
    assert reply.self_id == original.id
    assert Repo.get!(Seat, original.id).join_sequence == original.join_sequence
    disconnect(ctx.session, new_pid)
    advance(ctx, 30_000)
    refute Repo.get(Seat, original.id)
    assert {:ok, reply} = join_seat(ctx, nil, transport(), first.identity, "New seat")
    refute reply.self_id == original.id
    assert Repo.get!(Seat, reply.self_id).join_sequence > original.join_sequence
  end

  test "disconnected reservations block admission until their deadline", ctx do
    [first | _] = for _ <- 1..4, do: guest(ctx)
    disconnect(ctx.session, first.pid)
    assert {:error, :room_full} = join_seat(ctx, nil, transport(), browser_identity(), "Waiting")
    advance(ctx, 30_000)
    assert {:ok, _} = join_seat(ctx, nil, transport(), browser_identity(), "Admitted")
  end

  test "invalid replacement names leave the existing transport connected", ctx do
    first = guest(ctx)
    assert {:error, %Ecto.Changeset{}} = join_seat(ctx, nil, transport(), first.identity, nil)
    assert {:ok, %{connected_count: 1}} = Session.request(ctx.session, nil, first.pid, :snapshot)
  end

  test "recovery preserves an already disconnected guest's original expiry", ctx do
    first = guest(ctx)
    disconnect(ctx.session, first.pid)
    advance(ctx, 20_000)
    stop_supervised!(Session)
    session = start_supervised!({Session, ctx.session_opts})
    ctx = %{ctx | session: session}
    advance(ctx, 9_999)
    assert Repo.get(Seat, first.reply.self_id)
    advance(ctx, 1)
    refute Repo.get(Seat, first.reply.self_id)
  end

  test "handoff waits ten seconds and returning owner immediately reclaims", ctx do
    owner = transport()
    {:ok, owner_reply} = join_seat(ctx, ctx.scope, owner, nil, "Owner")
    first = guest(ctx, "First")
    _second = guest(ctx, "Second")

    assert {:ok, _} =
             control(ctx, ctx.scope, owner, %{"op" => "video", "video_id" => "M7lc1UVf-VE"})

    assert {:ok, _} = control(ctx, ctx.scope, owner, %{"op" => "play"})
    disconnect(ctx.session, owner)
    advance(ctx, 9_999)

    assert {:ok, %{controller_id: nil, playing: true}} =
             Session.request(ctx.session, nil, first.pid, :snapshot)

    assert {:error, :not_controller} = control(ctx, nil, first.pid, %{"op" => "pause"})
    advance(ctx, 1)
    assert {:ok, %{controller_id: id}} = Session.request(ctx.session, nil, first.pid, :snapshot)
    assert id == first.reply.self_id
    assert {:ok, %{playing: false}} = control(ctx, nil, first.pid, %{"op" => "pause"})
    {:ok, returning} = join_seat(ctx, ctx.scope, transport(), nil, "Owner back")
    assert returning.self_id == owner_reply.self_id
    assert returning.snapshot.controller_id == returning.self_id
    assert {:error, :not_controller} = control(ctx, nil, first.pid, %{"op" => "play"})
    assert Repo.get!(Room, ctx.room.id).owner_id == ctx.scope.user.id
  end

  test "an earlier reconnect does not displace the guest controller; succession is immediate",
       ctx do
    owner = transport()
    join_seat(ctx, ctx.scope, owner, nil, "Owner")
    first = guest(ctx, "First")
    second = guest(ctx, "Second")
    disconnect(ctx.session, owner)
    disconnect(ctx.session, first.pid)
    advance(ctx, 10_000)
    {:ok, snapshot} = Session.request(ctx.session, nil, second.pid, :snapshot)
    assert snapshot.controller_id == second.reply.self_id
    new_pid = transport()
    {:ok, rejoined} = join_seat(ctx, nil, new_pid, first.identity, "First returns")
    assert rejoined.snapshot.controller_id == second.reply.self_id
    disconnect(ctx.session, second.pid)
    {:ok, snapshot} = Session.request(ctx.session, nil, new_pid, :snapshot)
    assert snapshot.controller_id == first.reply.self_id
  end

  test "stale revision, authority and epoch cannot mutate playback", ctx do
    owner = transport()
    {:ok, joined} = join_seat(ctx, ctx.scope, owner, nil, "Owner")
    command = command(joined.snapshot, %{"op" => "video", "video_id" => "M7lc1UVf-VE"})

    assert {:error, :stale_epoch} =
             Session.request(
               ctx.session,
               ctx.scope,
               owner,
               {:control, %{command | "epoch" => Ecto.UUID.generate()}}
             )

    assert {:error, :stale_authority} =
             Session.request(
               ctx.session,
               ctx.scope,
               owner,
               {:control, %{command | "authority_revision" => -1}}
             )

    assert {:ok, _} = Session.request(ctx.session, ctx.scope, owner, {:control, command})

    assert {:error, :stale_revision} =
             Session.request(ctx.session, ctx.scope, owner, {:control, command})
  end

  test "durable chat broadcasts after commit and remains after guest expiry", ctx do
    first = guest(ctx, "Original name")

    assert {:ok, message} =
             Session.request(
               ctx.session,
               nil,
               first.pid,
               {:chat, %{"body" => "Durable", "sender_display_name" => "Forged"}}
             )

    assert_receive {pid, {:room_chat_message, %{body: "Durable"}}} when pid == first.pid
    assert message.sender_display_name == "Original name"
    disconnect(ctx.session, first.pid)
    advance(ctx, 30_000)
    new_guest = guest(ctx)

    assert [%{body: "Durable", sender_display_name: "Original name", sender_seat_id: nil}] =
             new_guest.reply.messages

    assert {:ok, [stored]} =
             Session.request(ctx.session, nil, new_guest.pid, :history)

    assert stored.id == message.id
  end

  test "concurrent chat has unique durable room ordering", ctx do
    first = guest(ctx)

    results =
      Task.async_stream(
        1..20,
        fn i ->
          Session.request(ctx.session, nil, first.pid, {:chat, %{body: "Message #{i}"}})
        end,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, {:ok, message}} -> message.sequence end)

    assert Enum.sort(results) == Enum.to_list(1..20)
    assert {:ok, messages} = Store.history(ctx.room.id)
    assert Enum.map(messages, & &1.sequence) == Enum.to_list(1..20)
  end

  test "explicit guest leave immediately releases the seat and access", ctx do
    first = guest(ctx)
    assert {:ok, %{}} = Session.request(ctx.session, nil, first.pid, :leave)
    refute Repo.get(Seat, first.reply.self_id)
    assert {:error, :not_joined} = Session.request(ctx.session, nil, first.pid, :history)

    assert {:error, :not_joined} =
             Session.request(ctx.session, nil, first.pid, {:chat, %{body: "No"}})
  end

  test "signaling reaches conference-ready seats without local devices", ctx do
    first = guest(ctx)
    second = guest(ctx)

    signal = %{
      "epoch" => first.reply.snapshot.epoch,
      "connection_generation" => first.reply.connection_generation,
      "conference_generation" => 1,
      "peer_generation" => 0,
      "to" => second.reply.self_id,
      "to_connection_generation" => second.reply.connection_generation,
      "to_conference_generation" => 1,
      "data" => %{
        "type" => "candidate",
        "negotiation_id" => "test-offer",
        "candidate" => %{"candidate" => "candidate:example"}
      }
    }

    assert {:error, :invalid_signal} =
             Session.request(ctx.session, nil, first.pid, {:signal, signal})

    for guest <- [first, second] do
      assert {:ok, _} =
               Session.request(
                 ctx.session,
                 nil,
                 guest.pid,
                 {:media,
                  %{
                    "epoch" => guest.reply.snapshot.epoch,
                    "connection_generation" => guest.reply.connection_generation,
                    "ready" => true,
                    "microphone" => false,
                    "camera" => false
                  }}
               )
    end

    assert {:ok, %{}} = Session.request(ctx.session, nil, first.pid, {:signal, signal})

    assert_receive {pid, {:room_signal, %{from: from}}}
                   when pid == second.pid and from == first.reply.self_id

    assert {:error, :invalid_signal} =
             Session.request(
               ctx.session,
               nil,
               first.pid,
               {:signal, %{signal | "to" => Ecto.UUID.generate()}}
             )
  end

  test "restart retains room, guest identity and chat, while clearing live authority", ctx do
    first = guest(ctx)
    {:ok, _} = Session.request(ctx.session, nil, first.pid, {:chat, %{body: "Before restart"}})
    old_epoch = first.reply.snapshot.epoch
    stop_supervised!(Session)
    session = start_supervised!({Session, ctx.session_opts})
    ctx = %{ctx | session: session}
    {:ok, rejoined} = join_seat(ctx, nil, transport(), first.identity, "Back")
    assert rejoined.self_id == first.reply.self_id
    assert [%{body: "Before restart"}] = rejoined.messages
    refute rejoined.snapshot.epoch == old_epoch
    assert rejoined.snapshot.controller_id == nil
    assert rejoined.snapshot.playing == false
    assert {:error, :not_joined} = Session.request(session, nil, first.pid, :snapshot)
  end

  test "occupied rooms have no elapsed time cap and owner capacity never expires", ctx do
    first = guest(ctx)
    advance(ctx, 86_400_000 * 30)
    assert {:ok, %{connected_count: 1}} = Session.request(ctx.session, nil, first.pid, :snapshot)

    assert {:ok, %{snapshot: %{connected_count: 2}}} =
             join_seat(ctx, ctx.scope, transport(), nil, "Owner")
  end

  test "disconnect racing with committed closure stops normally", ctx do
    first = guest(ctx)
    ref = Process.monitor(ctx.session)
    assert {:ok, _} = Store.close_room(ctx.scope, ctx.room.id, DateTime.utc_now())
    GenServer.stop(first.pid)
    session = ctx.session
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}
  end

  defp transport do
    start_supervised!(
      Supervisor.child_spec({ReviewProject.RoomsTransport, self()}, id: make_ref())
    )
  end

  defp guest(ctx, name \\ "Guest") do
    pid = transport()
    identity = browser_identity()
    assert {:ok, reply} = join_seat(ctx, nil, pid, identity, name)
    %{pid: pid, identity: identity, reply: reply}
  end

  defp join_seat(ctx, scope, pid, identity, name),
    do: Session.join(ctx.session, scope, identity, ctx.invitation_token, name, pid)

  defp disconnect(session, pid) do
    ref = Process.monitor(pid)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    _ = :sys.get_state(session)
    Session.maintain(session)
  end

  defp advance(ctx, milliseconds) do
    Agent.update(ctx.clock, &(&1 + milliseconds))
    Session.maintain(ctx.session)
  end

  defp control(ctx, scope, pid, operation) do
    {:ok, snapshot} = Session.request(ctx.session, scope, pid, :snapshot)
    Session.request(ctx.session, scope, pid, {:control, command(snapshot, operation)})
  end

  defp command(snapshot, operation),
    do:
      Map.merge(operation, %{
        "epoch" => snapshot.epoch,
        "revision" => snapshot.revision,
        "authority_revision" => snapshot.authority_revision
      })
end
