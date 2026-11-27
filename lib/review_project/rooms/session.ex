defmodule ReviewProject.Rooms.Session do
  @moduledoc """
  Single-node authority for one room's live seats, playback and message delivery.

  Transport processes join with a verified scope and server-issued browser identity.
  Only those processes may make requests.
  """
  use GenServer, restart: :transient
  alias ReviewProject.Rooms.{Conference, ICE, Media, Store, Timeline}

  def http_request(server, scope, identity, operation),
    do: GenServer.call(server, {:http_request, scope, identity, operation})

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
          media_server: Keyword.get(opts, :media_server, Media),
          media_empty_since: now,
          media_activity_at: now,
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
            state = state |> touch_media() |> maintain_state()
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

    if Store.open?(state.room.id, state.wall_clock.()) do
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

  # HTTP requests carry the verified signed browser identity, never a client PID.
  # Only a currently connected seat can stream or stage media.
  def handle_call({:http_request, scope, identity, :continue_upload}, _from, state) do
    # Upload boundaries verify durable room state. Between them, use the live
    # coordinator's seat/controller state; join/leave/close and maintenance
    # already update it. Do not run database-backed maintenance per body chunk.
    case http_member(state, scope, identity) do
      nil -> {:reply, {:error, :not_joined}, state}
      {id, member} -> operate(:can_upload, id, member, state)
    end
  end

  def handle_call({:http_request, scope, identity, operation}, _from, state) do
    state = maintain_state(state)

    if Store.open?(state.room.id, state.wall_clock.()) do
      case http_member(state, scope, identity) do
        nil -> {:reply, {:error, :not_joined}, state}
        {id, member} -> operate(operation, id, member, state)
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

  def handle_cast({:closed, reason}, state) do
    notify(state, :room_closed, %{reason: reason})
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
        {:reply, {:ok, payload}, touch_media(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp operate(:begin_upload, id, member, state) do
    case operate(:can_upload, id, member, state) do
      {:reply, {:ok, token}, state} -> {:reply, {:ok, token}, touch_media(state)}
      result -> result
    end
  end

  defp operate(:can_upload, id, _member, state) do
    result =
      cond do
        not media_enabled?() -> {:error, :uploads_disabled}
        state.controller_id != id -> {:error, :not_controller}
        true -> {:ok, %{epoch: state.epoch, authority_revision: state.authority_revision}}
      end

    {:reply, result, state}
  end

  defp operate(:media_access, _id, _member, state), do: {:reply, {:ok, %{}}, state}

  defp operate(:activity, _id, member, state) do
    case consume(member, :activity, 30, state.clock.()) do
      {:ok, member} ->
        state = %{state | members: Map.put(state.members, member.seat.id, member)}
        {:reply, {:ok, %{}}, touch_media(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp operate({:control, command}, id, _member, state) when is_map(command) do
    with :ok <- authorize_control(state, id, command) do
      case apply_control(state, command) do
        {:ok, timeline} ->
          state = touch_media(%{state | timeline: timeline})
          broadcast(state)
          {:reply, {:ok, snapshot(state)}, state}

        {:error, reason, next} ->
          {:reply, {:error, reason}, next}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
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
    state = maintain_media(state)
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
    maintain_media(state)
  end

  @impl true
  def terminate(_reason, state) do
    media_call(fn -> Media.discard(state.room.id, state.media_server) end)
    :ok
  end

  defp authorize_control(state, id, command) do
    cond do
      state.controller_id != id -> {:error, :not_controller}
      command["epoch"] != state.epoch -> {:error, :stale_epoch}
      command["authority_revision"] != state.authority_revision -> {:error, :stale_authority}
      command["revision"] != state.timeline.revision -> {:error, :stale_revision}
      true -> :ok
    end
  end

  defp apply_control(state, %{"op" => "video", "source" => %{"kind" => "upload", "id" => id}})
       when is_binary(id) do
    with true <- media_enabled?(),
         {:ok, asset} <- media_call(fn -> Media.ready(state.room.id, id, state.media_server) end) do
      source = %{
        kind: "upload",
        id: asset.id,
        name: asset.name,
        duration: asset.duration,
        url: "/room-media/#{state.room.id}/#{asset.id}"
      }

      {:ok, Timeline.select_upload(state.timeline, source, state.clock.())}
    else
      false -> {:error, :uploads_disabled}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_control(state, %{"op" => "discard_upload"}) do
    next = clear_uploaded_source(state)

    case media_call(fn -> Media.discard(state.room.id, state.media_server) end) do
      :ok -> {:ok, next.timeline}
      {:error, reason} -> {:error, reason, next}
    end
  end

  defp apply_control(state, command),
    do: Timeline.command(state.timeline, command, state.clock.())

  defp clear_uploaded_source(%{timeline: %{video_source: %{kind: "upload"}}} = state) do
    state = %{state | timeline: Timeline.clear(state.timeline, state.clock.())}
    broadcast(state)
    state
  end

  defp clear_uploaded_source(state), do: state

  defp touch_media(state), do: %{state | media_activity_at: state.clock.()}

  defp maintain_media(state) do
    now = state.clock.()
    empty? = not Enum.any?(state.members, fn {_id, member} -> member.pid != nil end)
    empty_since = if empty?, do: state.media_empty_since || now, else: nil
    active? = Timeline.playing?(state.timeline, now)
    state = %{state | media_empty_since: empty_since}
    state = if active?, do: touch_media(state), else: state

    # Known uploaded durations prevent an ended player claiming perpetual activity.
    state =
      if state.timeline.playing and not active? and state.timeline.video_id != nil do
        timeline = Timeline.bump(state.timeline, now)
        duration = state.timeline.video_source.duration
        ended_at = Timeline.playback_end(state.timeline)

        state = %{
          state
          | timeline: %{timeline | playing: false, position: duration},
            media_activity_at: max(state.media_activity_at, ended_at)
        }

        broadcast(state)
        state
      else
        state
      end

    empty_due? = is_integer(empty_since) and now - empty_since >= 300_000
    idle_due? = not active? and now - state.media_activity_at >= 3_600_000

    case media_call(fn -> Media.staged(state.room.id, state.media_server) end) do
      nil ->
        clear_uploaded_source(state)

      {:error, _} ->
        clear_uploaded_source(state)

      _asset when empty_due? or idle_due? ->
        state = clear_uploaded_source(state)
        media_call(fn -> Media.discard(state.room.id, state.media_server) end)
        state

      _asset ->
        validate_uploaded_source(state)
    end
  end

  defp validate_uploaded_source(%{timeline: %{video_source: %{kind: "upload", id: id}}} = state) do
    case media_call(fn -> Media.ready(state.room.id, id, state.media_server) end) do
      {:ok, _asset} -> state
      _ -> clear_uploaded_source(state)
    end
  end

  defp validate_uploaded_source(state), do: state

  defp http_member(state, scope, identity) do
    digest =
      if is_binary(identity) and byte_size(identity) >= 32,
        do: :crypto.hash(:sha256, [state.room.id, ":", identity])

    Enum.find(state.members, fn {_id, member} ->
      member.pid != nil and
        if member.seat.slot == 0 do
          Store.owner_id(scope) == state.room.owner_id
        else
          digest != nil and member.seat.browser_identity_hash == digest
        end
    end)
  end

  defp media_enabled?,
    do: Keyword.get(Application.get_env(:review_project, :uploaded_video, []), :enabled, false)

  defp media_call(fun) do
    fun.()
  catch
    :exit, _reason -> {:error, :media_unavailable}
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
