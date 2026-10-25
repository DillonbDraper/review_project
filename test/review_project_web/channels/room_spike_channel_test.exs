defmodule ReviewProjectWeb.RoomSpikeChannelTest do
  use ReviewProject.DataCase, async: false
  import Phoenix.ChannelTest
  import ReviewProject.AccountsFixtures
  alias ReviewProject.{Accounts, Accounts.Scope, OwnershipSpikes.Rooms}
  alias ReviewProjectWeb.{RoomSpikeChannel, RoomSpikeSocket}
  @endpoint ReviewProjectWeb.Endpoint

  setup do
    rooms = start_supervised!({Rooms, name: nil})
    owner = users_fixture()
    scope = Scope.for_users(owner)
    token = Accounts.generate_users_session_token(owner)
    {:ok, room} = Rooms.create(scope, rooms)
    %{rooms: rooms, scope: scope, token: token, room: room}
  end

  test "owner account and guest invitation are independently authorized; forged host fields have no effect",
       ctx do
    assert {:ok, %{role: "host"}, host} = join_room(ctx, ctx.scope, ctx.token, "owner", %{})

    assert {:error, %{reason: :invalid_invitation}} =
             join_room(ctx, nil, nil, "forged", %{
               host_token: ctx.room.invitation,
               user_id: ctx.scope.users.id,
               display_name: "Fake host"
             })

    assert {:ok, %{role: "guest", mesh: %{self_id: guest_id}}, guest} =
             join_room(ctx, nil, nil, "guest", %{invitation: ctx.room.invitation, role: "host"})

    ref = push(guest, "control", %{"op" => "play", "revision" => 0, "authority_revision" => 0})
    assert_reply ref, :error, %{reason: :forbidden}
    ref = push(guest, "mesh_chat", %{"body" => "hello", "author" => "forged"})
    assert_reply ref, :ok, %{author: ^guest_id, body: "hello", name: "Researcher"}
    ref = push(host, "snapshot", %{})
    assert_reply ref, :ok, %{access: %{owner_present: true, seat_count: 2}}
    ref = push(guest, "mesh_ice", %{})
    assert_reply ref, :ok, %{mode: "direct"}
  end

  test "revoked owner sessions cannot keep controlling through an existing channel", ctx do
    {:ok, reply, host} = join_room(ctx, ctx.scope, ctx.token, "owner", %{})
    Accounts.delete_users_session_token(ctx.token)

    ref =
      push(host, "control", %{
        "op" => "play",
        "revision" => reply.snapshot.revision,
        "authority_revision" => reply.snapshot.access.authority_revision
      })

    assert_reply ref, :error, %{reason: :session_expired}
  end

  test "moving one browser's seat closes its old channel and retains the seat identity", ctx do
    params = %{invitation: ctx.room.invitation}
    {:ok, %{mesh: %{self_id: id}}, old} = join_room(ctx, nil, nil, "same-browser", params)
    ref = Process.monitor(old.channel_pid)

    assert {:ok, %{mesh: %{self_id: ^id}, snapshot: %{access: %{seat_count: 2}}}, _new} =
             join_room(ctx, nil, nil, "same-browser", params)

    assert_push "seat_replaced", %{reason: "joined_another_tab"}
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}
  end

  defp join_room(ctx, scope, token, browser, params) do
    base =
      socket(RoomSpikeSocket, nil, %{
        current_scope: scope,
        session_token: token,
        browser_identity: browser,
        rooms: ctx.rooms
      })

    subscribe_and_join(
      base,
      RoomSpikeChannel,
      "room_access:#{ctx.room.room_id}",
      Map.merge(%{display_name: "Researcher"}, params)
    )
  end
end
