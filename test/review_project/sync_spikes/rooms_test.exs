defmodule ReviewProject.SyncSpikes.RoomsTest do
  use ExUnit.Case, async: true
  alias ReviewProject.SyncSpikes.Rooms

  setup do
    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, 1000)
    rooms = start_supervised!({Rooms, name: nil, clock: fn -> :atomics.get(clock, 1) end})
    {:ok, credentials} = Rooms.create(rooms)

    {:ok, "host", snapshot} =
      Rooms.join(credentials.room_id, credentials.host_token, self(), rooms)

    %{rooms: rooms, credentials: credentials, snapshot: snapshot, clock: clock}
  end

  test "monotonic timeline advances only while playing; pause and seek are authoritative", ctx do
    id = ctx.credentials.room_id

    assert {:ok, %{revision: 1, position: +0.0, playing: true}} =
             Rooms.control(id, self(), %{"revision" => 0, "op" => "play"}, ctx.rooms)

    :atomics.put(ctx.clock, 1, 4500)
    assert {:ok, %{position: 3.5, revision: 1}} = Rooms.snapshot(id, self(), ctx.rooms)

    assert {:ok, %{position: 3.5, playing: false}} =
             Rooms.control(id, self(), %{"revision" => 1, "op" => "pause"}, ctx.rooms)

    :atomics.put(ctx.clock, 1, 9000)
    assert {:ok, %{position: 3.5}} = Rooms.snapshot(id, self(), ctx.rooms)

    assert {:ok, %{position: 42.0, playing: false, revision: 3}} =
             Rooms.control(
               id,
               self(),
               %{"revision" => 2, "op" => "seek", "position" => 42},
               ctx.rooms
             )
  end

  test "guests cannot change state; credentials and revisions are checked", ctx do
    guest = start_supervised!({Agent, fn -> nil end})
    id = ctx.credentials.room_id
    assert {:ok, "guest", _} = Rooms.join(id, "", guest, ctx.rooms)
    assert {:error, :invalid_host_token} = Rooms.join(id, "forged", guest, ctx.rooms)

    assert {:error, :forbidden} =
             Rooms.control(id, guest, %{"revision" => 0, "op" => "play"}, ctx.rooms)

    assert {:error, :stale_revision} =
             Rooms.control(id, self(), %{"revision" => -1, "op" => "play"}, ctx.rooms)

    assert {:error, :invalid_command} =
             Rooms.control(
               id,
               self(),
               %{"revision" => 0, "op" => "seek", "position" => -1},
               ctx.rooms
             )

    assert {:ok, %{revision: 0}} = Rooms.snapshot(id, self(), ctx.rooms)
  end

  test "late join gets current position and video changes reset the timeline", ctx do
    id = ctx.credentials.room_id
    {:ok, _} = Rooms.control(id, self(), %{"revision" => 0, "op" => "play"}, ctx.rooms)
    :atomics.put(ctx.clock, 1, 11_000)
    guest = start_supervised!({Agent, fn -> nil end})

    assert {:ok, "guest", %{position: 10.0, playing: true, revision: 1}} =
             Rooms.join(id, nil, guest, ctx.rooms)

    assert {:ok, %{position: +0.0, playing: false, video_id: "aqz-KE-bpKQ", revision: 2}} =
             Rooms.control(
               id,
               self(),
               %{"revision" => 1, "op" => "video", "video_id" => "aqz-KE-bpKQ"},
               ctx.rooms
             )

    assert_receive {:playback, %{revision: 2}}
    refute Map.has_key?(ctx.snapshot, :host_token)
    refute Map.has_key?(ctx.snapshot, :token)
  end

  test "monitor cleanup allows the same host credential to reconnect", ctx do
    {:ok, other} = Rooms.create(ctx.rooms)
    member = start_supervised!({Agent, fn -> nil end})
    {:ok, "host", _} = Rooms.join(other.room_id, other.host_token, member, ctx.rooms)
    ref = Process.monitor(member)
    stop_supervised!(Agent)
    assert_receive {:DOWN, ^ref, :process, ^member, :shutdown}
    # Wait for the manager's own DOWN before asserting reconnect eligibility.
    :sys.get_state(ctx.rooms)
    assert {:ok, "host", _} = Rooms.join(other.room_id, other.host_token, self(), ctx.rooms)
  end
end
