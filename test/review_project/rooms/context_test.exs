defmodule ReviewProject.Rooms.ContextTest do
  use ReviewProject.DataCase, async: false
  import ReviewProject.RoomsFixtures
  alias ReviewProject.Rooms
  alias ReviewProject.Rooms.Session

  test "public context joins, sends and reads durable messages, then closes the room" do
    %{room: room, scope: scope, invitation_token: token} = room_fixture()
    session = start_supervised!({Session, room_id: room.id})

    assert {:ok, %{self_id: id}} =
             Rooms.join_room(nil, room.id, browser_identity(), token, "Guest")

    assert {:ok, message} = Rooms.send_message(nil, room.id, %{body: "From the context"})
    assert message.sender_seat_id == id
    assert {:ok, [stored]} = Rooms.list_messages(scope, room.id)
    assert stored.id == message.id
    assert {:ok, [public]} = Rooms.request(nil, room.id, :history)
    assert public.id == message.id
    ref = Process.monitor(session)
    assert {:ok, _} = Rooms.close_room(scope, room.id)
    assert_receive {:room_closed, %{reason: :closed}}
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}
    assert {:error, :not_joined} = Rooms.request(nil, room.id, :snapshot)

    assert {:error, :room_closed} =
             Rooms.join_room(nil, room.id, browser_identity(), token, "Guest")

    assert {:ok, [%{sender_display_name: "Guest", sender_seat_id: nil}]} =
             Rooms.list_messages(scope, room.id)
  end

  test "public API fails cleanly for missing rooms and nonmembers" do
    assert {:error, :not_found} =
             Rooms.join_room(nil, "invalid", browser_identity(), "bad", "Guest")

    assert {:error, :not_found} =
             Rooms.join_room(nil, Ecto.UUID.generate(), browser_identity(), "bad", "Guest")

    assert {:error, :not_joined} = Rooms.send_message(nil, Ecto.UUID.generate(), %{body: "No"})
    %{room: room} = room_fixture()
    start_supervised!({Session, room_id: room.id})
    assert {:error, :not_joined} = Rooms.request(nil, room.id, :snapshot, nil)
  end
end
