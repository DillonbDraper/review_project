defmodule ReviewProjectWeb.RoomSpikeSocket do
  @moduledoc "Development-only socket authenticated from the verified browser session."
  use Phoenix.Socket

  alias ReviewProject.Accounts
  alias ReviewProject.Accounts.Scope

  channel "room_access:*", ReviewProjectWeb.RoomSpikeChannel

  @impl true
  def connect(_params, socket, %{session: %{"room_spike_identity" => identity} = session})
      when is_binary(identity) do
    if Application.get_env(:review_project, :youtube_sync_spike, false) do
      token = session["users_token"]

      scope =
        case token && Accounts.get_users_by_session_token(token) do
          {users, _inserted_at} -> Scope.for_users(users)
          _ -> nil
        end

      {:ok,
       assign(socket,
         current_scope: scope,
         session_token: token,
         browser_identity: identity,
         rooms: ReviewProject.OwnershipSpikes.Rooms
       )}
    else
      :error
    end
  end

  def connect(_params, _socket, _info), do: :error

  @impl true
  def id(%{assigns: %{session_token: token}}) when is_binary(token),
    do: "users_sessions:#{Base.url_encode64(token)}"

  def id(_socket), do: nil
end
