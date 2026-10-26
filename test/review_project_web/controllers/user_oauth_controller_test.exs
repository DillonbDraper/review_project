defmodule ReviewProjectWeb.UserOAuthControllerTest do
  # Not async, as some tests change the application environment.
  use ReviewProjectWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ReviewProject.AccountsFixtures

  alias ReviewProject.Accounts
  alias ReviewProjectWeb.UserOAuthController

  describe "GET /users/auth/google" do
    test "redirects to Google with a state parameter", %{conn: conn} do
      conn = get(conn, ~p"/users/auth/google")

      uri = URI.parse(redirected_to(conn))
      params = URI.decode_query(uri.query)
      assert uri.host == "accounts.google.com"
      assert params["client_id"] == "test-client-id"
      assert params["redirect_uri"] == "http://www.example.com/users/auth/google/callback"
      assert params["scope"] == "email"
      assert params["prompt"] == "select_account"
      assert params["state"] == conn.resp_cookies["ueberauth.state_param"].value
    end

    test "rejects unknown providers", %{conn: conn} do
      conn = get(conn, ~p"/users/auth/github")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not available"
    end
  end

  describe "GET /users/auth/google/callback" do
    test "rejects callbacks without the request's state", %{conn: conn} do
      conn = get(conn, ~p"/users/auth/google/callback?code=code&state=forged")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Could not log in with Google"
      refute get_session(conn, :user_token)
    end

    test "registers and logs in a new user", %{conn: conn} do
      auth = google_auth()
      conn = callback(conn, auth)

      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Welcome!"
      assert {user, _} = Accounts.get_user_by_session_token(get_session(conn, :user_token))
      assert user.email == auth.info.email
      assert conn.resp_cookies["_review_project_web_user_remember_me"]
    end

    test "logs in an existing user with a Gmail address", %{conn: conn} do
      user = user_fixture(email: "user#{System.unique_integer([:positive])}@gmail.com")
      conn = callback(conn, google_auth(email: user.email))

      assert {logged_in_user, _} =
               Accounts.get_user_by_session_token(get_session(conn, :user_token))

      assert logged_in_user.id == user.id
    end

    test "logs in an existing user with a Google Workspace address", %{conn: conn} do
      user = user_fixture()
      conn = callback(conn, google_auth(email: user.email, raw_info: %{"hd" => "example.com"}))

      assert {logged_in_user, _} =
               Accounts.get_user_by_session_token(get_session(conn, :user_token))

      assert logged_in_user.id == user.id
    end

    test "asks existing users to log in with their email when Google is not authoritative",
         %{conn: conn} do
      user = user_fixture()
      conn = callback(conn, google_auth(email: user.email))

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "already uses #{user.email}"
      assert Phoenix.Flash.get(conn.assigns.flash, :email) == user.email
      refute get_session(conn, :user_token)
    end

    test "rejects unverified email addresses", %{conn: conn} do
      auth = google_auth(raw_info: %{"email_verified" => false})
      conn = callback(conn, auth)

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not been verified"
      refute Accounts.get_user_by_email(auth.info.email)
    end
  end

  describe "when Google is not configured" do
    setup do
      config = Application.fetch_env!(:ueberauth, Ueberauth.Strategy.Google.OAuth)
      Application.put_env(:ueberauth, Ueberauth.Strategy.Google.OAuth, client_id: nil)
      on_exit(fn -> Application.put_env(:ueberauth, Ueberauth.Strategy.Google.OAuth, config) end)
    end

    test "does not redirect to Google", %{conn: conn} do
      conn = get(conn, ~p"/users/auth/google")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not available"
    end

    test "hides the Google log in link", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")
      refute has_element?(lv, "#google-log-in")

      {:ok, lv, _html} = live(conn, ~p"/users/register")
      refute has_element?(lv, "#google-log-in")
    end
  end

  # Runs the callback action as if the Ueberauth plug had authenticated
  # the user with Google, which tests cannot contact.
  defp callback(conn, auth) do
    conn
    |> bypass_through(ReviewProjectWeb.Router, [:browser])
    |> get(~p"/users/auth/google/callback")
    |> assign(:ueberauth_auth, auth)
    |> UserOAuthController.callback(%{})
  end

  defp google_auth(attrs \\ []) do
    uid = "google-#{System.unique_integer([:positive])}"
    email = Keyword.get(attrs, :email, unique_user_email())

    user =
      Map.merge(
        %{"sub" => uid, "email" => email, "email_verified" => true},
        Keyword.get(attrs, :raw_info, %{})
      )

    %Ueberauth.Auth{
      provider: :google,
      uid: uid,
      info: %Ueberauth.Auth.Info{email: email},
      extra: %Ueberauth.Auth.Extra{raw_info: %{user: user}}
    }
  end
end
