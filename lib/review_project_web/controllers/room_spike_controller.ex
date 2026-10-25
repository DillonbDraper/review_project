defmodule ReviewProjectWeb.RoomSpikeController do
  @moduledoc "Browser-session bootstrap and authenticated creation for spike 5."
  use ReviewProjectWeb, :controller

  alias ReviewProject.OwnershipSpikes.Rooms

  @spike_path "/dev/spikes/room-access"

  def sign_in(conn, params) do
    return_to = params["return_to"] || @spike_path

    # Only return to this spike, including its invitation and selected ICE mode.
    # Never accept an external URL or a different application route.
    return_to =
      if is_binary(return_to) and
           Regex.match?(
             ~r{\A/dev/spikes/room-access(?:/room/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+)?(?:\?ice=(?:direct|auto|stun|relay-udp|relay-tcp|relay-tls))?\z},
             return_to
           ),
         do: return_to,
         else: @spike_path

    if conn.assigns.current_scope do
      redirect(conn, to: return_to)
    else
      conn
      |> put_session(:users_return_to, return_to)
      |> redirect(to: "/users/log-in")
    end
  end

  def session(conn, _params) do
    conn =
      if get_session(conn, :room_spike_identity),
        do: conn,
        else: put_session(conn, :room_spike_identity, Ecto.UUID.generate())

    email = if conn.assigns.current_scope, do: conn.assigns.current_scope.users.email

    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(%{
      csrf_token: Plug.CSRFProtection.get_csrf_token(),
      signed_in: not is_nil(conn.assigns.current_scope),
      email: email
    })
  end

  def create(conn, _params) do
    case Rooms.create(conn.assigns.current_scope) do
      {:ok, room} -> conn |> put_resp_header("cache-control", "no-store") |> json(room)
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: reason})
    end
  end
end
