defmodule ReviewProject.OwnershipSpikes.RoomsTest do
  use ExUnit.Case, async: true
  alias ReviewProject.Accounts.Scope
  alias ReviewProject.OwnershipSpikes.Rooms

  setup do
    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, 1000)
    rooms = start_supervised!({Rooms, name: nil, clock: fn -> :atomics.get(clock, 1) end})
    scope = %Scope{user: %{id: 123}}
    {:ok, room} = Rooms.create(scope, rooms)
    host = peer()
    {:ok, reply} = join(%{rooms: rooms, room: room}, scope, "host-browser", host)
    %{rooms: rooms, room: room, scope: scope, host: host, initial: reply, clock: clock}
  end

  test "accountless invitation guests cannot become owner or control the connected host", ctx do
    guest = peer()

    assert {:error, :invalid_invitation} =
             Rooms.join(nil, ctx.room.room_id, "guest", "forged", "Guest", guest.pid, ctx.rooms)

    assert {:ok, %{role: "guest"} = reply} = join(ctx, nil, "guest", guest)
    assert reply.snapshot.access.owner_identity == ctx.initial.mesh.self_id
    assert {:error, :forbidden} = command(ctx, nil, guest, reply.snapshot, "pause")
    assert {:error, :authentication_required} = Rooms.create(nil, ctx.rooms)
    assert :sys.get_state(ctx.rooms).rooms[ctx.room.room_id].owner_id == 123
    refute Map.has_key?(reply.snapshot.access, :owner_id)
  end

  test "handoff waits ten seconds, picks earliest connected guest, and preserves playing timeline",
       ctx do
    first = peer()
    second = peer()
    {:ok, a} = join(ctx, nil, "first", first)
    {:ok, _b} = join(ctx, nil, "second", second)
    {:ok, playing} = command(ctx, ctx.scope, ctx.host, ctx.initial.snapshot, "play")
    assert playing.playing
    disconnect(ctx, ctx.host)
    advance(ctx, 10_999)
    {:ok, waiting} = request(ctx, nil, first, :snapshot)
    assert waiting.access.controller_identity == nil
    assert waiting.position == 9.999
    assert {:error, :forbidden} = command(ctx, nil, first, waiting, "pause")
    advance(ctx, 11_000)
    {:ok, handed} = request(ctx, nil, first, :snapshot)
    assert handed.access.controller_identity == a.mesh.self_id
    assert handed.position == 10.0
    assert handed.playing
    assert {:ok, %{playing: false}} = command(ctx, nil, first, handed, "pause")
  end

  test "owner return before grace cancels handoff; return after handoff revokes the guest immediately",
       ctx do
    guest = peer()
    {:ok, _} = join(ctx, nil, "guest", guest)
    disconnect(ctx, ctx.host)
    advance(ctx, 5000)
    returned = peer()
    {:ok, early} = join(ctx, ctx.scope, "other-owner-browser", returned)
    assert early.mesh.self_id == ctx.initial.mesh.self_id
    assert early.snapshot.access.controller_identity == early.mesh.self_id
    disconnect(ctx, returned)
    advance(ctx, 15_000)
    {:ok, handed} = request(ctx, nil, guest, :snapshot)
    assert {:ok, _} = command(ctx, nil, guest, handed, "pause")
    returned_again = peer()
    {:ok, back} = join(ctx, ctx.scope, "host-browser", returned_again)
    assert back.snapshot.access.controller_identity == ctx.initial.mesh.self_id
    assert {:error, :forbidden} = command(ctx, nil, guest, handed, "play")

    assert {:error, :stale_authority} =
             command(ctx, ctx.scope, returned_again, ctx.initial.snapshot, "play")

    assert :sys.get_state(ctx.rooms).rooms[ctx.room.room_id].owner_id == 123
  end

  test "controller disconnect elects the next connected guest; an earlier reconnect does not steal control",
       ctx do
    first = peer()
    second = peer()
    {:ok, a} = join(ctx, nil, "first", first)
    {:ok, b} = join(ctx, nil, "second", second)
    disconnect(ctx, ctx.host)
    advance(ctx, 11_000)
    disconnect(ctx, first)
    {:ok, chosen} = request(ctx, nil, second, :snapshot)
    assert chosen.access.controller_identity == b.mesh.self_id
    reconnect = peer()
    {:ok, rejoined} = join(ctx, nil, "first", reconnect)
    assert rejoined.mesh.self_id == a.mesh.self_id
    assert rejoined.snapshot.access.controller_identity == b.mesh.self_id
  end

  test "one browser seat moves across tabs and the old transport loses all permissions", ctx do
    old = peer()
    replacement = peer()
    {:ok, original} = join(ctx, nil, "one-browser", old)
    {:ok, moved} = join(ctx, nil, "one-browser", replacement)
    assert moved.mesh.self_id == original.mesh.self_id
    assert moved.snapshot.access.seat_count == 2
    assert {:error, :not_joined} = request(ctx, nil, old, {:chat, "stale"})
    assert {:error, :not_joined} = request(ctx, nil, old, {:media, true})
    disconnect(ctx, old)
    {:ok, still_joined} = request(ctx, nil, replacement, :snapshot)
    assert still_joined.access.connected_count == 2
  end

  test "guest reservations enforce five seats, retain identity for thirty seconds, then release",
       ctx do
    guests =
      for n <- 1..4 do
        p = peer()
        {:ok, reply} = join(ctx, nil, "guest-#{n}", p)
        {p, reply}
      end

    extra = peer()
    assert {:error, :room_full} = join(ctx, nil, "extra", extra)
    {first, reply} = hd(guests)
    disconnect(ctx, first)
    advance(ctx, 30_999)
    assert {:error, :room_full} = join(ctx, nil, "extra", extra)
    restored = peer()
    assert {:ok, restored_reply} = join(ctx, nil, "guest-1", restored)
    assert restored_reply.mesh.self_id == reply.mesh.self_id
    disconnect(ctx, restored)
    advance(ctx, 60_999)
    assert {:ok, admitted} = join(ctx, nil, "extra", extra)
    assert admitted.snapshot.access.seat_count == 5
    assert length(admitted.mesh.peers) == 5
  end

  test "owner can return to four guests after being away beyond the reservation window", ctx do
    guest = peer()
    {:ok, _} = join(ctx, nil, "guest-1", guest)
    disconnect(ctx, ctx.host)
    advance(ctx, 70_000)
    for n <- 2..4, do: assert({:ok, _} = join(ctx, nil, "guest-#{n}", peer()))
    assert {:error, :room_full} = join(ctx, nil, "guest-5", peer())

    assert {:ok, %{role: "host", snapshot: %{access: %{seat_count: 5}}}} =
             join(ctx, ctx.scope, "host", peer())
  end

  test "a request that reaches the handoff deadline broadcasts the new authority", ctx do
    myself = %{pid: self()}
    {:ok, guest} = join(ctx, nil, "observing-guest", myself)
    disconnect(ctx, ctx.host)
    :atomics.put(ctx.clock, 1, 11_000)
    {:ok, handed} = request(ctx, nil, myself, :snapshot)
    id = guest.mesh.self_id
    assert handed.access.controller_identity == id
    assert_receive {:playback, %{access: %{controller_identity: ^id}}}
  end

  test "mesh and chat use server member identities and reject cross-room targets", ctx do
    guest = peer()
    {:ok, joined} = join(ctx, nil, "guest", guest)
    {:ok, _} = request(ctx, nil, guest, {:media, true})
    {:ok, _} = request(ctx, ctx.scope, ctx.host, {:media, true})

    signal = %{
      "to" => ctx.initial.mesh.self_id,
      "from" => "forged",
      "data" => %{"type" => "candidate", "candidate" => %{"candidate" => "test"}}
    }

    assert {:ok, %{}} = request(ctx, nil, guest, {:signal, signal})

    assert {:error, :invalid_signal} =
             request(ctx, nil, guest, {:signal, %{signal | "to" => "another-room"}})

    assert {:ok, %{author: id, name: "Guest", body: "hello"}} =
             request(ctx, nil, guest, {:chat, " hello "})

    assert id == joined.mesh.self_id
  end

  defp peer do
    id = make_ref()
    pid = start_supervised!(Supervisor.child_spec({Agent, fn -> nil end}, id: id))
    %{id: id, pid: pid}
  end

  defp join(ctx, scope, browser, peer),
    do:
      Rooms.join(
        scope,
        ctx.room.room_id,
        browser,
        ctx.room.invitation,
        "Guest",
        peer.pid,
        ctx.rooms
      )

  defp request(ctx, scope, peer, op),
    do: Rooms.request(scope, ctx.room.room_id, peer.pid, op, ctx.rooms)

  defp command(ctx, scope, peer, snapshot, op),
    do:
      request(
        ctx,
        scope,
        peer,
        {:control,
         %{
           "op" => op,
           "revision" => snapshot.revision,
           "authority_revision" => snapshot.access.authority_revision
         }}
      )

  defp disconnect(ctx, peer) do
    ref = Process.monitor(peer.pid)
    stop_supervised!(peer.id)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}
    _ = :sys.get_state(ctx.rooms)
  end

  defp advance(ctx, time) do
    :atomics.put(ctx.clock, 1, time)
    send(ctx.rooms, :maintain)
    _ = :sys.get_state(ctx.rooms)
  end
end
