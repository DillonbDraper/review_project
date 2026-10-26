defmodule ReviewProjectWeb.Hologram.AccountMenuTest do
  use ReviewProjectWeb.ConnCase, async: true

  import ReviewProject.AccountsFixtures

  alias ReviewProject.Accounts

  @remember_me_cookie "_review_project_web_user_remember_me"

  test "links guests to log in and sign up", %{conn: conn} do
    document = conn |> get("/") |> html_response(200) |> LazyHTML.from_document()

    assert document |> LazyHTML.query(~s|#log-in[href="/users/log-in"]|) |> Enum.count() == 1
    assert document |> LazyHTML.query(~s|#sign-up[href="/users/register"]|) |> Enum.count() == 1
    assert document |> LazyHTML.query("#log-out-form") |> Enum.empty?()
  end

  describe "for logged in users" do
    setup :register_and_log_in_user

    test "links to settings and logs out with the session's CSRF token",
         %{conn: conn, user: user} do
      conn = get(conn, "/")
      document = conn |> html_response(200) |> LazyHTML.from_document()

      assert document |> LazyHTML.query("#account-email") |> LazyHTML.text() == user.email

      assert document
             |> LazyHTML.query(~s|#account-settings[href="/users/settings"]|)
             |> Enum.count() == 1

      assert document |> LazyHTML.query("#log-in") |> Enum.empty?()

      form = LazyHTML.query(document, "#log-out-form")
      assert LazyHTML.attribute(form, "action") == ["/users/log-out"]
      assert LazyHTML.attribute(form, "method") == ["post"]
      assert input_value(form, "_method") == "delete"

      csrf_token = input_value(form, "_csrf_token")

      assert Plug.CSRFProtection.valid_state_and_csrf_token?(
               get_session(conn, "_csrf_token"),
               csrf_token
             )

      user_token = get_session(conn, :user_token)
      conn = post(conn, "/users/log-out", %{"_method" => "delete", "_csrf_token" => csrf_token})

      assert redirected_to(conn) == "/"
      refute Accounts.get_user_by_session_token(user_token)
    end

    test "treats logged out sessions as guests", %{conn: conn} do
      conn |> get_session(:user_token) |> Accounts.delete_user_session_token()

      document = conn |> get("/") |> html_response(200) |> LazyHTML.from_document()

      assert document |> LazyHTML.query("#log-in") |> Enum.count() == 1
      assert document |> LazyHTML.query("#account-email") |> Enum.empty?()
    end
  end

  test "keeps remembered users logged in", %{conn: conn} do
    user = user_fixture() |> set_password()

    conn =
      post(conn, ~p"/users/log-in", %{
        "user" => %{
          "email" => user.email,
          "password" => valid_user_password(),
          "remember_me" => "true"
        }
      })

    # A new browser session that only has the remember me cookie.
    conn =
      build_conn()
      |> put_req_cookie(@remember_me_cookie, conn.resp_cookies[@remember_me_cookie].value)
      |> get("/")

    document = conn |> html_response(200) |> LazyHTML.from_document()
    assert document |> LazyHTML.query("#account-email") |> LazyHTML.text() == user.email
    assert get_session(conn, :user_token)
  end

  defp input_value(form, name) do
    [value] = form |> LazyHTML.query(~s|input[name="#{name}"]|) |> LazyHTML.attribute("value")
    value
  end
end
