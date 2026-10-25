defmodule ReviewProject.SyncSpikes.Rooms do
  @moduledoc """
  Ephemeral, single-node playback, mesh signaling and chat for spikes 2 and 3A. Host credentials are
  research fixtures, not account authentication or the production ownership model.
  Positions are anchored to a monotonic clock; player callbacks never write state.
  """
  use GenServer

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  def create(server \\ __MODULE__), do: GenServer.call(server, :create)

  def join(room, token, member, server \\ __MODULE__),
    do: GenServer.call(server, {:join, room, token, member})

  def snapshot(room, member, server \\ __MODULE__),
    do: GenServer.call(server, {:snapshot, room, member})

  def control(room, member, command, server \\ __MODULE__),
    do: GenServer.call(server, {:control, room, member, command})

  def mesh_state(room, member, server \\ __MODULE__),
    do: GenServer.call(server, {:mesh_state, room, member})

  def media(room, member, enabled, server \\ __MODULE__),
    do: GenServer.call(server, {:media, room, member, enabled})

  def signal(room, member, payload, server \\ __MODULE__),
    do: GenServer.call(server, {:signal, room, member, payload})

  def chat(room, member, body, server \\ __MODULE__),
    do: GenServer.call(server, {:chat, room, member, body})

  @impl true
  def init(opts) do
    Process.send_after(self(), :prune, 60_000)

    {:ok,
     %{
       rooms: %{},
       monitors: %{},
       clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
     }}
  end

  @impl true
  def handle_call(:create, _from, state) do
    if map_size(state.rooms) >= 100 do
      {:reply, {:error, :experiment_full}, state}
    else
      id = Ecto.UUID.generate()
      token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      room = %{
        token: token,
        video_id: "M7lc1UVf-VE",
        position: 0.0,
        playing: false,
        revision: 0,
        at: state.clock.(),
        members: %{},
        identities: %{},
        chat: [],
        chat_seq: 0,
        empty_at: state.clock.()
      }

      {:reply, {:ok, %{room_id: id, host_token: token}}, put_in(state.rooms[id], room)}
    end
  end

  def handle_call({:join, id, token, member}, _from, state) do
    with {:ok, room} <- Map.fetch(state.rooms, id),
         {:ok, role} <- role(room, token),
         true <- map_size(room.members) < 5,
         false <-
           role == "host" &&
             Enum.any?(room.members, fn {pid, r} -> pid != member && r == "host" end) do
      {monitors, _ref} =
        if Map.has_key?(room.members, member) do
          {state.monitors, nil}
        else
          ref = Process.monitor(member)
          {Map.put(state.monitors, ref, {id, member}), ref}
        end

      identity =
        Map.get(room.identities, member, %{id: Ecto.UUID.generate(), role: role, media: false})

      room = %{
        room
        | members: Map.put(room.members, member, role),
          identities: Map.put(room.identities, member, identity),
          empty_at: nil
      }

      broadcast_roster(room)
      state = %{state | rooms: Map.put(state.rooms, id, room), monitors: monitors}
      {:reply, {:ok, role, public(room, state.clock.())}, state}
    else
      :error -> {:reply, {:error, :room_not_found}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
      true -> {:reply, {:error, :host_already_connected}, state}
      false -> {:reply, {:error, :room_full}, state}
    end
  end

  def handle_call({:snapshot, id, member}, _from, state) do
    with {:ok, room} <- Map.fetch(state.rooms, id),
         true <- Map.has_key?(room.members, member) do
      {:reply, {:ok, public(room, state.clock.())}, state}
    else
      _ -> {:reply, {:error, :not_joined}, state}
    end
  end

  def handle_call({:control, id, member, command}, _from, state) do
    with {:ok, room} <- Map.fetch(state.rooms, id),
         "host" <- Map.get(room.members, member),
         %{"revision" => revision} when revision == room.revision <- command,
         {:ok, room} <- update(room, command, state.clock.()) do
      snapshot = public(room, state.clock.())
      for {pid, _role} <- room.members, do: send(pid, {:playback, snapshot})
      {:reply, {:ok, snapshot}, put_in(state.rooms[id], room)}
    else
      :error -> {:reply, {:error, :room_not_found}, state}
      role when role in [nil, "guest"] -> {:reply, {:error, :forbidden}, state}
      %{} -> {:reply, {:error, :stale_revision}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:error, :invalid_command}, state}
    end
  end

  def handle_call({:mesh_state, id, member}, _from, state) do
    with {:ok, room} <- Map.fetch(state.rooms, id),
         {:ok, identity} <- Map.fetch(room.identities, member) do
      {:reply, {:ok, %{self_id: identity.id, peers: roster(room), chat: room.chat}}, state}
    else
      _ -> {:reply, {:error, :not_joined}, state}
    end
  end

  def handle_call({:media, id, member, enabled}, _from, state) do
    with true <- is_boolean(enabled),
         {:ok, room} <- Map.fetch(state.rooms, id),
         {:ok, identity} <- Map.fetch(room.identities, member) do
      room = %{room | identities: Map.put(room.identities, member, %{identity | media: enabled})}
      broadcast_roster(room)
      {:reply, {:ok, %{peers: roster(room)}}, put_in(state.rooms[id], room)}
    else
      _ -> {:reply, {:error, :not_joined}, state}
    end
  end

  def handle_call({:signal, id, member, payload}, _from, state) do
    with {:ok, room} <- Map.fetch(state.rooms, id),
         {:ok, sender} <- Map.fetch(room.identities, member),
         %{"to" => to, "data" => data} <- payload,
         true <- valid_signal?(data),
         {target, recipient} <-
           Enum.find(room.identities, fn {_pid, identity} -> identity.id == to end),
         true <- target != member && sender.media && recipient.media do
      send(target, {:mesh_signal, %{from: sender.id, data: data}})
      {:reply, {:ok, %{}}, state}
    else
      _ -> {:reply, {:error, :invalid_signal}, state}
    end
  end

  def handle_call({:chat, id, member, body}, _from, state) do
    with {:ok, room} <- Map.fetch(state.rooms, id),
         {:ok, sender} <- Map.fetch(room.identities, member),
         true <- is_binary(body),
         body = String.trim(body),
         true <- byte_size(body) > 0 && byte_size(body) <= 1000 do
      message = %{id: room.chat_seq + 1, author: sender.id, role: sender.role, body: body}
      room = %{room | chat_seq: message.id, chat: Enum.take(room.chat ++ [message], -50)}
      for {pid, _role} <- room.members, do: send(pid, {:mesh_chat, message})
      {:reply, {:ok, message}, put_in(state.rooms[id], room)}
    else
      _ -> {:reply, {:error, :invalid_message}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {{id, member}, monitors} ->
        room = Map.fetch!(state.rooms, id)
        members = Map.delete(room.members, member)

        room = %{
          room
          | members: members,
            identities: Map.delete(room.identities, member),
            empty_at: if(map_size(members) == 0, do: state.clock.())
        }

        broadcast_roster(room)

        {:noreply, %{state | rooms: Map.put(state.rooms, id, room), monitors: monitors}}
    end
  end

  def handle_info(:prune, state) do
    # Research harness cleanup only: an occupied room has no duration limit.
    cutoff = state.clock.() - 30 * 60 * 1000
    rooms = Map.reject(state.rooms, fn {_id, room} -> room.empty_at && room.empty_at < cutoff end)
    Process.send_after(self(), :prune, 60_000)
    {:noreply, %{state | rooms: rooms}}
  end

  defp role(_room, token) when token in [nil, ""], do: {:ok, "guest"}

  defp role(room, token) when is_binary(token) do
    if Plug.Crypto.secure_compare(room.token, token),
      do: {:ok, "host"},
      else: {:error, :invalid_host_token}
  end

  defp role(_room, _token), do: {:error, :invalid_host_token}

  defp roster(room), do: room.identities |> Map.values() |> Enum.sort_by(& &1.id)

  defp broadcast_roster(room) do
    peers = roster(room)
    for {pid, _role} <- room.members, do: send(pid, {:mesh_roster, %{peers: peers}})
  end

  defp valid_signal?(
         %{"type" => "description", "description" => %{"type" => type, "sdp" => sdp}} = data
       )
       when type in ["offer", "answer"] and is_binary(sdp),
       do: byte_size(sdp) <= 65_536 && byte_size(Jason.encode!(data)) <= 73_728

  defp valid_signal?(%{"type" => "candidate", "candidate" => %{"candidate" => candidate}} = data)
       when is_binary(candidate),
       do: byte_size(candidate) <= 4096 && byte_size(Jason.encode!(data)) <= 8192

  defp valid_signal?(_data), do: false

  defp public(room, now), do: ReviewProject.SyncSpikes.Timeline.snapshot(room, now)

  defp update(room, command, now),
    do: ReviewProject.SyncSpikes.Timeline.update(room, command, now)
end
