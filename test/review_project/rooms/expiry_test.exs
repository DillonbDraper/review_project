defmodule ReviewProject.Rooms.ExpiryTest do
  use ReviewProject.DataCase, async: false
  import ReviewProject.RoomsFixtures
  alias ReviewProject.Rooms
  alias ReviewProject.Rooms.{Expiry, Invitation, Room, Session, Store}

  @three_hours 3 * 60 * 60

  test "creation starts a three-hour deadline and rejects client lifecycle overrides" do
    now = DateTime.utc_now()

    assert {:ok, %{room: room}} =
             Rooms.create_room(owner_scope(), %{
               expires_at: nil,
               expired_at: now,
               closed_at: now
             })

    assert DateTime.diff(room.expires_at, now) in @three_hours..(@three_hours + 1)
    refute room.expired_at
    refute room.closed_at
  end

  test "the final disconnect starts abandonment even while a guest seat is reserved" do
    ctx = room_fixture()
    now = DateTime.utc_now()
    {:ok, %{seat: owner}} = Store.admit(ctx.scope, ctx.room.id, nil, nil, "Host", now)

    {:ok, %{seat: guest}} =
      Store.admit(nil, ctx.room.id, browser_identity(), ctx.invitation_token, "Guest", now)

    assert is_nil(room(ctx).expires_at)
    {:ok, _} = Store.disconnect(ctx.room.id, owner.id, owner.connection_generation, now)
    assert is_nil(room(ctx).expires_at)
    later = DateTime.add(now, 30, :second)
    {:ok, seat} = Store.disconnect(ctx.room.id, guest.id, guest.connection_generation, later)
    assert seat.reserved_until
    assert room(ctx).expires_at == DateTime.add(later, @three_hours, :second)
  end

  test "leave, rejoin and leave again reset only the empty period" do
    ctx = room_fixture()
    now = DateTime.utc_now()

    {:ok, %{seat: guest}} =
      Store.admit(nil, ctx.room.id, browser_identity(), ctx.invitation_token, "Guest", now)

    {:ok, _} = Store.release(ctx.room.id, guest.id, guest.connection_generation, now)
    deadline = room(ctx).expires_at
    assert deadline == DateTime.add(now, @three_hours, :second)

    {:ok, %{seat: host}} =
      Store.admit(ctx.scope, ctx.room.id, nil, nil, "Host", DateTime.add(deadline, -1, :second))

    assert is_nil(room(ctx).expires_at)
    later = DateTime.add(deadline, 60, :second)
    {:ok, _} = Store.release(ctx.room.id, host.id, host.connection_generation, later)
    assert room(ctx).expires_at == DateTime.add(later, @three_hours, :second)
  end

  test "failed admission cannot extend a deadline and the exact boundary rejects admission" do
    ctx = room_fixture()
    deadline = ctx.room.expires_at

    assert {:error, :invalid_invitation} =
             Store.admit(
               nil,
               ctx.room.id,
               browser_identity(),
               "bad",
               "Guest",
               DateTime.add(deadline, -1, :second)
             )

    assert room(ctx).expires_at == deadline

    assert {:error, :room_expired} =
             Store.admit(
               nil,
               ctx.room.id,
               browser_identity(),
               ctx.invitation_token,
               "Guest",
               deadline
             )

    assert {:error, :room_expired} =
             Store.admit(ctx.scope, ctx.room.id, nil, nil, "Host", deadline)

    assert {:error, :room_expired} = Store.recover(ctx.room.id, deadline)
  end

  test "joining cancels a previously selected expiry candidate" do
    ctx = room_fixture()
    deadline = ctx.room.expires_at
    assert ctx.room.id in Store.expired_room_ids(deadline)

    assert {:ok, _} =
             Store.admit(
               ctx.scope,
               ctx.room.id,
               nil,
               nil,
               "Host",
               DateTime.add(deadline, -1, :second)
             )

    assert {:ok, nil} = Store.expire_abandoned_room(ctx.room.id, deadline)
    refute room(ctx).closed_at
  end

  test "expiry commits first and prevents a competing join" do
    ctx = room_fixture()
    assert {:ok, %Room{}} = Store.expire_abandoned_room(ctx.room.id, ctx.room.expires_at)

    assert {:error, :room_expired} =
             Store.admit(ctx.scope, ctx.room.id, nil, nil, "Host", ctx.room.expires_at)

    assert {:ok, nil} = Store.expire_abandoned_room(ctx.room.id, ctx.room.expires_at)
  end

  test "competing join and expiry cannot produce an occupied expired room" do
    ctx = room_fixture()
    deadline = ctx.room.expires_at

    results =
      [:join, :expire]
      |> Task.async_stream(
        fn
          :join ->
            Store.admit(
              ctx.scope,
              ctx.room.id,
              nil,
              nil,
              "Host",
              DateTime.add(deadline, -1, :second)
            )

          :expire ->
            Store.expire_abandoned_room(ctx.room.id, deadline)
        end,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    case results do
      [{:ok, _}, {:ok, nil}] ->
        assert is_nil(room(ctx).expires_at)
        assert is_nil(room(ctx).expired_at)

      [{:error, :room_expired}, {:ok, %Room{}}] ->
        assert room(ctx).expired_at == deadline
    end
  end

  test "scheduled sweep messages expire rooms after the clock advances" do
    ctx = room_fixture()
    clock = start_supervised!({Agent, fn -> DateTime.add(ctx.room.expires_at, -1, :second) end})

    worker =
      start_supervised!(
        {Expiry,
         enabled: true, name: nil, interval: :infinity, clock: fn -> Agent.get(clock, & &1) end}
      )

    _ = :sys.get_state(worker)
    refute room(ctx).closed_at
    Agent.update(clock, fn _ -> ctx.room.expires_at end)
    send(worker, :sweep)
    _ = :sys.get_state(worker)
    assert room(ctx).expired_at == ctx.room.expires_at
  end

  test "worker closes abandoned coordinators, revokes invitations and preserves chat" do
    ctx = live_room()
    assert {:ok, _} = Rooms.send_message(ctx.scope, ctx.room.id, %{body: "Keep this history"})
    assert {:ok, _} = Rooms.request(ctx.scope, ctx.room.id, :leave)
    deadline = room(ctx).expires_at
    assert deadline == DateTime.add(ctx.now, @three_hours, :second)
    session_ref = Process.monitor(ctx.session)
    worker = worker(deadline)
    _ = :sys.get_state(worker)
    assert_receive {:DOWN, ^session_ref, :process, _, :normal}
    assert room(ctx).expired_at == deadline
    assert room(ctx).closed_at == deadline

    assert [%Invitation{revoked_at: ^deadline}] =
             Repo.all(from i in Invitation, where: i.room_id == ^ctx.room.id)

    assert {:ok, [%{body: "Keep this history"}]} = Rooms.list_messages(ctx.scope, ctx.room.id)
    assert {:ok, []} = Expiry.sweep(worker)
    assert {:ok, []} = Rooms.list_rooms(ctx.scope)

    assert {:error, :room_expired} =
             Rooms.join_room(nil, ctx.room.id, browser_identity(), ctx.invitation_token, "Guest")
  end

  test "occupied rooms, including guest-only rooms, survive days of elapsed time" do
    ctx = live_room(:guest)
    worker = worker(DateTime.add(ctx.now, 7, :day))
    assert {:ok, []} = Expiry.sweep(worker)
    refute room(ctx).closed_at
    assert is_nil(room(ctx).expires_at)
    assert {:ok, %{connected_count: 1}} = Rooms.request(nil, ctx.room.id, :snapshot)
  end

  test "empty deadlines survive coordinator and worker restarts without extension" do
    ctx = live_room()
    {:ok, _} = Rooms.request(ctx.scope, ctx.room.id, :leave)
    deadline = room(ctx).expires_at
    stop_supervised!(Session)

    session =
      start_supervised!(
        {Session,
         room_id: ctx.room.id,
         maintenance_interval: :infinity,
         wall_clock: fn -> DateTime.add(deadline, -60, :second) end}
      )

    assert room(ctx).expires_at == deadline
    _ = worker(DateTime.add(deadline, -30, :second))
    stop_supervised!(Expiry)
    ref = Process.monitor(session)
    _ = worker(deadline)
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}
    assert room(ctx).expired_at == deadline
  end

  test "restart reconciliation grants an orphaned occupied room a persisted grace period" do
    ctx = live_room()
    stop_supervised!(Session)
    recovered_at = DateTime.add(ctx.now, 60, :second)
    worker = worker(recovered_at)
    _ = :sys.get_state(worker)
    deadline = DateTime.add(recovered_at, @three_hours, :second)
    assert room(ctx).expires_at == deadline
    stop_supervised!(Expiry)
    _ = worker(DateTime.add(recovered_at, 60, :second))
    assert room(ctx).expires_at == deadline
  end

  test "overdue invitations fail before the sweep and disappear from active rooms" do
    ctx = room_fixture()
    past = DateTime.add(DateTime.utc_now(), -1, :second)
    Repo.update!(Ecto.Changeset.change(ctx.room, expires_at: past))

    assert {:error, :room_expired} =
             Rooms.join_room(nil, ctx.room.id, browser_identity(), ctx.invitation_token, "Guest")

    assert {:ok, []} = Rooms.list_rooms(ctx.scope)
    assert room(ctx).closed_at == nil
  end

  defp room(ctx), do: Repo.get!(Room, ctx.room.id)

  defp worker(now) do
    worker =
      start_supervised!(
        {Expiry, enabled: true, name: nil, interval: :infinity, clock: fn -> now end}
      )

    _ = :sys.get_state(worker)
    worker
  end

  defp live_room(role \\ :host) do
    ctx = room_fixture()
    now = DateTime.utc_now()

    session =
      start_supervised!(
        {Session,
         room_id: ctx.room.id, maintenance_interval: :infinity, wall_clock: fn -> now end}
      )

    scope = if role == :host, do: ctx.scope

    {:ok, _} =
      Rooms.join_room(scope, ctx.room.id, browser_identity(), ctx.invitation_token, "Participant")

    Map.merge(ctx, %{session: session, now: now})
  end
end
