defmodule ReviewProjectWeb.RoomChannel do
  @moduledoc "Room admission, chat and membership-authorized conference signaling."
  use Phoenix.Channel

  alias ReviewProject.Rooms
  alias ReviewProjectWeb.{RoomErrors, RoomSocket}

  @impl true
  def join("room:" <> room_id, params, socket) do
    with true <- RoomSocket.valid_session?(socket),
         {:ok, room_id} <- Ecto.UUID.cast(room_id),
         {:ok, reply} <-
           Rooms.join_room(
             socket.assigns.current_scope,
             room_id,
             socket.assigns.browser_identity,
             params["invitation"],
             params["display_name"]
           ),
         [{coordinator, _}] <- Registry.lookup(ReviewProject.Rooms.Registry, room_id) do
      ref = Process.monitor(coordinator)

      # A coordinator can restart between admission and monitoring. The epoch
      # check makes sure this channel is bound to the process it actually joined.
      case Rooms.request(socket.assigns.current_scope, room_id, :snapshot) do
        {:ok, %{epoch: epoch}} when epoch == reply.snapshot.epoch ->
          {:ok, Map.take(reply, [:self_id, :connection_generation, :snapshot, :messages]),
           assign(socket, room_id: room_id, coordinator_ref: ref)}

        _ ->
          {:error, %{reason: "not_joined"}}
      end
    else
      false -> {:error, %{reason: "session_expired"}}
      {:error, reason} -> {:error, RoomErrors.payload(reason)}
      [] -> {:error, %{reason: "not_joined"}}
      :error -> {:error, %{reason: "not_found"}}
    end
  end

  @impl true
  def handle_in(event, params, socket) do
    if RoomSocket.valid_session?(socket) do
      result =
        case {event, params} do
          {event, params} when event in ["replay_select", "replay_cancel"] and is_map(params) ->
            operation = if event == "replay_select", do: :replay_select, else: :replay_cancel

            Rooms.request(
              socket.assigns.current_scope,
              socket.assigns.room_id,
              {operation, params}
            )

          {"replay_preparation_failure", _} ->
            Rooms.request(
              socket.assigns.current_scope,
              socket.assigns.room_id,
              :replay_preparation_failure
            )

          {"replay_grant", _} ->
            Rooms.request(socket.assigns.current_scope, socket.assigns.room_id, :replay_grant)

          {"snapshot", _} ->
            Rooms.request(socket.assigns.current_scope, socket.assigns.room_id, :snapshot)

          {"control", command} when is_map(command) ->
            Rooms.request(
              socket.assigns.current_scope,
              socket.assigns.room_id,
              {:control, command}
            )

          {"activity", params} when is_map(params) ->
            Rooms.request(socket.assigns.current_scope, socket.assigns.room_id, :activity)

          {"leave", _} ->
            Rooms.request(socket.assigns.current_scope, socket.assigns.room_id, :leave)

          {"chat_send", %{"body" => body}} when is_binary(body) ->
            Rooms.send_message(socket.assigns.current_scope, socket.assigns.room_id, %{body: body})

          {"chat_history", params} when is_map(params) ->
            Rooms.request(socket.assigns.current_scope, socket.assigns.room_id, :history)

          {event, params}
          when event in ~w(file_offer file_available file_signal file_reset file_ice) and
                 is_map(params) ->
            operation = %{
              "file_offer" => :file_offer,
              "file_available" => :file_available,
              "file_signal" => :file_signal,
              "file_reset" => :file_reset,
              "file_ice" => :file_ice
            }

            Rooms.request(
              socket.assigns.current_scope,
              socket.assigns.room_id,
              {Map.fetch!(operation, event), params}
            )

          {"conference_state", params} when is_map(params) ->
            Rooms.request(socket.assigns.current_scope, socket.assigns.room_id, {:media, params})

          {"conference_signal", params} when is_map(params) ->
            Rooms.request(socket.assigns.current_scope, socket.assigns.room_id, {:signal, params})

          {"conference_ice", params} when is_map(params) ->
            Rooms.request(socket.assigns.current_scope, socket.assigns.room_id, {:ice, params})

          {"conference_reset", params} when is_map(params) ->
            Rooms.request(
              socket.assigns.current_scope,
              socket.assigns.room_id,
              {:reset_peer, params}
            )

          _ ->
            {:error, :invalid_operation}
        end

      case result do
        {:ok, reply} -> {:reply, {:ok, reply}, socket}
        {:error, reason} -> {:reply, {:error, RoomErrors.payload(reason)}, socket}
      end
    else
      push(socket, "room_ended", %{reason: "session_expired"})
      {:stop, :normal, {:error, %{reason: "session_expired"}}, socket}
    end
  end

  @impl true
  def handle_info({:room_state, snapshot}, socket) do
    push(socket, "room_state", snapshot)
    {:noreply, socket}
  end

  def handle_info({:room_chat_message, message}, socket) do
    push(socket, "chat_message", message)
    {:noreply, socket}
  end

  def handle_info({:room_file_signal, signal}, socket) do
    push(socket, "file_signal", signal)
    {:noreply, socket}
  end

  def handle_info({:room_file_peer, peer}, socket) do
    push(socket, "file_peer", peer)
    {:noreply, socket}
  end

  def handle_info({:room_signal, signal}, socket) do
    push(socket, "conference_signal", signal)
    {:noreply, socket}
  end

  def handle_info({:room_conference_peer, peer}, socket) do
    push(socket, "conference_peer", peer)
    {:noreply, socket}
  end

  def handle_info({event, payload}, socket)
      when event in [:room_seat_replaced, :room_left, :room_closed] do
    push(socket, "room_ended", RoomErrors.payload(payload.reason))
    {:stop, :normal, socket}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{assigns: %{coordinator_ref: ref}} = socket
      ) do
    push(socket, "room_restart", %{})
    {:stop, :normal, socket}
  end

  def handle_info({_event, _payload}, socket), do: {:noreply, socket}
end
