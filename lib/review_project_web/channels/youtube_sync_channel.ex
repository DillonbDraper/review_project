defmodule ReviewProjectWeb.YouTubeSyncChannel do
  @moduledoc "Playback, membership, targeted mesh signaling and chat for development spikes."
  use Phoenix.Channel

  alias ReviewProject.SyncSpikes.Rooms
  alias ReviewProject.SyncSpikes.ICE

  @impl true
  def join("youtube_sync:" <> id, params, socket) do
    case Rooms.join(id, Map.get(params, "host_token"), self(), socket.assigns.rooms) do
      {:ok, role, snapshot} ->
        {:ok, mesh} = Rooms.mesh_state(id, self(), socket.assigns.rooms)
        mode = Map.get(params, "ice_mode", "direct")

        case ICE.issue(mesh.self_id, mode) do
          {:ok, ice} ->
            {:ok, %{role: role, snapshot: snapshot, mesh: Map.put(mesh, :ice, ice)},
             socket |> assign(:room_id, id) |> assign(:ice_mode, mode)}

          {:error, reason} ->
            {:error, %{reason: reason}}
        end

      {:error, reason} ->
        {:error, %{reason: reason}}
    end
  end

  @impl true
  def handle_in("snapshot", _params, socket) do
    reply_result(Rooms.snapshot(socket.assigns.room_id, self(), socket.assigns.rooms), socket)
  end

  def handle_in("control", command, socket) do
    reply_result(
      Rooms.control(socket.assigns.room_id, self(), command, socket.assigns.rooms),
      socket
    )
  end

  def handle_in("mesh_media", %{"enabled" => enabled}, socket) do
    reply_result(
      Rooms.media(socket.assigns.room_id, self(), enabled, socket.assigns.rooms),
      socket
    )
  end

  def handle_in("mesh_signal", payload, socket) do
    reply_result(
      Rooms.signal(socket.assigns.room_id, self(), payload, socket.assigns.rooms),
      socket
    )
  end

  def handle_in("mesh_chat", %{"body" => body}, socket) do
    reply_result(Rooms.chat(socket.assigns.room_id, self(), body, socket.assigns.rooms), socket)
  end

  def handle_in("mesh_ice", _params, socket) do
    with {:ok, mesh} <- Rooms.mesh_state(socket.assigns.room_id, self(), socket.assigns.rooms),
         {:ok, ice} <- ICE.issue(mesh.self_id, socket.assigns.ice_mode) do
      {:reply, {:ok, ice}, socket}
    else
      {:error, reason} -> {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in(_event, _params, socket),
    do: {:reply, {:error, %{reason: :unknown_event}}, socket}

  @impl true
  def handle_info({:playback, snapshot}, socket) do
    push(socket, "playback", snapshot)
    {:noreply, socket}
  end

  def handle_info({event, payload}, socket)
      when event in [:mesh_roster, :mesh_signal, :mesh_chat] do
    push(socket, Atom.to_string(event), payload)
    {:noreply, socket}
  end

  defp reply_result({:ok, snapshot}, socket), do: {:reply, {:ok, snapshot}, socket}
  defp reply_result({:error, reason}, socket), do: {:reply, {:error, %{reason: reason}}, socket}
end
