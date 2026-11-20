defmodule ReviewProject.Rooms.Session do
  @moduledoc """
  Single-node authority for one room's live seats, playback and message delivery.

  Transport processes join with a verified scope and server-issued browser identity.
  Only those processes may make requests.
  """
  use GenServer, restart: :transient
  alias ReviewProject.Rooms.{Conference, ICE, Store, Timeline}

  def start_link(opts) do
    name = Keyword.get(opts, :name, via(Keyword.fetch!(opts, :room_id)))
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  def via(id), do: {:via, Registry, {ReviewProject.Rooms.Registry, id}}

  def join(server, scope, identity, invitation, name, member),
    do: GenServer.call(server, {:join, scope, identity, invitation, name, member})

  def request(server, scope, member, operation),
    do: GenServer.call(server, {:request, scope, member, operation})

  @doc false
  def maintain(server), do: GenServer.call(server, :maintain)

  @impl true
  def init(opts) do
    # Finish an in-flight database transition before supervisor shutdown.
    Process.flag(:trap_exit, true)
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    wall_clock = Keyword.get(opts, :wall_clock, &DateTime.utc_now/0)
    now = clock.()
    wall_now = wall_clock.()

    case Store.recover(Keyword.fetch!(opts, :room_id), wall_now) do
      {:ok, %{room: room, seats: seats}} ->
        members =
          Map.new(seats, fn seat ->
            deadline =
              if seat.reserved_until,
                do: now + max(0, DateTime.diff(seat.reserved_until, wall_now, :millisecond))

            {seat.id, member(seat, nil, nil, deadline)}
          end)

        state = %{
          room: room,
          members: members,
          monitors: %{},
          controller_id: nil,
          absent_since: now,
          authority_revision: 0,
          epoch: Ecto.UUID.generate(),
          roster_revision: 0,
          peer_generations: %{},
          timeline: Timeline.new(now),
          clock: clock,
          wall_clock: wall_clock,
          maintenance_interval: Keyword.get(opts, :maintenance_interval, 250)
        }

        schedule(state)
        {:ok, state}

      {:error, reason} ->
        {:stop, {:shutdown, reason}}
    end
  end

  @impl true
  def handle_call({:join, scope, identity, invitation, name, pid}, _from, state) do
    state = maintain_state(state)

    cond do
      not is_pid(pid) ->
        {:reply, {:error, :invalid_member}, state}

      Enum.any?(state.members, fn {_id, member} -> member.pid == pid end) ->
        {:reply, {:error, :already_joined}, state}

      true ->
        case Store.admit(scope, state.room.id, identity, invitation, name, state.wall_clock.()) do
          {:ok, %{seat: seat}} ->
            old = state.members[seat.id]
            state = detach(state, old)

            if old && old.pid,
              do: send(old.pid, {:room_seat_replaced, %{reason: :joined_another_tab}})

            ref = Process.monitor(pid)

            state = %{
              state
              | members: Map.put(state.members, seat.id, member(seat, pid, ref, nil)),
                roster_revision: state.roster_revision + 1,
                monitors: Map.put(state.monitors, ref, seat.id)
            }

            state = if seat.slot == 0, do: %{state | absent_since: nil}, else: state
            state = maintain_state(state)
            broadcast(state)
            {:ok, messages} = Store.history(state.room.id)

            reply = %{
              self_id: seat.id,
              connection_generation: seat.connection_generation,
              snapshot: snapshot(state),
              messages: Enum.map(messages, &public_message/1)
            }

            {:reply, {:ok, reply}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:request, scope, pid, operation}, _from, state) do
    state = maintain_state(state)

    if Store.open?(state.room.id) do
      case Enum.find(state.members, fn {_id, member} -> is_pid(pid) and member.pid == pid end) do
        nil ->
          {:reply, {:error, :not_joined}, state}

        {id, member} ->
          if member.seat.slot == 0 and Store.owner_id(scope) != state.room.owner_id do
            {:reply, {:error, :authentication_required}, state}
          else
            operate(operation, id, member, state)
          end
      end
    else
      notify(state, :room_closed, %{reason: :closed})
      {:stop, :normal, {:error, :room_closed}, state}
    end
  end

  def handle_call(:maintain, _from, state) do
    state = maintain_state(state)
    {:reply, {:ok, snapshot(state)}, state}
  end

  @impl true
  def handle_cast(:closed, state) do
    notify(state, :room_closed, %{reason: :closed})
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, ref) do
      {:ok, id} ->
        member = state.members[id]

        case Store.disconnect(
               state.room.id,
               id,
               member.seat.connection_generation,
               state.wall_clock.()
             ) do
          {:ok, seat} ->
            deadline = if seat.slot > 0, do: state.clock.() + 30_000
            state = detach(state, member)

            state = %{
              state
              | members: Map.put(state.members, id, member(seat, nil, nil, deadline)),
                roster_revision: state.roster_revision + 1
            }

            state = if seat.slot == 0, do: %{state | absent_since: state.clock.()}, else: state
            state = maintain_state(state)
            broadcast(state)
            {:noreply, state}

          {:error, reason} when reason in [:not_found, :stale_connection] ->
            # Closure/deletion can commit before its notification reaches us.
            notify(state, :room_closed, %{reason: :closed})
            {:stop, :normal, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(:maintain, state) do
    state = maintain_state(state)
    schedule(state)
    {:noreply, state}
  end

  defp operate(:snapshot, _id, _member, state),
    do: {:reply, {:ok, snapshot(state)}, state}

  defp operate(:history, _id, _member, state) do
    {:ok, messages} = Store.history(state.room.id)
    {:reply, {:ok, Enum.map(messages, &public_message/1)}, state}
  end

  defp operate({:chat, attrs}, id, member, state) when is_map(attrs) do
    case Store.append_message(state.room.id, id, member.seat.connection_generation, attrs) do
      {:ok, message} ->
        payload = public_message(message)
        notify(state, :room_chat_message, payload)
        {:reply, {:ok, payload}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp operate({:control, command}, id, _member, state) when is_map(command) do
    result =
      cond do
        state.controller_id != id -> {:error, :not_controller}
        command["epoch"] != state.epoch -> {:error, :stale_epoch}
        command["authority_revision"] != state.authority_revision -> {:error, :stale_authority}
        command["revision"] != state.timeline.revision -> {:error, :stale_revision}
        true -> Timeline.command(state.timeline, command, state.clock.())
      end

    case result do
      {:ok, timeline} ->
        state = %{state | timeline: timeline}
        broadcast(state)
        {:reply, {:ok, snapshot(state)}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp operate({:media, params}, id, member, state) when is_map(params) do
    with :ok <- current_connection(params, member, state),
         {:ok, conference} <- Conference.update(member.conference, params) do
      state = %{
        state
        | members: Map.put(state.members, id, %{member | conference: conference}),
          roster_revision:
            state.roster_revision + if(conference != member.conference, do: 1, else: 0)
      }

      if conference != member.conference, do: broadcast(state)
      {:reply, {:ok, snapshot(state)}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp operate({:ice, params}, id, member, state) when is_map(params) do
    with :ok <- current_connection(params, member, state),
         {:ok, member} <- consume(member, :ice, 6, state.clock.()) do
      state = %{state | members: Map.put(state.members, id, member)}
      {:reply, ICE.issue(id), state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp operate({:reset_peer, %{"to" => _to} = params}, id, member, state) do
    with :ok <- current_connection(params, member, state),
         {:ok, target} <- conference_target(params, id, member, state),
         true <- params["peer_generation"] == peer_generation(state, member, target),
         {:ok, member} <- consume(member, :reset_peer, 4, state.clock.()) do
      generation = peer_generation(state, member, target) + 1
      key = peer_key(member, target)

      state = %{
        state
        | peer_generations: Map.put(state.peer_generations, key, generation),
          members: Map.put(state.members, id, member)
      }

      send(target.pid, {:room_conference_peer, peer_envelope(state, member, target, generation)})
      send(member.pid, {:room_conference_peer, peer_envelope(state, target, member, generation)})
      {:reply, {:ok, %{}}, state}
    else
      false -> {:reply, {:error, :stale_peer}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp operate({:signal, %{"to" => to, "data" => data} = params}, id, member, state)
       when is_binary(to) do
    with :ok <- current_connection(params, member, state),
         {:ok, target} <- conference_target(params, id, member, state),
         true <- params["peer_generation"] == peer_generation(state, member, target),
         true <- Conference.valid_signal?(data),
         {:ok, member} <- consume_signal(member, state.clock.()) do
      payload = %{
        from: id,
        epoch: state.epoch,
        connection_generation: member.seat.connection_generation,
        conference_generation: member.conference.generation,
        to_connection_generation: target.seat.connection_generation,
        to_conference_generation: target.conference.generation,
        peer_generation: peer_generation(state, member, target),
        data: data
      }

      send(target.pid, {:room_signal, payload})
      state = %{state | members: Map.put(state.members, id, member)}
      {:reply, {:ok, %{}}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:error, :invalid_signal}, state}
    end
  end

  defp operate(:leave, id, member, state) do
    {:ok, seat} =
      Store.release(state.room.id, id, member.seat.connection_generation, state.wall_clock.())

    state = detach(state, member)
    state = %{state | roster_revision: state.roster_revision + 1}

    state =
      if seat.slot == 0 do
        %{
          state
          | members: Map.put(state.members, id, member(seat, nil, nil, nil)),
            absent_since: state.clock.()
        }
      else
        %{state | members: Map.delete(state.members, id)}
      end

    send(member.pid, {:room_left, %{reason: :left}})
    state = maintain_state(state)
    broadcast(state)
    {:reply, {:ok, %{}}, state}
  end

  defp operate(_operation, _id, _member, state),
    do: {:reply, {:error, :invalid_operation}, state}

  defp maintain_state(state) do
    now = state.clock.()

    expired =
      for {id, member} <- state.members,
          member.seat.slot > 0 and is_nil(member.pid) and
            is_integer(member.deadline) and member.deadline <= now,
          do: id

    if expired != [], do: {:ok, _} = Store.expire(state.room.id, expired)
    members = Map.drop(state.members, expired)
    {_owner_id, owner} = Enum.find(members, fn {_id, member} -> member.seat.slot == 0 end)
    current = members[state.controller_id]

    controller_id =
      cond do
        owner.pid ->
          owner.seat.id

        is_nil(state.absent_since) or now - state.absent_since < 10_000 ->
          nil

        current && current.pid ->
          state.controller_id

        true ->
          members
          |> Enum.filter(fn {_id, member} -> member.seat.slot > 0 and member.pid != nil end)
          |> Enum.min_by(fn {_id, member} -> member.seat.join_sequence end, fn -> {nil, nil} end)
          |> elem(0)
      end

    changed? = controller_id != state.controller_id

    state = %{
      state
      | members: members,
        roster_revision: state.roster_revision + if(expired != [], do: 1, else: 0)
    }

    ready = Enum.filter(Map.values(members), &(&1.pid != nil and &1.conference.ready))

    keys =
      for first <- ready,
          second <- ready,
          first.seat.id < second.seat.id,
          do: peer_key(first, second)

    state = %{state | peer_generations: Map.take(state.peer_generations, keys)}

    state =
      if changed? do
        %{
          state
          | controller_id: controller_id,
            authority_revision: state.authority_revision + 1,
            timeline: Timeline.bump(state.timeline, now)
        }
      else
        state
      end

    if changed? or expired != [], do: broadcast(state)
    state
  end

  defp member(seat, pid, ref, deadline),
    do: %{
      seat: seat,
      pid: pid,
      ref: ref,
      deadline: deadline,
      conference: Conference.new(),
      request_windows: %{},
      signal_window: nil,
      signal_count: 0
    }

  defp detach(state, %{ref: ref}) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    %{state | monitors: Map.delete(state.monitors, ref)}
  end

  defp detach(state, _member), do: state

  defp snapshot(state) do
    seats =
      state.members
      |> Map.values()
      |> Enum.sort_by(& &1.seat.join_sequence)
      |> Enum.map(fn member ->
        %{
          id: member.seat.id,
          display_name: member.seat.display_name,
          role: if(member.seat.slot == 0, do: :owner, else: :guest),
          connected: member.pid != nil,
          connection_generation: member.seat.connection_generation,
          conference: member.conference
        }
      end)

    Timeline.snapshot(state.timeline, state.clock.())
    |> Map.merge(%{
      room_id: state.room.id,
      room_name: state.room.name,
      epoch: state.epoch,
      roster_revision: state.roster_revision,
      authority_revision: state.authority_revision,
      controller_id: state.controller_id,
      owner_present: Enum.any?(seats, &(&1.role == :owner and &1.connected)),
      seats: seats,
      seat_count: length(seats),
      connected_count: Enum.count(seats, & &1.connected)
    })
  end

  defp public_message(message),
    do:
      Map.take(message, [
        :id,
        :room_id,
        :sender_seat_id,
        :sender_display_name,
        :sequence,
        :body,
        :inserted_at
      ])

  defp broadcast(state), do: notify(state, :room_state, snapshot(state))

  defp notify(state, event, payload) do
    for {_id, member} <- state.members, member.pid, do: send(member.pid, {event, payload})
  end

  defp schedule(%{maintenance_interval: :infinity}), do: :ok
  defp schedule(state), do: Process.send_after(self(), :maintain, state.maintenance_interval)

  defp current_connection(params, member, state) do
    cond do
      params["epoch"] != state.epoch ->
        {:error, :stale_epoch}

      params["connection_generation"] != member.seat.connection_generation ->
        {:error, :stale_connection}

      true ->
        :ok
    end
  end

  defp conference_target(params, id, member, state) do
    target = state.members[params["to"]]

    if target && target.pid && member.conference.ready && target.conference.ready &&
         params["to"] != id && params["conference_generation"] == member.conference.generation &&
         params["to_connection_generation"] == target.seat.connection_generation &&
         params["to_conference_generation"] == target.conference.generation,
       do: {:ok, target},
       else: {:error, :invalid_signal}
  end

  defp peer_key(first, second),
    do:
      Enum.sort([
        {first.seat.id, first.seat.connection_generation, first.conference.generation},
        {second.seat.id, second.seat.connection_generation, second.conference.generation}
      ])

  defp peer_generation(state, first, second),
    do: Map.get(state.peer_generations, peer_key(first, second), 0)

  defp peer_envelope(state, from, to, generation),
    do: %{
      epoch: state.epoch,
      from: from.seat.id,
      connection_generation: from.seat.connection_generation,
      conference_generation: from.conference.generation,
      to_connection_generation: to.seat.connection_generation,
      to_conference_generation: to.conference.generation,
      peer_generation: generation
    }

  defp consume(member, operation, limit, now) do
    {started, count} = Map.get(member.request_windows, operation, {now, 0})
    {started, count} = if now - started >= 10_000, do: {now, 0}, else: {started, count}

    if count < limit,
      do:
        {:ok,
         %{
           member
           | request_windows: Map.put(member.request_windows, operation, {started, count + 1})
         }},
      else: {:error, :rate_limited}
  end

  # Four peers can generate a burst of candidates at once. Bound sustained
  # signaling without making device availability part of admission.
  defp consume_signal(member, now) do
    member =
      if is_nil(member.signal_window) or now - member.signal_window >= 10_000,
        do: %{member | signal_window: now, signal_count: 0},
        else: member

    if member.signal_count < 256,
      do: {:ok, %{member | signal_count: member.signal_count + 1}},
      else: {:error, :rate_limited}
  end
end
