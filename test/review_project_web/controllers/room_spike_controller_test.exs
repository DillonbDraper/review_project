defmodule ReviewProjectWeb.RoomSpikeControllerTest do
  use ReviewProjectWeb.ConnCase, async: true
  import ReviewProject.AccountsFixtures
  alias ReviewProject.OwnershipSpikes.Rooms

  test "sign-in remembers the spike invitation and ICE mode", %{conn: conn} do
    destination = "/dev/spikes/room-access/room/room-id/invitation-token?ice=relay-tls"
    conn = get(conn, "/dev/spikes/room-access/sign-in", return_to: destination)
    assert redirected_to(conn) == "/users/log-in"
    assert get_session(conn, :users_return_to) == destination
  end

  test "sign-in defaults to this spike and rejects unrelated or external destinations", %{
    conn: conn
  } do
    for destination <- [
          nil,
          "https://example.com",
          "//example.com",
          "/users/settings",
          "/dev/spikes/room-access/../users",
          "/dev/spikes/room-access?ice=auto&next=//example.com",
          "/dev/spikes/room-access\\example.com",
          "/dev/spikes/room-access/room/%2f/token"
        ] do
      params = if destination, do: %{return_to: destination}, else: %{}
      response = get(conn, "/dev/spikes/room-access/sign-in", params)
      assert redirected_to(response) == "/users/log-in"
      assert get_session(response, :users_return_to) == "/dev/spikes/room-access"
    end
  end

  test "an already signed-in owner returns immediately without another login", %{conn: conn} do
    destination = "/dev/spikes/room-access?ice=auto"

    conn =
      conn
      |> log_in_users(users_fixture())
      |> get("/dev/spikes/room-access/sign-in", return_to: destination)

    assert redirected_to(conn) == destination
  end

  test "password login returns to the spike and its bootstrap recognizes the account", %{
    conn: conn
  } do
    user = users_fixture() |> set_password()
    conn = get(conn, "/dev/spikes/room-access/sign-in")

    conn =
      conn
      |> recycle()
      |> post("/users/log-in", %{
        "users" => %{"email" => user.email, "password" => valid_users_password()}
      })

    assert redirected_to(conn) == "/dev/spikes/room-access"

    conn = conn |> recycle() |> get("/dev/spikes/room-access/session")
    assert %{"signed_in" => true, "email" => email} = json_response(conn, 200)
    assert email == user.email
    identity = get_session(conn, :room_spike_identity)
    conn = conn |> recycle() |> get("/dev/spikes/room-access/session")
    assert %{"signed_in" => true, "email" => ^email} = json_response(conn, 200)
    assert get_session(conn, :room_spike_identity) == identity
  end

  test "email confirmation returns a newly registered owner to the invitation", %{conn: conn} do
    user = unconfirmed_users_fixture()
    {token, _} = generate_users_magic_link_token(user)
    destination = "/dev/spikes/room-access/room/room-id/invitation-token?ice=auto"
    conn = get(conn, "/dev/spikes/room-access/sign-in", return_to: destination)

    conn =
      conn
      |> recycle()
      |> post("/users/log-in?_action=confirmed", %{"users" => %{"token" => token}})

    assert redirected_to(conn) == destination
    conn = conn |> recycle() |> get("/dev/spikes/room-access/session")
    assert %{"signed_in" => true, "email" => email} = json_response(conn, 200)
    assert email == user.email
  end

  test "guests receive a stable browser identity and CSRF token but cannot create rooms", %{
    conn: conn
  } do
    first = get(conn, "/dev/spikes/room-access/session")
    assert %{"csrf_token" => token, "signed_in" => false} = json_response(first, 200)
    assert is_binary(token)
    assert first |> get_resp_header("cache-control") == ["no-store"]
    identity = get_session(first, :room_spike_identity)
    assert is_binary(identity)
    second = first |> recycle() |> get("/dev/spikes/room-access/session")
    assert get_session(second, :room_spike_identity) == identity
    refused = second |> recycle() |> post("/dev/spikes/room-access/rooms", %{owner_id: 999})
    assert redirected_to(refused) == "/users/log-in"
  end

  test "creation takes ownership from the authenticated scope, ignoring forged owner IDs", %{
    conn: conn
  } do
    rooms = start_supervised!({Rooms, []})
    user = users_fixture()
    conn = conn |> log_in_users(user) |> post("/dev/spikes/room-access/rooms", %{owner_id: 999})
    assert %{"room_id" => id, "invitation" => invitation} = json_response(conn, 200)
    assert is_binary(invitation)
    assert :sys.get_state(rooms).rooms[id].owner_id == user.id
  end
end
