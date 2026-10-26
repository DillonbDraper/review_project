defmodule ReviewProjectWeb.RoomSpikeSocketTest do
  use ReviewProject.DataCase, async: true
  import Phoenix.ChannelTest
  import ReviewProject.AccountsFixtures
  alias ReviewProject.Accounts
  alias ReviewProjectWeb.RoomSpikeSocket
  @endpoint ReviewProjectWeb.Endpoint

  test "raw client parameters cannot supply identity or account scope" do
    assert :error =
             connect(RoomSpikeSocket, %{"user_id" => 1, "browser_identity" => "forged"},
               connect_info: %{}
             )

    assert :error = connect(RoomSpikeSocket, %{}, connect_info: %{session: nil})
  end

  test "only the verified session supplies account scope and guest identity" do
    user = user_fixture()
    token = Accounts.generate_user_session_token(user)
    info = %{session: %{"room_spike_identity" => "server-browser", "user_token" => token}}
    assert {:ok, socket} = connect(RoomSpikeSocket, %{"user_id" => 999}, connect_info: info)
    assert socket.assigns.current_scope.user.id == user.id
    assert socket.assigns.browser_identity == "server-browser"
    assert RoomSpikeSocket.id(socket) == "users_sessions:#{Base.url_encode64(token)}"
    Accounts.delete_user_session_token(token)
    assert {:ok, expired} = connect(RoomSpikeSocket, %{}, connect_info: info)
    assert expired.assigns.current_scope == nil
  end
end
