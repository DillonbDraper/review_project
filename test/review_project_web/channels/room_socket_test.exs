defmodule ReviewProjectWeb.RoomSocketTest do
  use ReviewProject.DataCase, async: true

  import Phoenix.ChannelTest
  import ReviewProject.AccountsFixtures
  import ReviewProject.RoomsFixtures
  alias ReviewProject.Accounts
  alias ReviewProjectWeb.RoomSocket

  @endpoint ReviewProjectWeb.Endpoint

  test "a signed session is required; client identity and roles are ignored" do
    assert :error =
             connect(RoomSocket, %{browser_identity: browser_identity(), role: "owner"},
               connect_info: %{}
             )

    identity = browser_identity()
    info = %{session: %{"room_browser_identity" => identity}}
    assert {:ok, socket} = connect(RoomSocket, %{user_id: 123}, connect_info: info)
    assert socket.assigns.current_scope == nil
    assert socket.assigns.browser_identity == identity
  end

  test "account sockets use the existing logout topic and refuse expired sessions" do
    user = user_fixture()
    token = Accounts.generate_user_session_token(user)
    info = %{session: %{"room_browser_identity" => browser_identity(), "user_token" => token}}
    assert {:ok, socket} = connect(RoomSocket, %{}, connect_info: info)
    assert socket.assigns.current_scope.user.id == user.id
    assert RoomSocket.id(socket) == "users_sessions:#{Base.url_encode64(token)}"
    Accounts.delete_user_session_token(token)
    assert :error = connect(RoomSocket, %{}, connect_info: info)
  end
end
