defmodule ReviewProjectWeb.Hologram.RoomPanelTest do
  use ReviewProjectWeb.ConnCase, async: true

  import ReviewProject.AccountsFixtures
  import ReviewProject.RoomsFixtures
  alias Hologram.{Component, Server}
  alias ReviewProject.{Accounts, Rooms}
  alias ReviewProjectWeb.Hologram.{ConferencePanel, RoomPanel, RoomUI, UserAuth}

  test "expired rooms explain abandonment rather than attributing closure to the host" do
    assert RoomUI.error(%{reason: "room_expired"}) ==
             "This room has expired after three hours without participants. Create a new room to continue."
  end

  test "creation derives ownership from the verified session and returns a shareable invitation" do
    user = user_fixture()
    server = authenticated(user)

    params = %{
      name: " Movie night ",
      display_name: " Alex ",
      generation: 1,
      operation_id: 1,
      owner_id: 999
    }

    result = RoomPanel.command(:create, params, server).next_action
    assert result.name == :created
    assert result.params.display_name == "Alex"
    assert byte_size(result.params.invitation) >= 40
    assert {:ok, room} = Rooms.get_room(server.stash.current_scope, result.params.room_id)
    assert room.owner_id == user.id
    assert room.name == "Movie night"
  end

  test "commands refuse missing or revoked account sessions" do
    user = user_fixture()
    token = Accounts.generate_user_session_token(user)
    Accounts.delete_user_session_token(token)
    params = %{name: "Party", display_name: "Alex", generation: 1, operation_id: 1}

    for session <- [%{}, %{"user_token" => token}] do
      server = UserAuth.call(%Server{session: session}, :mount_current_scope)
      result = RoomPanel.command(:create, params, server).next_action
      assert result.name == :operation_error
      assert result.params.error.reason == "session_expired"
    end
  end

  test "invalid names return safe errors without creating a room" do
    server = authenticated(user_fixture())

    result =
      RoomPanel.command(
        :create,
        %{name: String.duplicate("a", 121), display_name: "Alex", generation: 1, operation_id: 1},
        server
      ).next_action

    assert result.params.error.reason == "validation"
    assert result.params.error.errors.name != []
    assert {:ok, []} = Rooms.list_rooms(server.stash.current_scope)
  end

  test "only the owner can replace an invitation through a command" do
    fixture = room_fixture()
    params = %{room_id: fixture.room.id, generation: 2, operation_id: 1}

    denied =
      RoomPanel.command(:replace_invitation, params, authenticated(user_fixture())).next_action

    assert denied.params.error.reason == "forbidden"

    accepted =
      RoomPanel.command(:replace_invitation, params, authenticated(fixture.scope.user)).next_action

    assert accepted.name == :invitation_replaced
    refute accepted.params.invitation == fixture.invitation_token
  end

  test "an earlier request timeout cannot affect a later invitation operation" do
    first = RoomPanel.action(:replace_invitation, %{}, joined_component())
    old_timeout = first.next_action.params

    done =
      RoomPanel.action(:invitation_replaced, Map.put(old_timeout, :invitation, "first"), first)

    next = RoomPanel.action(:replace_invitation, %{}, done)
    stale = RoomPanel.action(:operation_timeout, old_timeout, next)
    assert stale.state.busy
    assert stale.state.operation_pending
    timed_out = RoomPanel.action(:operation_timeout, next.next_action.params, next)
    refute timed_out.state.busy
    assert timed_out.state.error =~ "Refresh before trying again"
  end

  test "malformed display names return a safe command error" do
    params = %{name: "Party", display_name: 123, generation: 1, operation_id: 1}
    result = RoomPanel.command(:create, params, authenticated(user_fixture())).next_action
    assert result.params.error.reason == "invalid_display_name"
  end

  test "client state contains only public account fields" do
    server = authenticated(user_fixture())
    component = RoomPanel.init(%{room_id: ""}, %Component{}, server)
    assert component.state.signed_in
    refute Map.has_key?(component.state, :current_scope)
    refute Map.has_key?(component.state, :user)
    refute Map.has_key?(component.state, :user_token)
  end

  test "disconnect requests recovery and invalidates callbacks from the old connection" do
    component = joined_component()
    generation = component.state.generation

    disconnected =
      RoomPanel.action(
        :transport,
        %{generation: generation, type: "lost", result: %{}},
        component
      )

    refute disconnected.state.joined
    assert disconnected.state.busy
    assert disconnected.state.recovering
    assert disconnected.next_action.name == :stopped
    assert disconnected.next_action.target == "conference-panel"
    assert disconnected.next_action.params.mode == "recover"
    continuation = conference_continuation(disconnected.next_action)
    assert continuation.name == :disconnected
    assert continuation.target == "chat-panel"
    assert continuation.params.generation == disconnected.state.generation

    stale =
      RoomPanel.action(
        :transport,
        %{generation: generation, type: "room_ended", result: %{reason: "closed"}},
        disconnected
      )

    assert stale.state == disconnected.state
  end

  test "tab replacement is terminal and does not fight for the seat" do
    component = joined_component()

    ended =
      RoomPanel.action(
        :transport,
        %{
          generation: component.state.generation,
          type: "room_ended",
          result: %{reason: "joined_another_tab"}
        },
        component
      )

    refute ended.state.joined
    refute ended.state.busy
    assert ended.state.status =~ "another tab"
    assert ended.next_action.name == :stopped
    assert ended.next_action.params.mode == "stop"
    assert conference_continuation(ended.next_action).name == :reset
    stale_retry = RoomPanel.action(:retry, %{generation: component.state.generation}, ended)
    assert stale_retry.state == ended.state
  end

  test "a session check after logout ends authenticated membership" do
    component = joined_component()

    result =
      RoomPanel.action(
        :session_result,
        %{
          generation: component.state.generation,
          status: "ok",
          result: %{signed_in: false, csrf_token: "csrf"}
        },
        component
      )

    refute result.state.busy
    assert result.state.status =~ "sign-in expired"
  end

  test "a temporary session failure retries while an insecure origin explains the requirement" do
    component = joined_component()

    retry =
      RoomPanel.action(
        :session_result,
        %{generation: component.state.generation, status: "unavailable"},
        component
      )

    assert retry.next_action.name == :retry
    assert retry.next_action.delay == 1500

    insecure =
      RoomPanel.action(
        :session_result,
        %{generation: component.state.generation, status: "insecure"},
        component
      )

    refute insecure.state.busy
    assert insecure.state.error =~ "HTTPS or localhost"
  end

  test "name validation and invitation construction run in Elixir" do
    assert {:ok, "Alex"} = RoomUI.display_name(" Alex ")
    assert {:ok, _} = RoomUI.display_name(String.duplicate("😀", 60))

    for invalid <- [" ", "na\nme", String.duplicate("x", 61), "name" <> <<0>>] do
      assert {:error, _} = RoomUI.display_name(invalid)
    end

    assert RoomUI.invitation_url("https://host:4001", "room", "a+b=") ==
             "https://host:4001/rooms/room#invitation=a%2Bb%3D"

    assert RoomUI.invitation_url("https://host", "room", "") == ""
  end

  test "admission starts the conference directly and preserves chat activation" do
    component = joined_component()
    component = Component.put_state(component, joined: false, recovering: true)

    joined =
      RoomPanel.action(
        :transport,
        %{
          generation: component.state.generation,
          type: "joined",
          result: %{
            self_id: "host",
            connection_generation: 3,
            snapshot: snapshot(),
            messages: []
          }
        },
        component
      )

    assert joined.state.joined
    refute joined.state.recovering
    action = joined.next_action
    assert action.target == "conference-panel"
    assert action.name == :joined
    assert action.params.generation == joined.state.conference_generation
    assert action.params.connection_generation == 3
    assert action.params.resume
    assert action.params.snapshot == snapshot()
    chat = conference_continuation(action)
    assert chat.name == :activate
    assert chat.target == "chat-panel"
    assert chat.params.self_id == "host"
    assert chat.params.messages == []
    assert chat.params.room_generation == joined.state.generation
  end

  test "roster, signals, and pair resets target the conference for the current room connection" do
    component = joined_component()

    for {type, result, event, key} <- [
          {"room_state", snapshot(), :roster, :snapshot},
          {"conference_signal", %{from: "guest", data: %{}}, :signal, :signal},
          {"conference_peer", %{from: "guest", peer_generation: 2}, :peer_reset, :peer}
        ] do
      params = %{generation: component.state.generation, type: type, result: result}
      updated = RoomPanel.action(:transport, params, component)
      action = updated.next_action
      assert action.target == "conference-panel"
      assert action.name == event
      assert action.params[key] == result
      assert action.params.generation == component.state.conference_generation

      stale =
        RoomPanel.action(:transport, %{params | generation: params.generation - 1}, component)

      assert stale == component

      unjoined = Component.put_state(component, joined: false)
      assert RoomPanel.action(:transport, params, unjoined) == unjoined
    end
  end

  test "snapshot delivery updates the conference without dropping the next room poll" do
    component = joined_component()

    updated =
      RoomPanel.action(
        :snapshot,
        %{generation: component.state.generation, status: "ok", result: snapshot()},
        component
      )

    assert updated.next_action.name == :roster
    assert updated.next_action.params.snapshot == snapshot()
    poll = conference_continuation(updated.next_action)
    assert poll.name == :poll
    assert poll.target == "room-controls"
    assert poll.delay == 15_000
    assert poll.params.generation == updated.state.generation
  end

  test "leaving clears conference intent before a server acknowledgement arrives" do
    component = joined_component()
    leaving = RoomPanel.action(:leave, %{}, component)
    assert leaving.state.busy
    assert leaving.next_action.name == :stopped
    assert leaving.next_action.params.mode == "stop"
    assert leaving.next_action.params.generation > component.state.conference_generation
  end

  test "either leave confirmation clears the session before returning home" do
    component = RoomPanel.action(:leave, %{}, joined_component())
    generation = component.state.generation

    for {action, params} <- [
          {:left, %{generation: generation, status: "ok"}},
          {:transport, %{generation: generation, type: "room_ended", result: %{reason: "left"}}}
        ] do
      left = RoomPanel.action(action, params, component)
      refute left.state.joined
      refute left.state.busy
      assert left.state.participants == []
      assert left.state.generation > generation
      assert left.next_action.name == :stopped
      assert left.next_action.params.mode == "stop"
      reset = conference_continuation(left.next_action)
      assert reset.name == :reset
      assert reset.target == "chat-panel"

      stale = RoomPanel.action(:left, %{generation: generation, status: "ok"}, left)
      assert stale == left
    end
  end

  test "a failed leave keeps the session available to retry" do
    leaving = RoomPanel.action(:leave, %{}, joined_component())

    failed =
      RoomPanel.action(:left, %{generation: leaving.state.generation, status: "error"}, leaving)

    assert failed.state.joined
    refute failed.state.busy
    assert failed.state.error != ""
    assert failed.state.generation == leaving.state.generation
  end

  test "a restored page clears the call before restoring chat and advances its saved resource epoch" do
    component = Component.put_state(joined_component(), conference_generation: 500)
    mounted = RoomPanel.action(:room_mounted, %{}, component)
    refute mounted.state.joined
    refute mounted.state.recovering
    assert mounted.next_action.name == :stopped
    assert mounted.next_action.params.mode == "stop"
    assert mounted.next_action.params.generation > 500
    reset = conference_continuation(mounted.next_action)
    assert reset.name == :reset
    assert reset.target == "chat-panel"
    assert reset.params.resume
  end

  defp conference_continuation(action) do
    component = ConferencePanel.init(%{}, %Component{}, %Server{})
    updated = ConferencePanel.action(action.name, action.params, component)
    assert updated.next_action.name == :sync_tiles
    next = updated.next_action
    continuation = ConferencePanel.action(next.name, next.params, updated).next_action
    assert continuation.target == "video-panel"
    video = ReviewProjectWeb.Hologram.VideoPanel.init(%{room_id: "room"}, %Component{}, %Server{})

    ReviewProjectWeb.Hologram.VideoPanel.action(continuation.name, continuation.params, video).next_action
  end

  defp snapshot do
    %{
      room_name: "Movie night",
      epoch: "epoch",
      roster_revision: 1,
      revision: 1,
      authority_revision: 1,
      controller_id: "host",
      video_id: nil,
      playing: false,
      position: 0,
      server_time_ms: 0,
      seats: [],
      connected_count: 1,
      seat_count: 1
    }
  end

  defp authenticated(user) do
    token = Accounts.generate_user_session_token(user)
    UserAuth.call(%Server{session: %{"user_token" => token}}, :mount_current_scope)
  end

  defp joined_component do
    component = RoomPanel.init(%{room_id: Ecto.UUID.generate()}, %Component{}, %Server{})

    %{
      component
      | state:
          Map.merge(component.state, %{
            joined: true,
            busy: false,
            generation: 2,
            authenticated: true,
            self_id: "host",
            display_name: "Alex"
          })
    }
  end
end
