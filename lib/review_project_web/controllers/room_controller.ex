defmodule ReviewProjectWeb.RoomController do
  use ReviewProjectWeb, :controller

  def session(conn, _params) do
    conn =
      if get_session(conn, :room_browser_identity) do
        conn
      else
        put_session(
          conn,
          :room_browser_identity,
          Base.url_encode64(:crypto.strong_rand_bytes(32))
        )
      end

    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(%{
      csrf_token: Plug.CSRFProtection.get_csrf_token(),
      signed_in: not is_nil(conn.assigns.current_scope)
    })
  end

  def sign_in(conn, params) do
    destination = params["return_to"]

    destination =
      if is_binary(destination) and Regex.match?(~r"\A/rooms/[a-f0-9-]{36}\z", destination),
        do: destination,
        else: "/"

    if conn.assigns.current_scope do
      redirect(conn, to: destination)
    else
      conn |> put_session(:user_return_to, destination) |> redirect(to: "/users/log-in")
    end
  end
end
