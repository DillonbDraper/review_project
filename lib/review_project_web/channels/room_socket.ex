defmodule ReviewProjectWeb.RoomSocket do
  @moduledoc "Room connections authenticated from the signed browser session."
  use Phoenix.Socket

  alias ReviewProject.Accounts
  alias ReviewProject.Accounts.Scope

  channel "room:*", ReviewProjectWeb.RoomChannel

  @impl true
  def connect(_params, socket, %{session: %{"room_browser_identity" => identity} = session})
      when is_binary(identity) and byte_size(identity) in 16..256 do
    token = session["user_token"]

    case token && Accounts.get_user_by_session_token(token) do
      {user, _at} ->
        {:ok,
         assign(socket,
           current_scope: Scope.for_user(user),
           session_token: token,
           browser_identity: identity
         )}

      nil when is_nil(token) ->
        {:ok, assign(socket, current_scope: nil, session_token: nil, browser_identity: identity)}

      _ ->
        :error
    end
  end

  def connect(_params, _socket, _info), do: :error

  @impl true
  def id(%{assigns: %{session_token: token}}) when is_binary(token),
    do: "users_sessions:#{Base.url_encode64(token)}"

  def id(_socket), do: nil

  def valid_session?(%{assigns: %{session_token: nil, current_scope: nil}}), do: true

  def valid_session?(%{assigns: %{session_token: token, current_scope: scope}}) do
    case Accounts.get_user_by_session_token(token) do
      {user, _at} -> user.id == scope.user.id
      _ -> false
    end
  end
end
