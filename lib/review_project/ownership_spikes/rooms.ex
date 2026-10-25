defmodule ReviewProject.OwnershipSpikes.Rooms do
  @moduledoc "Single-node, in-memory access and host handoff experiment for spike 5."
  use GenServer

  alias ReviewProject.OwnershipSpikes.Room
  alias ReviewProject.SyncSpikes.Timeline

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  def create(scope, server \\ __MODULE__), do: GenServer.call(server, {:create, scope})

  def join(scope, id, browser, invite, name, member, server \\ __MODULE__),
    do: GenServer.call(server, {:join, scope, id, browser, invite, name, member})

  def request(scope, id, member, operation, server \\ __MODULE__),
    do: GenServer.call(server, {:request, scope, id, member, operation})

  @impl true
  def init(opts) do
    Process.send_after(self(), :maintain, 250)

    {:ok,
     %{
       rooms: %{},
       monitors: %{},
       clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
       handoff_ms: Keyword.get(opts, :handoff_ms, 10_000),
       reservation_ms: Keyword.get(opts, :reservation_ms, 30_000)
     }}
  end

  @impl true
  def handle_call({:create, scope}, _from, state) do
    with true <- map_size(state.rooms) < 100,
         {:ok, room} <- Room.new(scope, state.clock.()) do
      owner = seat("Host", "host", 0)
      room = %{room | seats: %{owner_key(room) => owner}}

      {:reply, {:ok, %{room_id: room.id, invitation: room.invitation}},
       put_in(state.rooms[room.id], room)}
    else
      false -> {:reply, {:error, :experiment_full}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:join, scope, id, browser, invitation, name, pid}, _from, state) do
    with {:ok, room} <- Map.fetch(state.rooms, id),
         true <- is_binary(browser) and byte_size(browser) in 1..128,
         true <- Room.owner?(scope, room) or Room.invited?(room, invitation),
         {:ok, name} <- Room.display_name(name) do
      room = maintain(room, state)
      key = if Room.owner?(scope, room), do: owner_key(room), else: {:guest, browser}

      if Map.has_key?(room.seats, key) or map_size(room.seats) < 5 do
        role = if key == owner_key(room), do: "host", else: "guest"
        sequence = room.join_sequence + 1
        old = Map.get(room.seats, key, seat(name, role, sequence))
        monitors = detach(old, state.monitors)

        if old.pid && old.pid != pid,
          do: send(old.pid, {:seat_replaced, %{reason: "joined_another_tab"}})

        ref = Process.monitor(pid)
        joined = %{old | pid: pid, ref: ref, name: name, media: false, disconnected_at: nil}

        room = %{
          room
          | seats: Map.put(room.seats, key, joined),
            join_sequence: sequence,
            empty_at: nil
        }

        room = if role == "host", do: %{room | absent_since: nil}, else: room
        room = maintain(room, state)
        broadcast(room, state.clock.())

        state = %{
          state
          | rooms: Map.put(state.rooms, id, room),
            monitors: Map.put(monitors, ref, {id, key, pid})
        }

        {:reply,
         {:ok, %{role: role, snapshot: snapshot(room, state.clock.()), mesh: mesh(room, joined)}},
         state}
      else
        {:reply, {:error, :room_full}, put_in(state.rooms[id], room)}
      end
    else
      :error -> {:reply, {:error, :room_not_found}, state}
      false -> {:reply, {:error, :invalid_invitation}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:request, scope, id, pid, operation}, _from, state) do
    with {:ok, original} <- Map.fetch(state.rooms, id),
         room = maintain(original, state),
         {key, member} <- Enum.find(room.seats, fn {_key, seat} -> seat.pid == pid end),
         true <- member.role != "host" or Room.owner?(scope, room) do
      case operate(room, key, member, operation, state) do
        {:ok, result, updated} ->
          if updated != original, do: broadcast(updated, state.clock.())
          {:reply, {:ok, result}, put_in(state.rooms[id], updated)}

        {:error, reason} ->
          {:reply, {:error, reason}, put_in(state.rooms[id], room)}
      end
    else
      _ -> {:reply, {:error, :not_joined}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {{id, key, pid}, monitors} ->
        state = %{state | monitors: monitors}

        case get_in(state.rooms, [id, :seats, key]) do
          %{pid: ^pid} = member ->
            room = state.rooms[id]
            member = %{member | pid: nil, ref: nil, media: false, disconnected_at: state.clock.()}
            room = %{room | seats: Map.put(room.seats, key, member)}

            room =
              if key == owner_key(room), do: %{room | absent_since: state.clock.()}, else: room

            room = maintain(room, state)
            broadcast(room, state.clock.())
            {:noreply, put_in(state.rooms[id], room)}

          _ ->
            {:noreply, state}
        end
    end
  end

  def handle_info(:maintain, state) do
    rooms =
      Map.new(state.rooms, fn {id, old} ->
        room = maintain(old, state)
        if room != old, do: broadcast(room, state.clock.())
        {id, room}
      end)

    # Research cleanup only. Occupied rooms have no session-duration limit.
    rooms =
      Map.reject(rooms, fn {_id, room} ->
        room.empty_at && state.clock.() - room.empty_at > 1_800_000
      end)

    Process.send_after(self(), :maintain, 250)
    {:noreply, %{state | rooms: rooms}}
  end

  defp operate(room, _key, _member, :snapshot, state),
    do: {:ok, snapshot(room, state.clock.()), room}

  defp operate(room, _key, member, :mesh, _state), do: {:ok, mesh(room, member), room}

  defp operate(room, key, _member, {:control, command}, state) do
    cond do
      room.controller != key ->
        {:error, :forbidden}

      command["authority_revision"] != room.authority_revision ->
        {:error, :stale_authority}

      command["revision"] != room.timeline.revision ->
        {:error, :stale_revision}

      true ->
        case Timeline.update(room.timeline, command, state.clock.()) do
          {:ok, timeline} ->
            room = %{room | timeline: timeline}
            {:ok, snapshot(room, state.clock.()), room}

          error ->
            error
        end
    end
  end

  defp operate(room, key, member, {:media, enabled}, _state) when is_boolean(enabled) do
    room = put_in(room.seats[key], %{member | media: enabled})
    {:ok, %{peers: roster(room)}, room}
  end

  defp operate(room, _key, member, {:signal, %{"to" => to, "data" => data}}, _state) do
    with true <- valid_signal?(data),
         {_key, target} <-
           Enum.find(room.seats, fn {_key, seat} -> seat.id == to and seat.pid != nil end),
         true <- target.pid != member.pid && member.media && target.media do
      send(target.pid, {:mesh_signal, %{from: member.id, data: data}})
      {:ok, %{}, room}
    else
      _ -> {:error, :invalid_signal}
    end
  end

  defp operate(room, _key, member, {:chat, body}, _state) when is_binary(body) do
    body = String.trim(body)

    if byte_size(body) in 1..1000 do
      message = %{
        id: room.chat_seq + 1,
        author: member.id,
        name: member.name,
        role: member.role,
        body: body
      }

      room = %{room | chat_seq: message.id, chat: Enum.take(room.chat ++ [message], -50)}
      for {_key, seat} <- room.seats, seat.pid, do: send(seat.pid, {:mesh_chat, message})
      {:ok, message, room}
    else
      {:error, :invalid_message}
    end
  end

  defp operate(_room, _key, _member, _operation, _state), do: {:error, :invalid_command}

  defp maintain(room, state) do
    now = state.clock.()

    seats =
      Map.reject(room.seats, fn {key, seat} ->
        key != owner_key(room) && seat.pid == nil && seat.disconnected_at != nil &&
          now - seat.disconnected_at >= state.reservation_ms
      end)

    room = %{room | seats: seats}
    owner = room.seats[owner_key(room)]
    active_controller = room.controller && room.seats[room.controller]

    controller =
      cond do
        owner.pid != nil ->
          owner_key(room)

        room.absent_since == nil or now - room.absent_since < state.handoff_ms ->
          nil

        active_controller && active_controller.pid != nil ->
          room.controller

        true ->
          room.seats
          |> Enum.filter(fn {_key, seat} -> seat.pid != nil and seat.role == "guest" end)
          |> Enum.min_by(fn {_key, seat} -> seat.sequence end, fn -> {nil, nil} end)
          |> elem(0)
      end

    room =
      if controller != room.controller do
        %{
          room
          | controller: controller,
            authority_revision: room.authority_revision + 1,
            timeline: %{room.timeline | revision: room.timeline.revision + 1}
        }
      else
        room
      end

    occupied = Enum.any?(room.seats, fn {_key, seat} -> seat.pid != nil end)
    %{room | empty_at: if(occupied, do: nil, else: room.empty_at || now)}
  end

  defp seat(name, role, sequence),
    do: %{
      id: Ecto.UUID.generate(),
      name: name,
      role: role,
      sequence: sequence,
      pid: nil,
      ref: nil,
      media: false,
      disconnected_at: nil
    }

  defp owner_key(room), do: {:owner, room.owner_id}

  defp detach(%{ref: nil}, monitors), do: monitors

  defp detach(%{ref: ref}, monitors) do
    Process.demonitor(ref, [:flush])
    Map.delete(monitors, ref)
  end

  defp public_seat(seat),
    do: %{
      id: seat.id,
      name: seat.name,
      role: seat.role,
      connected: seat.pid != nil,
      media: seat.media
    }

  defp roster(room),
    do:
      room.seats
      |> Map.values()
      |> Enum.filter(& &1.pid)
      |> Enum.sort_by(& &1.sequence)
      |> Enum.map(&public_seat/1)

  defp mesh(room, member), do: %{self_id: member.id, peers: roster(room), chat: room.chat}

  defp snapshot(room, now) do
    Map.put(Timeline.snapshot(room.timeline, now), :access, %{
      owner_identity: room.seats[owner_key(room)].id,
      controller_identity: if(room.controller, do: room.seats[room.controller].id),
      authority_revision: room.authority_revision,
      owner_present: room.seats[owner_key(room)].pid != nil,
      seats:
        room.seats |> Map.values() |> Enum.sort_by(& &1.sequence) |> Enum.map(&public_seat/1),
      seat_count: map_size(room.seats),
      connected_count: length(roster(room))
    })
  end

  defp broadcast(room, now) do
    for {_key, member} <- room.seats, member.pid do
      send(member.pid, {:mesh_roster, %{peers: roster(room)}})
      send(member.pid, {:playback, snapshot(room, now)})
    end
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
end
