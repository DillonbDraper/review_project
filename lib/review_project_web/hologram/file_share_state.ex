defmodule ReviewProjectWeb.Hologram.FileShareState do
  @moduledoc "Client-side file selection, membership, signaling and recovery policy."
  alias ReviewProjectWeb.Hologram.{FileShareMetadata, FileSharePeer}

  def new(generation \\ 0) do
    %{
      generation: generation,
      connected: false,
      room_generation: -1,
      pending_room: [],
      room_id: nil,
      epoch: nil,
      self_id: nil,
      connection_generation: nil,
      source: nil,
      seats: [],
      revision: -1,
      roster_revision: -1,
      authority_revision: -1,
      controller_id: nil,
      owned: nil,
      peers: %{},
      peer_generations: %{},
      early: %{},
      serial: 0,
      ice_ref: nil,
      ice_request: 0,
      ice_fetching: false,
      restoring: false,
      selection: nil,
      selection_serial: 0,
      open: false,
      message: "",
      outgoing: 0.0,
      metrics: nil
    }
  end

  def view(state) do
    metrics =
      if state.source do
        if state.source.available do
          bitrate = Float.round(state.source.size * 8 / state.source.duration / 1_000_000, 2)

          if supplier?(state),
            do:
              "Source bitrate ≈ #{bitrate} Mbps · Total outgoing #{Float.round(state.outgoing / 1_000_000, 2)} Mbps · Original quality",
            else: "Source bitrate ≈ #{bitrate} Mbps · Original quality"
        else
          "Source unavailable · Shared playback paused"
        end
      else
        ""
      end

    %{
      share_open: state.open,
      share_message: state.message,
      share_generation: state.selection_serial,
      share_metrics: metrics
    }
  end

  def event(state, :joined, params) do
    if params.generation > state.generation do
      next = %{
        new(params.generation)
        | connected: true,
          room_id: params.snapshot.room_id,
          epoch: params.snapshot.epoch,
          self_id: params.self_id,
          connection_generation: params.connection_generation,
          owned: params.retained,
          room_generation: params.room_generation
      }

      {next, effects} = snapshot(next, params.snapshot)

      Enum.reduce(state.pending_room, {next, effects}, fn queued, {next, effects} ->
        if queued.room_generation == params.room_generation do
          {next, more} = event(next, :room_signal, queued)
          {next, effects ++ more}
        else
          {next, effects}
        end
      end)
    else
      {state, []}
    end
  end

  def event(state, :stopped, params) do
    if params.generation >= state.generation,
      do: {%{new(params.generation) | room_generation: params.room_generation}, []},
      else: {state, []}
  end

  def event(state, :room_signal, params) do
    cond do
      params.room_generation < state.room_generation ->
        {state, []}

      not state.connected or params.room_generation > state.room_generation ->
        {%{state | pending_room: Enum.take(state.pending_room ++ [params], 64)}, []}

      params.kind == "signal" ->
        handle(state, :signal, %{signal: params.payload})

      params.kind == "peer_reset" ->
        handle(state, :peer_reset, %{peer: params.payload})

      true ->
        {state, []}
    end
  end

  def event(state, event, params) when event in [:open, :close, :cancel] do
    handle(state, event, params)
  end

  def event(state, event, params) do
    if state.connected and Map.get(params, :generation, state.generation) == state.generation,
      do: handle(state, event, params),
      else: {state, []}
  end

  def controller?(state), do: state.connected and state.controller_id == state.self_id
  def supplier?(state), do: state.source != nil and state.source.seat_id == state.self_id

  def owns?(state),
    do:
      state.source != nil and state.owned != nil and
        state.owned.source_id == state.source.id and
        state.owned.source_generation == state.source.generation

  defp handle(state, :snapshot, %{snapshot: incoming}), do: snapshot(state, incoming)

  defp handle(state, :open, params) do
    if Map.get(params, :solo, false) or controller?(state),
      do:
        {%{state | open: true, message: "Choose a file to share directly from this device."}, []},
      else: {state, []}
  end

  defp handle(state, event, _) when event in [:close, :cancel] do
    {state, effects} = cancel_selection(state)

    {%{
       state
       | open: if(event == :close, do: false, else: state.open),
         message: if(event == :cancel, do: "File preparation cancelled.", else: state.message)
     }, effects}
  end

  defp handle(state, :choose, _) do
    if controller?(state) and state.selection == nil do
      request = state.selection_serial + 1
      {%{state | selection_serial: request}, [{:choose_file, request}]}
    else
      {state, []}
    end
  end

  defp handle(state, :chosen, params) do
    cond do
      not controller?(state) or not state.open or params.request != state.selection_serial or
          state.selection != nil ->
        {state, [{:release_file, params.handle}]}

      params.size < 1 or params.size > 1_073_741_824 ->
        {%{state | message: "Choose a file up to 1 GiB."}, [{:release_file, params.handle}]}

      true ->
        selection = %{
          request: params.request,
          handle: params.handle,
          name: params.name,
          size: params.size,
          guards: selection_guards(state),
          phase: :inspecting,
          metadata: nil
        }

        {%{state | selection: selection, message: "Preparing file…"},
         [{:inspect_file, params.request, params.handle}]}
    end
  end

  defp handle(state, :inspected, params) do
    if selection_current?(state, params, :inspecting) do
      if params.status == "ok" do
        case FileShareMetadata.validate(state.selection, params.result) do
          {:ok, metadata} ->
            selection = %{state.selection | phase: :decoding, metadata: metadata}

            {%{state | selection: selection},
             [{:check_decode, selection.request, metadata.codec}]}

          {:error, message} ->
            selection_failed(state, message)
        end
      else
        message =
          if Map.get(params, :reason) == "inspection_timeout",
            do: "File inspection exceeded ten seconds. Choose another file.",
            else:
              "Could not inspect this file within the format and read limits. Choose another file."

        selection_failed(state, message)
      end
    else
      {state, []}
    end
  end

  defp handle(state, :decoded, params) do
    if selection_current?(state, params, :decoding) do
      cond do
        not params.supported ->
          selection_failed(state, "This browser cannot decode the selected file.")

        not controller?(state) or state.selection.guards != selection_guards(state) ->
          selection_failed(state, "Playback changed during preparation. Choose the file again.")

        true ->
          selection = %{state.selection | phase: :publishing}
          {%{state | selection: selection, message: "Publishing file…"}, [{:offer, selection}]}
      end
    else
      {state, []}
    end
  end

  defp handle(state, :offered, params) do
    if selection_current?(state, params, :publishing) do
      source = Map.get(params.result, :video_source)

      valid =
        params.status == "ok" and source != nil and source.kind == "local_file" and
          params.result.epoch == state.epoch and
          not (state.revision > params.result.revision and
                 source_key(state.source) != source_key(source))

      if valid do
        selection = state.selection

        owned = %{
          handle: selection.handle,
          source_id: source.id,
          source_generation: source.generation
        }

        state = %{
          state
          | selection: nil,
            owned: owned,
            open: false,
            message: "File shared. Keep this tab open."
        }

        {state, effects} = snapshot(state, params.result)
        {state, more} = reconcile(state)
        {state, [{:adopt_file, selection.handle, source} | effects ++ more]}
      else
        selection_failed(
          state,
          "The file could not be selected because playback or the connection changed. Choose the file again."
        )
      end
    else
      {state, []}
    end
  end

  defp handle(state, :ice_ready, params) do
    if params.request == state.ice_request do
      old = state.ice_ref
      state = %{state | ice_ref: params.ref, ice_fetching: false}
      effects = [{:release_ice, old}, {:cancel_timer, "file-ice", "refresh"}]

      effects =
        if params.refresh_after,
          do:
            effects ++
              [
                {:later, "file-ice", "refresh", params.refresh_after * 1000,
                 %{event: "refresh_ice", request: params.request}}
              ],
          else: effects

      {state, configure} =
        Enum.reduce(state.peers, {state, []}, fn {_, peer}, {state, effects} ->
          {state, more} = put_peer(state, FileSharePeer.enqueue(peer, :configure))
          {state, effects ++ more}
        end)

      {state, more} = reconcile(state)
      {state, effects ++ configure ++ more}
    else
      {state, [{:release_ice, params.ref}]}
    end
  end

  defp handle(state, :ice_failed, %{request: request}) do
    if request == state.ice_request,
      do:
        {%{state | ice_fetching: false, message: "Connecting to the file source…"},
         [{:later, "file-ice", "refresh", 2000, %{event: "refresh_ice", request: request}}]},
      else: {state, []}
  end

  defp handle(state, :restored, params) do
    if state.source && params.source_id == state.source.id do
      state = %{state | restoring: false}

      if params.status == "ok",
        do: snapshot(state, params.result),
        else:
          {state,
           [
             {:later, "file-room", "restore", 2000,
              %{event: "restore", source_id: params.source_id}}
           ]}
    else
      {state, []}
    end
  end

  defp handle(state, :signal, %{signal: message}) do
    if current_message?(state, message) do
      case state.peers[message.from] do
        nil ->
          signals = Map.get(state.early, message.from, [])

          {%{
             state
             | early: Map.put(state.early, message.from, Enum.take(signals ++ [message.data], 64))
           }, []}

        peer ->
          put_peer(state, FileSharePeer.enqueue(peer, message.data))
      end
    else
      {state, []}
    end
  end

  defp handle(state, :peer_reset, %{peer: message}) do
    if current_envelope?(state, message) and
         message.peer_generation > known_generation(state, message.from) do
      old = state.peers[message.from]

      state = %{
        state
        | peers: Map.delete(state.peers, message.from),
          early: Map.delete(state.early, message.from),
          peer_generations:
            Map.put(state.peer_generations, message.from, %{
              generation: message.peer_generation,
              connection_generation: message.connection_generation
            })
      }

      {state, effects} = reconcile(state)
      {state, if(old, do: [{:close_peer, old.group} | effects], else: effects)}
    else
      {state, []}
    end
  end

  defp handle(state, :reset_result, params) do
    peer = state.peers[params.peer]

    if peer && peer.group == params.group && params.status != "ok",
      do: retry_peer(state, %{peer | retry_pending: false}),
      else: {state, []}
  end

  defp handle(state, :signaled, params) do
    peer = state.peers[params.peer]

    if peer && peer.group == params.group && params.status != "ok",
      do: retry_peer(state, peer),
      else: {state, []}
  end

  defp handle(state, :native, %{event: "metrics"} = params) do
    if state.source && state.source.id == params.source_id do
      outgoing =
        if state.metrics && params.at > state.metrics.at,
          do:
            max(0, params.sent_bytes - state.metrics.bytes) * 8000 /
              (params.at - state.metrics.at),
          else: 0.0

      {%{state | outgoing: outgoing, metrics: %{at: params.at, bytes: params.sent_bytes}}, []}
    else
      {state, []}
    end
  end

  defp handle(state, :native, %{event: "refresh_ice", request: request}) do
    if request == state.ice_request, do: fetch_ice(state), else: {state, []}
  end

  defp handle(state, :native, %{event: "restore", source_id: id}) do
    if state.source && state.source.id == id, do: restore(state), else: {state, []}
  end

  defp handle(state, :native, params) do
    peer = state.peers[Map.get(params, :peer)]

    if peer && peer.group == Map.get(params, :group),
      do: native_peer(state, peer, params),
      else: {state, []}
  end

  defp handle(state, _, _), do: {state, []}

  defp native_peer(state, peer, %{event: "operation", token: token} = params) do
    if token == peer.token and peer.phase not in [:idle, :failed] do
      if params.status == "ok",
        do: put_peer(state, FileSharePeer.complete(peer, params.result)),
        else: retry_peer(state, %{peer | phase: :failed, queue: [], data: nil, candidates: []})
    else
      {state, []}
    end
  end

  defp native_peer(state, peer, %{event: "ice", candidate: candidate}),
    do: {state, FileSharePeer.candidate(peer, candidate)}

  defp native_peer(state, peer, %{event: "channel", handle: handle}),
    do: {state, [{:bind_channel, peer.id, handle}]}

  defp native_peer(state, peer, %{event: "channel_open"}) do
    peer = %{
      peer
      | connected: true,
        retry_pending: false,
        retries: 0,
        retry_token: peer.retry_token + 1
    }

    effects = [{:cancel_timer, peer.group, "recovery"}]

    effects =
      if supplier?(state), do: effects, else: effects ++ [{:player_ready, state.source.id}]

    {%{state | peers: Map.put(state.peers, peer.id, peer)}, effects}
  end

  defp native_peer(state, peer, %{event: "connection", status: status})
       when status in ["failed", "disconnected"],
       do: retry_peer(state, %{peer | connected: false})

  defp native_peer(state, peer, %{event: "channel_closed"}),
    do: retry_peer(state, %{peer | connected: false})

  defp native_peer(state, peer, %{event: "recover", token: token}) do
    if token == peer.retry_token and not peer.connected do
      peer = %{peer | retry_pending: true, retries: peer.retries + 1}
      {%{state | peers: Map.put(state.peers, peer.id, peer)}, [{:reset_peer, peer.id}]}
    else
      {state, []}
    end
  end

  defp native_peer(state, _peer, _params), do: {state, []}

  defp snapshot(state, incoming) do
    if incoming.epoch == state.epoch and incoming.room_id == state.room_id and
         incoming.revision >= state.revision and incoming.roster_revision >= state.roster_revision do
      source =
        case Map.get(incoming, :video_source) do
          %{kind: "local_file"} = source -> source
          _ -> nil
        end

      changed =
        state.revision == -1 or source_key(source) != source_key(state.source) or
          availability(source) != availability(state.source)

      old_peers = state.peers
      old_ice = state.ice_ref
      owned = if source_key(source) == owned_key(state.owned), do: state.owned

      same_connections =
        for seat <- incoming.seats,
            Enum.any?(
              state.seats,
              &(&1.id == seat.id and &1.connection_generation == seat.connection_generation)
            ),
            do: seat.id

      state = %{
        state
        | source: source,
          seats: incoming.seats,
          early: Map.take(state.early, same_connections),
          peer_generations: Map.take(state.peer_generations, same_connections),
          revision: incoming.revision,
          roster_revision: incoming.roster_revision,
          authority_revision: incoming.authority_revision,
          controller_id: incoming.controller_id,
          owned: owned
      }

      {state, selection_effects} =
        if (not controller?(state) and state.selection) && state.selection.phase != :publishing,
          do: cancel_selection(state),
          else: {state, []}

      state = if not controller?(state), do: %{state | open: false}, else: state

      {state, effects} =
        if changed do
          mode = if supplier?(state), do: "source", else: "receiver"

          next = %{
            state
            | peers: %{},
              early: %{},
              peer_generations: %{},
              ice_ref: nil,
              ice_fetching: false,
              ice_request: state.ice_request + 1,
              restoring: false,
              metrics: nil,
              outgoing: 0.0
          }

          effects = Enum.map(old_peers, fn {_, peer} -> {:close_peer, peer.group} end)

          {next,
           effects ++
             [
               {:release_ice, old_ice},
               {:cancel_timer, "file-ice", "refresh"},
               {:configure_source, source, mode}
             ]}
        else
          {state, []}
        end

      {state, restore_effects} = restore(state)
      {state, peer_effects} = reconcile(state)
      {state, selection_effects ++ effects ++ restore_effects ++ peer_effects}
    else
      {state, []}
    end
  end

  defp reconcile(state) do
    seats =
      if state.source && state.source.available do
        Enum.filter(state.seats, fn seat ->
          seat.connected and seat.id != state.self_id and
            (supplier?(state) or seat.id == state.source.seat_id)
        end)
      else
        []
      end

    {peers, closed} =
      Enum.reduce(state.peers, {%{}, []}, fn {id, peer}, {kept, effects} ->
        if Enum.any?(
             seats,
             &(&1.id == id and &1.connection_generation == peer.connection_generation)
           ),
           do: {Map.put(kept, id, peer), effects},
           else: {kept, effects ++ [{:close_peer, peer.group}]}
      end)

    state = %{state | peers: peers}

    cond do
      is_nil(state.source) or not state.source.available or
          (supplier?(state) and not owns?(state)) ->
        {state, closed}

      state.ice_ref == nil ->
        {state, effects} = fetch_ice(state)
        {state, closed ++ effects}

      true ->
        Enum.reduce(seats, {state, closed}, fn seat, {state, effects} ->
          if state.peers[seat.id] do
            {state, effects}
          else
            serial = state.serial + 1
            group = "file-peer:#{state.generation}:#{serial}"
            negotiation = "file:#{state.generation}:#{serial}"

            peer =
              FileSharePeer.new(
                seat,
                known_generation(state, seat.id),
                group,
                supplier?(state),
                negotiation
              )

            {peer, created} = FileSharePeer.start(peer)

            peer = %{
              peer
              | queue: Map.get(state.early, seat.id, []),
                retry_token: 1,
                retry_pending: false
            }

            state = %{
              state
              | serial: serial,
                peers: Map.put(state.peers, seat.id, peer),
                early: Map.delete(state.early, seat.id)
            }

            {state,
             effects ++
               created ++
               [
                 {:later, group, "recovery", 15000,
                  %{event: "recover", peer: seat.id, token: peer.retry_token}}
               ]}
          end
        end)
    end
  end

  defp fetch_ice(state) do
    if state.source && state.source.available && not state.ice_fetching do
      request = state.ice_request + 1
      {%{state | ice_request: request, ice_fetching: true}, [{:fetch_ice, request}]}
    else
      {state, []}
    end
  end

  defp restore(state) do
    if state.source != nil and not state.source.available and supplier?(state) and owns?(state) and
         not state.restoring,
       do: {%{state | restoring: true}, [{:restore, state.source.id}]},
       else: {state, []}
  end

  defp retry_peer(state, peer) do
    if peer.retry_pending do
      {%{state | peers: Map.put(state.peers, peer.id, peer)}, []}
    else
      token = peer.retry_token + 1
      delay = min(10000, 2000 * (peer.retries + 1))
      peer = %{peer | retry_pending: true, retry_token: token}

      {%{state | peers: Map.put(state.peers, peer.id, peer)},
       [{:later, peer.group, "recovery", delay, %{event: "recover", peer: peer.id, token: token}}]}
    end
  end

  defp put_peer(state, {peer, effects}),
    do: {%{state | peers: Map.put(state.peers, peer.id, peer)}, effects}

  defp selection_current?(state, params, phase),
    do:
      state.selection != nil and
        state.selection.request == params.request and state.selection.phase == phase

  defp selection_failed(state, message) do
    handle = state.selection.handle
    {%{state | selection: nil, message: message}, [{:release_file, handle}]}
  end

  defp cancel_selection(%{selection: %{phase: :publishing}} = state), do: {state, []}

  defp cancel_selection(%{selection: selection} = state) when selection != nil,
    do:
      {%{state | selection: nil, selection_serial: state.selection_serial + 1},
       [{:release_file, selection.handle}]}

  defp cancel_selection(state), do: {%{state | selection_serial: state.selection_serial + 1}, []}

  def selection_guards(state),
    do: %{
      epoch: state.epoch,
      authority_revision: state.authority_revision,
      revision: state.revision,
      connection_generation: state.connection_generation
    }

  def file_guards(state),
    do: %{
      epoch: state.epoch,
      connection_generation: state.connection_generation,
      source_id: state.source.id,
      source_generation: state.source.generation
    }

  def envelope(state, peer),
    do:
      Map.merge(file_guards(state), %{
        to: peer.id,
        to_connection_generation: peer.connection_generation,
        peer_generation: peer.peer_generation
      })

  defp source_key(nil), do: nil
  defp source_key(source), do: {source.id, source.generation}
  defp owned_key(nil), do: nil
  defp owned_key(owned), do: {owned.source_id, owned.source_generation}
  defp availability(nil), do: nil
  defp availability(source), do: source.available

  defp known_generation(state, id) do
    seat = Enum.find(state.seats, &(&1.id == id))

    case state.peer_generations[id] do
      %{generation: generation, connection_generation: connection} when seat != nil ->
        if seat.connection_generation == connection, do: generation, else: 0

      _ ->
        0
    end
  end

  defp current_message?(state, message),
    do:
      current_envelope?(state, message) and
        message.peer_generation == known_generation(state, message.from)

  defp current_envelope?(state, message) do
    seat = Enum.find(state.seats, &(&1.id == message.from and &1.connected))

    state.source != nil and state.source.available and seat != nil and
      message.epoch == state.epoch and message.source_id == state.source.id and
      message.source_generation == state.source.generation and
      message.to_connection_generation == state.connection_generation and
      message.connection_generation == seat.connection_generation and
      message.from != state.self_id and
      (supplier?(state) or message.from == state.source.seat_id)
  end
end
