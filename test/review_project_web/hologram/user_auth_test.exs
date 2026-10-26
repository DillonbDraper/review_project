defmodule ReviewProjectWeb.Hologram.UserAuthTest do
  use ReviewProject.DataCase, async: true

  import ReviewProject.AccountsFixtures

  alias Hologram.Server
  alias ReviewProject.Accounts
  alias ReviewProjectWeb.Hologram.UserAuth

  setup do
    user = user_fixture()
    %{user: user, token: Accounts.generate_user_session_token(user)}
  end

  describe "call/2 with :mount_current_scope" do
    test "stashes the scope of the session's user", %{user: user, token: token} do
      server = UserAuth.call(%Server{session: %{"user_token" => token}}, :mount_current_scope)

      assert server.stash.current_scope.user.id == user.id
    end

    test "stashes a nil scope without a valid session token", %{token: token} do
      Accounts.delete_user_session_token(token)

      for session <- [%{}, %{"user_token" => token}] do
        server = UserAuth.call(%Server{session: session}, :mount_current_scope)

        assert Map.fetch!(server.stash, :current_scope) == nil
        refute server.status
      end
    end
  end

  describe "call/2 with :require_authenticated" do
    test "continues for logged in users", %{user: user, token: token} do
      server = %Server{method: :get, path: "/rooms", session: %{"user_token" => token}}
      server = UserAuth.call(server, :require_authenticated)

      assert server.stash.current_scope.user.id == user.id
      refute server.status
    end

    test "redirects pages to log in and returns to them afterwards" do
      server = %Server{method: :get, path: "/rooms", raw_query: "tab=open"}
      server = UserAuth.call(server, :require_authenticated)

      assert server.status == 302
      assert Server.get_response_header(server, "location") == "/users/log-in"
      assert server.session["user_return_to"] == "/rooms?tab=open"

      assert server.session["phoenix_flash"] == %{
               "error" => "You must log in to access this page."
             }
    end

    test "does not return to pages fetched by client-side navigation" do
      server = %Server{method: :post, path: "/hologram/page/Elixir.ReviewProjectWeb.Rooms"}
      server = UserAuth.call(server, :require_authenticated)

      assert server.status == 302
      refute Map.has_key?(server.session, "user_return_to")
    end

    test "refuses commands" do
      server = %Server{method: :post, path: "/hologram/command"}
      server = UserAuth.call(server, :require_authenticated)

      assert server.status == 403
      refute Server.get_response_header(server, "location")
      assert server.session == %{}
    end
  end

  describe "csrf_token/1" do
    test "returns a token for the session's CSRF state, creating it if needed" do
      {token, server} = UserAuth.csrf_token(%Server{})

      assert Plug.CSRFProtection.valid_state_and_csrf_token?(server.session["_csrf_token"], token)
      assert {_token, ^server} = UserAuth.csrf_token(server)
    end

    test "does not reuse the token of another session" do
      {_token, server} = UserAuth.csrf_token(%Server{})
      {other_token, other_server} = UserAuth.csrf_token(%Server{})

      refute other_server.session["_csrf_token"] == server.session["_csrf_token"]

      refute Plug.CSRFProtection.valid_state_and_csrf_token?(
               server.session["_csrf_token"],
               other_token
             )
    end
  end
end
