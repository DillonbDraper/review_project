defmodule ReviewProjectWeb.RoomChatChannelTest do
  use ReviewProject.DataCase, async: false

  import Phoenix.ChannelTest
  import ReviewProject.RoomsFixtures
  alias ReviewProject.Rooms
  alias ReviewProject.Rooms.Session
  alias ReviewProjectWeb.{RoomChannel, RoomSocket}

  @endpoint ReviewProjectWeb.Endpoint

  setup do
    fixture = room_fixture()
    start_supervised!({Session, room_id: fixture.room.id})
    fixture
  end

  test "committed chat is acknowledged, broadcast to both participants and stored with trusted attribution",
       ctx do
    {:ok, %{self_id: sender}, host} = join_room(ctx, ctx.scope, "Alex")
    {:ok, _, _guest} = join_room(ctx, nil, "Sam")
    body = "<script>A shared thought</script>"

    ref =
      push(host, "chat_send", %{
        "body" => "  #{body}  ",
        "sender_display_name" => "Forged",
        "sender_seat_id" => Ecto.UUID.generate()
      })

    assert_reply ref, :ok, %{
      id: id,
      sender_display_name: "Alex",
      sender_seat_id: ^sender,
      body: ^body,
      sequence: 1
    }

    assert_push "chat_message", %{id: ^id, body: ^body}
    assert_push "chat_message", %{id: ^id, body: ^body}
    assert {:ok, [stored]} = Rooms.list_messages(ctx.scope, ctx.room.id)
    assert stored.id == id
    assert stored.sender_display_name == "Alex"
  end

  test "late join and history refresh return the whole ordered conversation", ctx do
    {:ok, _, host} = join_room(ctx, ctx.scope, "Alex")

    for i <- 1..300 do
      ref = push(host, "chat_send", %{"body" => "Message #{i}"})
      assert_reply ref, :ok, %{sequence: ^i}
    end

    {:ok, %{messages: messages}, guest} = join_room(ctx, nil, "Late guest")
    assert Enum.map(messages, & &1.sequence) == Enum.to_list(1..300)
    ref = push(guest, "chat_history", %{})
    assert_reply ref, :ok, history
    assert Enum.map(history, & &1.sequence) == Enum.to_list(1..300)
  end

  test "blank, oversized and null-containing messages fail without writing history", ctx do
    {:ok, _, guest} = join_room(ctx, nil, "Guest")

    for body <- ["  \n ", String.duplicate("a", 2001), "not\0text"] do
      ref = push(guest, "chat_send", %{"body" => body})
      assert_reply ref, :error, %{reason: "validation", errors: %{body: [_ | _]}}
    end

    ref = push(guest, "chat_history", %{})
    assert_reply ref, :ok, []
    body = String.duplicate("😀", 2000)
    ref = push(guest, "chat_send", %{"body" => body})
    assert_reply ref, :ok, %{body: ^body}
  end

  test "chat always uses the joined room and cannot read or write a supplied room ID", ctx do
    other = room_fixture()
    start_supervised!(Supervisor.child_spec({Session, room_id: other.room.id}, id: other.room.id))
    {:ok, _, first} = join_room(ctx, nil, "First")
    {:ok, _, second} = join_room(other, nil, "Second")

    ref =
      push(first, "chat_send", %{"body" => "Private to first room", "room_id" => other.room.id})

    assert_reply ref, :ok, %{room_id: id}
    assert id == ctx.room.id
    ref = push(second, "chat_history", %{"room_id" => ctx.room.id})
    assert_reply ref, :ok, []
    assert {:ok, []} = Rooms.list_messages(other.scope, other.room.id)
  end

  test "a replacement seat gets history but its old transport loses chat access", ctx do
    identity = browser_identity()
    {:ok, %{self_id: seat}, old} = join_room(ctx, nil, "Original name", identity)
    ref = push(old, "chat_send", %{"body" => "Before replacement"})
    assert_reply ref, :ok, %{id: id}

    assert {:ok, %{self_id: ^seat, messages: [%{id: ^id, sender_display_name: "Original name"}]},
            _} =
             join_room(ctx, nil, "New name", identity)

    assert {:error, :not_joined} =
             Rooms.send_message(nil, ctx.room.id, %{body: "Stale"}, old.channel_pid)
  end

  defp join_room(ctx, scope, name, identity \\ browser_identity()) do
    token = if scope, do: ReviewProject.Accounts.generate_user_session_token(scope.user)
    assigns = %{current_scope: scope, session_token: token, browser_identity: identity}

    subscribe_and_join(socket(RoomSocket, nil, assigns), RoomChannel, "room:#{ctx.room.id}", %{
      invitation: ctx.invitation_token,
      display_name: name
    })
  end
end
