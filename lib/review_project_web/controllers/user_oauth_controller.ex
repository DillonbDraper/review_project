defmodule ReviewProjectWeb.UserOAuthController do
  use ReviewProjectWeb, :controller

  alias ReviewProject.Accounts
  alias ReviewProjectWeb.UserAuth

  plug :ueberauth

  # Ueberauth redirects requests for enabled providers to the provider,
  # so this is only reached for unknown or unconfigured providers.
  def request(conn, _params), do: provider_unavailable(conn)

  def callback(%{assigns: %{ueberauth_auth: %Ueberauth.Auth{} = auth}} = conn, _params) do
    case Accounts.login_user_by_identity(identity_attrs(auth)) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(:info, "Welcome!")
        |> UserAuth.log_in_user(user, %{"remember_me" => "true"})

      {:error, :email_taken} ->
        conn
        |> put_flash(
          :error,
          "An account already uses #{auth.info.email}. Log in with your email to continue."
        )
        |> put_flash(:email, auth.info.email)
        |> redirect(to: ~p"/users/log-in")

      {:error, :email_not_verified} ->
        conn
        |> put_flash(:error, "Your Google account's email address has not been verified.")
        |> redirect(to: ~p"/users/log-in")

      {:error, _reason} ->
        log_in_failed(conn)
    end
  end

  def callback(%{assigns: %{ueberauth_failure: _failure}} = conn, _params) do
    log_in_failed(conn)
  end

  def callback(conn, _params), do: provider_unavailable(conn)

  defp ueberauth(conn, _opts) do
    if UserAuth.oauth_provider_enabled?(conn.path_params["provider"]) do
      Ueberauth.call(conn, Ueberauth.init())
    else
      conn
    end
  end

  defp identity_attrs(%Ueberauth.Auth{provider: :google} = auth) do
    user = auth.extra.raw_info.user
    email_verified? = user["email_verified"] in [true, "true"]

    %{
      provider: "google",
      uid: auth.uid,
      email: auth.info.email,
      email_verified: email_verified?,
      email_authoritative: email_verified? and google_authoritative?(user)
    }
  end

  # Google vouches for the current owner of Gmail and Workspace addresses only, see
  # https://developers.google.com/identity/openid-connect/openid-connect#obtainuserinfo
  defp google_authoritative?(%{"email" => email} = user) when is_binary(email) do
    String.ends_with?(String.downcase(email), "@gmail.com") or is_binary(user["hd"])
  end

  defp google_authoritative?(_user), do: false

  defp log_in_failed(conn) do
    conn
    |> put_flash(:error, "Could not log in with Google. Please try again.")
    |> redirect(to: ~p"/users/log-in")
  end

  defp provider_unavailable(conn) do
    conn
    |> put_flash(:error, "That log in method is not available.")
    |> redirect(to: ~p"/users/log-in")
  end
end
