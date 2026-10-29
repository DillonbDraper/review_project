defmodule ReviewProject.Rooms.StoreTest do
  use ReviewProject.DataCase, async: true
  import ReviewProject.RoomsFixtures
  alias ReviewProject.Rooms
  alias ReviewProject.Rooms.{ChatRoomMessage, Invitation, Room, Seat, Store}

  test "room creation authenticates and assigns ownership server-side" do
    assert {:error, :authentication_required} = Rooms.create_room(nil)
    scope = owner_scope()
    other = owner_scope()

    assert {:ok, %{room: room, invitation_token: token}} =
             Rooms.create_room(scope, %{
               "name" => "  Friday night  ",
               "owner_id" => other.user.id,
               "closed_at" => DateTime.utc_now(),
               "next_join_sequence" => 500
             })

    assert room.owner_id == scope.user.id
    assert room.name == "Friday night"
    assert room.closed_at == nil
    assert room.next_join_sequence == 1
    assert [%Seat{slot: 0, join_sequence: 0, display_name: "Host"}] = Repo.all(Seat)
    assert [%Invitation{token_hash: digest}] = Repo.all(Invitation)
    assert digest == :crypto.hash(:sha256, token)
    refute token == digest
  end

  test "invalid metadata and missing owners roll back the entire creation" do
    assert {:error, changeset} =
             Rooms.create_room(owner_scope(), %{name: String.duplicate("x", 121)})

    assert errors_on(changeset).name != []
    assert Repo.aggregate(Room, :count) == 0
    assert Repo.aggregate(Seat, :count) == 0
    assert {:error, changeset} = Rooms.create_room(%{user: %{id: 9_000_000_000}})
    assert errors_on(changeset).owner_id != []
    assert Repo.aggregate(Invitation, :count) == 0
  end

  test "owner lists, metadata and history are scoped" do
    %{scope: scope, room: room} = room_fixture()
    other = owner_scope()
    other_room = room_fixture(other).room
    assert {:ok, [%Room{id: id}]} = Rooms.list_rooms(scope)
    assert id == room.id
    assert {:error, :forbidden} = Rooms.get_room(scope, other_room.id)
    assert {:error, :authentication_required} = Rooms.list_rooms(nil)
    assert {:error, :authentication_required} = Rooms.list_messages(nil, room.id)
    assert {:error, :not_found} = Rooms.get_room(scope, "invalid")
  end

  test "rotation invalidates the old invitation and only the owner can rotate" do
    %{scope: scope, room: room, invitation_token: old} = room_fixture()
    assert {:error, :forbidden} = Rooms.rotate_invitation(owner_scope(), room.id)
    assert {:ok, token} = Rooms.rotate_invitation(scope, room.id)
    refute token == old

    assert {:error, :invalid_invitation} =
             Store.admit(nil, room.id, browser_identity(), old, "Guest", now())

    assert {:ok, _} = Store.admit(nil, room.id, browser_identity(), token, "Guest", now())
    assert Repo.aggregate(from(i in Invitation, where: is_nil(i.revoked_at)), :count) == 1
  end

  test "anonymous and signed-in visitors require invitations, not owner-like names" do
    %{room: room, invitation_token: token} = room_fixture()

    assert {:error, :invalid_invitation} =
             Store.admit(owner_scope(), room.id, browser_identity(), nil, "Host", now())

    assert {:error, :invalid_browser_identity} =
             Store.admit(nil, room.id, "short", token, "Guest", now())

    assert {:ok, %{seat: seat}} =
             Store.admit(nil, room.id, browser_identity(), token, "Host", now())

    assert seat.slot > 0
  end

  test "invalid names do not consume capacity or join sequence" do
    %{room: room, invitation_token: token} = room_fixture()

    for name <- [
          nil,
          "  ",
          "bad\nname",
          String.duplicate("x", 61),
          String.duplicate("e\u0301", 31)
        ] do
      assert {:error, %Ecto.Changeset{}} =
               Store.admit(nil, room.id, browser_identity(), token, name, now())
    end

    assert Repo.get!(Room, room.id).next_join_sequence == 1
    assert Repo.aggregate(Seat, :count) == 1
  end

  test "messages are durable, ordered and attributed from the seat" do
    %{scope: scope, room: room} = room_fixture()
    {:ok, %{seat: seat}} = Store.admit(scope, room.id, nil, nil, "Actual host", now())

    attrs = %{
      "body" => "  Hello  ",
      "sender_display_name" => "Forged",
      "sequence" => 500,
      "room_id" => Ecto.UUID.generate(),
      "sender_seat_id" => Ecto.UUID.generate()
    }

    assert {:ok, message} =
             Store.append_message(room.id, seat.id, seat.connection_generation, attrs)

    assert message.sender_display_name == "Actual host"
    assert message.sender_seat_id == seat.id
    assert message.sequence == 1
    assert message.body == "Hello"
    assert message.room_id == room.id
    assert {:ok, [%ChatRoomMessage{id: id}]} = Rooms.list_messages(scope, room.id)
    assert id == message.id
    assert Repo.get!(Room, room.id).next_chat_sequence == 2
  end

  test "invalid messages and replaced generations cannot consume message sequence" do
    %{scope: scope, room: room} = room_fixture()
    {:ok, %{seat: seat}} = Store.admit(scope, room.id, nil, nil, "Host", now())

    for body <- [
          nil,
          " ",
          "bad\x00body",
          String.duplicate("x", 2_001),
          String.duplicate("e\u0301", 1_001)
        ] do
      assert {:error, %Ecto.Changeset{}} =
               Store.append_message(room.id, seat.id, seat.connection_generation, %{body: body})
    end

    assert {:error, :stale_connection} =
             Store.append_message(room.id, seat.id, seat.connection_generation - 1, %{body: "No"})

    assert Repo.get!(Room, room.id).next_chat_sequence == 1
  end

  test "seat deletion preserves messages and their original sender name" do
    %{scope: scope, room: room, invitation_token: token} = room_fixture()
    {:ok, %{seat: seat}} = Store.admit(nil, room.id, browser_identity(), token, "Guest", now())

    {:ok, message} =
      Store.append_message(room.id, seat.id, seat.connection_generation, %{body: "Remember me"})

    assert {:ok, _} = Store.release(room.id, seat.id, seat.connection_generation, now())
    assert {:ok, [stored]} = Rooms.list_messages(scope, room.id)
    assert stored.id == message.id
    assert stored.sender_seat_id == nil
    assert stored.sender_display_name == "Guest"
  end

  test "history returns the whole conversation in chronological order" do
    %{scope: scope, room: room} = room_fixture()
    {:ok, %{seat: seat}} = Store.admit(scope, room.id, nil, nil, "Host", now())

    for i <- 1..300 do
      assert {:ok, _} =
               Store.append_message(room.id, seat.id, seat.connection_generation, %{
                 body: "Message #{i}"
               })
    end

    assert {:ok, messages} = Rooms.list_messages(scope, room.id)
    assert Enum.map(messages, & &1.sequence) == Enum.to_list(1..300)
  end

  test "closure preserves history and blocks admission, chat and invitation replacement" do
    %{scope: scope, room: room, invitation_token: token} = room_fixture()
    {:ok, %{seat: seat}} = Store.admit(scope, room.id, nil, nil, "Host", now())

    {:ok, message} =
      Store.append_message(room.id, seat.id, seat.connection_generation, %{body: "Last message"})

    assert {:error, :forbidden} = Rooms.close_room(owner_scope(), room.id)
    assert {:ok, %Room{closed_at: %DateTime{}}} = Rooms.close_room(scope, room.id)

    assert {:error, :room_closed} =
             Store.admit(nil, room.id, browser_identity(), token, "Guest", now())

    assert {:error, :room_closed} = Rooms.rotate_invitation(scope, room.id)

    assert {:error, :room_closed} =
             Store.append_message(room.id, seat.id, seat.connection_generation, %{
               body: "Too late"
             })

    assert {:ok, [%{id: id}]} = Rooms.list_messages(scope, room.id)
    assert id == message.id
  end

  test "database prevents cross-room sender attribution" do
    %{room: first} = room_fixture()
    %{room: second} = room_fixture()
    seat = Repo.get_by!(Seat, room_id: first.id, slot: 0)

    changeset =
      ChatRoomMessage.changeset(
        %ChatRoomMessage{
          room_id: second.id,
          sender_seat_id: seat.id,
          sender_display_name: "Host",
          sequence: 1
        },
        %{body: "Forged"}
      )

    assert {:error, changeset} = Repo.insert(changeset)
    assert errors_on(changeset).sender_seat_id != []
  end

  test "database capacity and owner slot constraints reject a sixth slot" do
    %{room: room} = room_fixture()

    changeset =
      Seat.changeset(
        %Seat{
          room_id: room.id,
          slot: 5,
          join_sequence: 1,
          browser_identity_hash: :crypto.strong_rand_bytes(32)
        },
        %{display_name: "Sixth"}
      )

    assert {:error, changeset} = Repo.insert(changeset)
    assert errors_on(changeset).slot != []
  end

  defp now, do: DateTime.utc_now()
end
