defmodule ReviewProject.SyncSpikes.MeshTest do
  use ExUnit.Case, async: true
  alias ReviewProject.SyncSpikes.Rooms

  setup do
    rooms = start_supervised!({Rooms, name: nil})
    {:ok, credentials} = Rooms.create(rooms)
    {:ok, "host", _} = Rooms.join(credentials.room_id, credentials.host_token, self(), rooms)
    %{rooms: rooms, id: credentials.room_id}
  end

  defp member(index) do
    start_supervised!(%{
      id: {:member, index},
      start:
        {Task, :start_link,
         [
           fn ->
             receive do
               :stop -> :ok
             end
           end
         ]}
    })
  end

  test "five people including host; departing member frees capacity", ctx do
    guests =
      for index <- 1..4 do
        pid = member(index)
        assert {:ok, "guest", _} = Rooms.join(ctx.id, nil, pid, ctx.rooms)
        assert_receive {:mesh_roster, %{peers: peers}} when length(peers) == index + 1
        pid
      end

    assert {:error, :room_full} = Rooms.join(ctx.id, nil, member(5), ctx.rooms)
    assert {:ok, %{peers: peers}} = Rooms.mesh_state(ctx.id, self(), ctx.rooms)
    assert length(peers) == 5
    assert Enum.count(peers, &(&1.role == "host")) == 1
    first = hd(guests)
    ref = Process.monitor(first)
    send(first, :stop)
    assert_receive {:DOWN, ^ref, :process, ^first, :normal}
    assert_receive {:mesh_roster, %{peers: [_a, _b, _c, _d]}}
    assert {:ok, "guest", _} = Rooms.join(ctx.id, nil, member(6), ctx.rooms)
  end

  test "signaling requires membership, readiness, and a recipient in the same room", ctx do
    other = member(1)
    {:ok, second} = Rooms.create(ctx.rooms)
    {:ok, "guest", _} = Rooms.join(second.room_id, nil, other, ctx.rooms)
    {:ok, %{self_id: target}} = Rooms.mesh_state(ctx.id, self(), ctx.rooms)
    data = %{"type" => "description", "description" => %{"type" => "offer", "sdp" => "research"}}
    signal = %{"to" => target, "data" => data, "from" => "forged"}
    assert {:error, :invalid_signal} = Rooms.signal(ctx.id, other, signal, ctx.rooms)
    assert {:error, :invalid_signal} = Rooms.signal(second.room_id, other, signal, ctx.rooms)
    {:ok, "guest", _} = Rooms.join(ctx.id, nil, other, ctx.rooms)
    assert {:error, :invalid_signal} = Rooms.signal(ctx.id, other, signal, ctx.rooms)
    {:ok, _} = Rooms.media(ctx.id, other, true, ctx.rooms)
    {:ok, _} = Rooms.media(ctx.id, self(), true, ctx.rooms)
    {:ok, %{self_id: sender}} = Rooms.mesh_state(ctx.id, other, ctx.rooms)
    assert {:ok, %{}} = Rooms.signal(ctx.id, other, signal, ctx.rooms)
    assert_receive {:mesh_signal, %{from: ^sender, data: ^data}}

    assert {:error, :invalid_signal} =
             Rooms.signal(ctx.id, other, %{signal | "data" => %{}}, ctx.rooms)

    oversize = put_in(data, ["description", "sdp"], String.duplicate("x", 65_537))

    assert {:error, :invalid_signal} =
             Rooms.signal(ctx.id, other, %{signal | "data" => oversize}, ctx.rooms)
  end

  test "chat uses server identity, trims input, bounds history, and returns it on join", ctx do
    {:ok, %{self_id: author}} = Rooms.mesh_state(ctx.id, self(), ctx.rooms)

    assert {:ok, %{author: ^author, role: "host", body: "<script>hello</script>"}} =
             Rooms.chat(ctx.id, self(), "  <script>hello</script>  ", ctx.rooms)

    assert {:error, :invalid_message} = Rooms.chat(ctx.id, self(), "  ", ctx.rooms)

    assert {:error, :invalid_message} =
             Rooms.chat(ctx.id, self(), String.duplicate("x", 1001), ctx.rooms)

    assert {:error, :invalid_message} = Rooms.chat(ctx.id, member(1), "outside", ctx.rooms)
    for index <- 2..55, do: Rooms.chat(ctx.id, self(), "message #{index}", ctx.rooms)
    guest = member(2)
    {:ok, "guest", _} = Rooms.join(ctx.id, nil, guest, ctx.rooms)
    {:ok, %{chat: messages}} = Rooms.mesh_state(ctx.id, guest, ctx.rooms)
    assert length(messages) == 50
    assert Enum.map(messages, & &1.id) == Enum.to_list(6..55)
  end
end
