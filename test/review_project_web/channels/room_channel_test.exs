defmodule ReviewProjectWeb.RoomChannelTest do
  use ReviewProject.DataCase, async: false

  import Phoenix.ChannelTest
  import ReviewProject.RoomsFixtures
  alias ReviewProject.{Accounts, Rooms}
  alias ReviewProject.Rooms.Session
  alias ReviewProjectWeb.{RoomChannel, RoomSocket}

  @endpoint ReviewProjectWeb.Endpoint

  setup do
    fixture = room_fixture()
    session = start_supervised!({Session, room_id: fixture.room.id})
    Map.put(fixture, :session, session)
  end

  test "host and anonymous invitation guests join the durable room", ctx do
    assert {:ok, %{snapshot: %{room_name: "Watch party"}}, _host} = join_room(ctx, ctx.scope)
    assert {:ok, %{self_id: id, snapshot: snapshot}, guest} = join_room(ctx)
    assert snapshot.connected_count == 2
    assert Enum.any?(snapshot.seats, &(&1.id == id and &1.display_name == "Guest"))
    refute Map.has_key?(snapshot, :owner_id)
    ref = push(guest, "snapshot", %{})
    assert_reply ref, :ok, %{connected_count: 2}
  end

  test "forged ownership and bad invitations cannot bypass admission", ctx do
    assert {:error, %{reason: "invalid_invitation"}} =
             join_room(ctx, nil, browser_identity(), %{
               invitation: "bad",
               role: "owner",
               owner_id: ctx.scope.user.id
             })

    assert {:error, %{reason: "validation", errors: %{display_name: [_]}}} =
             join_room(ctx, nil, browser_identity(), %{display_name: "  "})

    assert {:error, %{reason: "not_found"}} =
             subscribe_and_join(
               socket(RoomSocket, nil, guest_assigns()),
               RoomChannel,
               "room:invalid",
               %{}
             )
  end

  test "four guest seats preserve the owner's place", ctx do
    for _ <- 1..4, do: assert({:ok, _, _} = join_room(ctx))
    assert {:error, %{reason: "room_full"}} = join_room(ctx)
    assert {:ok, %{snapshot: %{connected_count: 5}}, _} = join_room(ctx, ctx.scope)
  end

  test "moving a browser seat stops its old channel and explicit leave releases it", ctx do
    identity = browser_identity()
    {:ok, %{self_id: id}, old} = join_room(ctx, nil, identity)
    ref = Process.monitor(old.channel_pid)
    assert {:ok, %{self_id: ^id}, replacement} = join_room(ctx, nil, identity)
    assert_push "room_ended", %{reason: "joined_another_tab"}
    assert_receive {:DOWN, ^ref, :process, _, _}

    ref = push(replacement, "leave", %{})
    assert_reply ref, :ok, %{}
    assert {:ok, %{self_id: new_id}, _} = join_room(ctx, nil, identity)
    refute new_id == id
  end

  test "invitation replacement rejects old links without removing connected guests", ctx do
    {:ok, _, guest} = join_room(ctx)
    assert {:ok, new_token} = Rooms.rotate_invitation(ctx.scope, ctx.room.id)
    ref = push(guest, "snapshot", %{})
    assert_reply ref, :ok, %{}
    assert {:error, %{reason: "invalid_invitation"}} = join_room(ctx)
    assert {:ok, _, _} = join_room(ctx, nil, browser_identity(), %{invitation: new_token})
  end

  test "coordinator death ends stale membership and requests a fresh client join", ctx do
    {:ok, _, guest} = join_room(ctx)
    ref = Process.monitor(guest.channel_pid)
    stop_supervised!(Session)
    assert_push "room_restart", %{}
    assert_receive {:DOWN, ^ref, :process, _, _}
  end

  test "revoked account sessions cannot use an existing channel", ctx do
    {:ok, _, host} = join_room(ctx, ctx.scope)
    Accounts.delete_user_session_token(host.assigns.session_token)
    ref = push(host, "snapshot", %{})
    assert_reply ref, :error, %{reason: "session_expired"}
    assert_push "room_ended", %{reason: "session_expired"}
  end

  defp join_room(ctx, scope \\ nil, identity \\ browser_identity(), params \\ %{}) do
    token = if scope, do: Accounts.generate_user_session_token(scope.user)
    assigns = %{current_scope: scope, session_token: token, browser_identity: identity}

    subscribe_and_join(
      socket(RoomSocket, nil, assigns),
      RoomChannel,
      "room:#{ctx.room.id}",
      Map.merge(
        %{invitation: ctx.invitation_token, display_name: if(scope, do: "Host", else: "Guest")},
        params
      )
    )
  end

  defp guest_assigns,
    do: %{current_scope: nil, session_token: nil, browser_identity: browser_identity()}
end
