defmodule ReviewProjectWeb.RoomControllerTest do
  use ReviewProjectWeb.ConnCase, async: true

  import ReviewProject.RoomsFixtures

  test "session bootstrap reuses a secret browser identity without returning it", %{conn: conn} do
    first = get(conn, "/room-session")
    assert %{"csrf_token" => csrf, "signed_in" => false} = json_response(first, 200)
    identity = get_session(first, :room_browser_identity)
    assert byte_size(Base.url_decode64!(identity)) == 32
    assert Plug.CSRFProtection.valid_state_and_csrf_token?(get_session(first, :_csrf_token), csrf)
    refute Map.has_key?(json_response(first, 200), "browser_identity")
    assert get_resp_header(first, "cache-control") == ["no-store"]
    second = first |> recycle() |> get("/room-session")
    assert get_session(second, :room_browser_identity) == identity
  end

  test "login returns to the workspace or a local room, never an external URL", %{conn: conn} do
    destination = "/rooms/#{Ecto.UUID.generate()}"
    response = get(conn, "/room-sign-in", return_to: destination)
    assert redirected_to(response) == "/users/log-in"
    assert get_session(response, :user_return_to) == destination

    for destination <- [
          "https://example.com",
          "//example.com",
          "/users/settings",
          "/rooms/../users"
        ] do
      response = get(conn, "/room-sign-in", return_to: destination)
      assert get_session(response, :user_return_to) == "/"
    end
  end

  test "room entry is public and does not expose private room details before joining", %{
    conn: conn
  } do
    fixture = room_fixture()
    response = get(conn, "/rooms/#{fixture.room.id}")
    document = response |> html_response(200) |> LazyHTML.from_document()
    assert document |> LazyHTML.query("#join-room-form") |> Enum.count() == 1
    assert document |> LazyHTML.query("#room-participants") |> Enum.empty?()
    assert document |> LazyHTML.query("#room-name") |> LazyHTML.text() == "Your room"
  end
end
