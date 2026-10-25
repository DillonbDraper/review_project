defmodule ReviewProjectWeb.RoomSpikeChannel do
  @moduledoc "Verified room membership, playback authority, mesh signaling and chat for spike 5."
  use Phoenix.Channel
  alias ReviewProject.{Accounts, OwnershipSpikes.Rooms, SyncSpikes.ICE}

  @impl true
  def join("room_access:" <> id, params, socket) do
    mode = Map.get(params, "ice_mode", "direct")

    with true <- valid_session?(socket),
         {:ok, _validation} <- ICE.issue("validation", mode),
         {:ok, reply} <-
           Rooms.join(
             socket.assigns.current_scope,
             id,
             socket.assigns.browser_identity,
             params["invitation"],
             params["display_name"],
             self(),
             socket.assigns.rooms
           ),
         {:ok, ice} <- ICE.issue(reply.mesh.self_id, mode) do
      reply = %{reply | mesh: Map.put(reply.mesh, :ice, ice)}
      {:ok, reply, socket |> assign(:room_id, id) |> assign(:ice_mode, mode)}
    else
      false -> {:error, %{reason: :session_expired}}
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  @impl true
  def handle_in(event, params, socket) do
    if valid_session?(socket) do
      result =
        case {event, params} do
          {"snapshot", _} ->
            request(socket, :snapshot)

          {"control", command} when is_map(command) ->
            request(socket, {:control, command})

          {"mesh_media", %{"enabled" => enabled}} ->
            request(socket, {:media, enabled})

          {"mesh_signal", payload} ->
            request(socket, {:signal, payload})

          {"mesh_chat", %{"body" => body}} ->
            request(socket, {:chat, body})

          {"mesh_ice", _} ->
            with {:ok, mesh} <- request(socket, :mesh),
                 do: ICE.issue(mesh.self_id, socket.assigns.ice_mode)

          _ ->
            {:error, :unknown_event}
        end

      case result do
        {:ok, reply} -> {:reply, {:ok, reply}, socket}
        {:error, reason} -> {:reply, {:error, %{reason: reason}}, socket}
      end
    else
      {:stop, :normal, {:error, %{reason: :session_expired}}, socket}
    end
  end

  @impl true
  def handle_info({:seat_replaced, payload}, socket) do
    push(socket, "seat_replaced", payload)
    {:stop, :normal, socket}
  end

  def handle_info({event, payload}, socket)
      when event in [:playback, :mesh_roster, :mesh_signal, :mesh_chat] do
    push(socket, Atom.to_string(event), payload)
    {:noreply, socket}
  end

  defp request(socket, operation),
    do:
      Rooms.request(
        socket.assigns.current_scope,
        socket.assigns.room_id,
        self(),
        operation,
        socket.assigns.rooms
      )

  defp valid_session?(%{assigns: %{current_scope: nil}}), do: true

  defp valid_session?(%{assigns: %{current_scope: scope, session_token: token}}) do
    case Accounts.get_users_by_session_token(token) do
      {users, _at} -> users.id == scope.users.id
      _ -> false
    end
  end
end
