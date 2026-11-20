defmodule ReviewProjectWeb.Hologram.ConferenceState do
  @moduledoc "Client-side conference state and effects, independent of browser objects."
  alias ReviewProjectWeb.Hologram.{ConferencePeer, ConferenceRecovery, ConferenceTiles}

  def new(generation \\ 0) do
    %{
      generation: generation,
      connected: false,
      supported: true,
      self_id: nil,
      epoch: nil,
      connection_generation: nil,
      own: nil,
      seats: [],
      views: %{},
      roster_revision: -1,
      serial: 0,
      devices: Map.new(["audio", "video"], &{&1, device()}),
      peers: %{},
      publishing: false,
      publish_dirty: false,
      resume: nil,
      ice_ready: false,
      ice_ref: nil,
      ice_group: nil,
      ice_request: 0,
      ice_fetching: false,
      ice_error: "",
      error: ""
    }
  end

  def view(state) do
    %{
      connected: state.connected,
      supported: state.supported,
      microphone: status(state.devices["audio"]),
      camera: status(state.devices["video"]),
      microphone_error: state.devices["audio"].error,
      camera_error: state.devices["video"].error,
      error: state.error,
      ice_error: state.ice_error,
      retry_available:
        state.ice_error != "" or
          Enum.any?(state.peers, fn {_, peer} -> peer.recovery_stage == :exhausted end),
      peer_count: map_size(state.peers),
      connected_peers: Enum.count(state.peers, fn {_id, peer} -> peer.connected end),
      audio_blocked: Enum.any?(state.peers, fn {_id, peer} -> peer.blocked end),
      tiles: ConferenceTiles.list(state)
    }
  end

  def event(state, :joined, params) do
    if params.generation > state.generation do
      resume = if Map.get(params, :resume, false), do: state.resume

      state = %{
        new(params.generation)
        | connected: true,
          supported: params.supported,
          self_id: params.self_id,
          epoch: params.snapshot.epoch,
          connection_generation: params.connection_generation
      }

      {state, effects} = roster(state, params.snapshot)
      {state, ice_effects} = if state.supported, do: request_ice(state), else: {state, []}
      kinds = if resume && resume.self_id == state.self_id, do: resume.kinds, else: []

      Enum.reduce(kinds, {state, effects ++ ice_effects}, fn kind, {state, effects} ->
        {state, next} = handle(state, :toggle, %{kind: kind})
        {state, effects ++ next}
      end)
    else
      {state, []}
    end
  end

  def event(state, :stopped, params) do
    if params.generation >= state.generation do
      resume =
        case Map.get(params, :mode, "stop") do
          "recover" when state.connected ->
            %{
              self_id: state.self_id,
              kinds: Enum.filter(["audio", "video"], &(state.devices[&1].track != nil))
            }

          mode when mode in ["recover", "continue"] ->
            state.resume

          _ ->
            nil
        end

      {%{new(params.generation) | resume: resume}, []}
    else
      {state, []}
    end
  end

  def event(state, event, params) do
    if state.connected and Map.get(params, :generation, state.generation) == state.generation,
      do: handle(state, event, params),
      else: {state, []}
  end

  defp handle(state, :roster, %{snapshot: snapshot}), do: roster(state, snapshot)

  defp handle(state, :ice_ready, params) do
    if params.request == state.ice_request do
      initial = not state.ice_ready
      old_group = state.ice_group

      state = %{
        state
        | ice_ready: true,
          ice_fetching: false,
          ice_ref: params.ref,
          ice_group: params.group,
          ice_error: if(Map.get(params, :fallback, false), do: ice_error(), else: "")
      }

      delay =
        if Map.get(params, :fallback, false),
          do: 5_000,
          else: params.refresh_after && params.refresh_after * 1_000

      effects = [{:close, old_group}] ++ ice_timer(state, delay)
      {state, next} = if initial, do: publish(state), else: configure_peers(state)
      {state, effects ++ next}
    else
      {state, [{:close, params.group}]}
    end
  end

  defp handle(state, :ice_failed, %{request: request}) do
    if request == state.ice_request,
      do: {%{state | ice_fetching: false, ice_error: ice_error()}, ice_timer(state, 5_000)},
      else: {state, []}
  end

  defp handle(state, :native_result, %{event: "refresh_ice", request: request}) do
    if request == state.ice_request, do: request_ice(state), else: {state, []}
  end

  defp handle(state, :retry_call, _) do
    {state, effects} = request_ice(state)

    Enum.reduce(state.peers, {state, effects}, fn {_, peer}, {state, effects} ->
      if peer.recovery_stage == :exhausted do
        {state, next} = update_peer(state, peer, ConferenceRecovery.retry(peer))
        {state, effects ++ next}
      else
        {state, effects}
      end
    end)
  end

  defp handle(state, :toggle, %{kind: kind}) when kind in ["audio", "video"] do
    device = state.devices[kind]

    cond do
      not state.supported ->
        {state, []}

      device.pending or device.track != nil ->
        {state, effects} = tracks_changed(put_device(state, kind, device()))
        {state, [{:close, device.group} | effects]}

      true ->
        serial = state.serial + 1
        group = "device:#{kind}:#{serial}"
        next = %{device | pending: true, error: "", group: group}
        state = put_device(%{state | serial: serial}, kind, next)
        {state, [{:capture, kind, next}]}
    end
  end

  defp handle(state, :enable_audio, _params) do
    {state,
     Enum.flat_map(state.peers, fn {id, peer} -> if peer.audio, do: [{:play, id}], else: [] end)}
  end

  defp handle(state, :published, params) do
    dirty = state.publish_dirty
    state = %{state | publishing: false, publish_dirty: false}

    {state, effects} =
      if params.status == "ok",
        do: roster(state, params.result),
        else:
          {%{
             state
             | error:
                 "Conference signaling is unavailable. Your room and chat are still connected."
           }, []}

    {state, next} = if dirty, do: publish(state), else: {state, []}
    {state, effects ++ next}
  end

  defp handle(state, :signaled, params) do
    # Replies from an obsolete pair cannot change the replacement's UI.
    if params.status == "ok" or
         not Enum.any?(state.peers, fn {_, p} -> p.group == params.group end),
       do: {state, []},
       else: {%{state | error: "A conference signal could not be delivered."}, []}
  end

  defp handle(state, :reset_result, params) do
    peer = state.peers[params.peer]

    if peer && peer.group == params.group && params.status != "ok" &&
         Map.get(params.result, :reason) != "stale_peer",
       do: update_peer(state, peer, ConferenceRecovery.exhausted(peer)),
       else: {state, []}
  end

  defp handle(state, :peer_reset, %{peer: message}) do
    peer = state.peers[message.from]

    if valid_pair?(state, peer, message) && message.peer_generation > peer.peer_generation do
      serial = state.serial + 1
      seat = Enum.find(state.seats, &(&1.id == peer.id))

      next = %{
        ConferencePeer.new(seat, state.self_id, "peer:#{serial}")
        | peer_generation: message.peer_generation,
          rebuilds: peer.rebuilds + 1
      }

      {%{state | serial: serial, peers: Map.put(state.peers, peer.id, next)},
       [{:close, peer.group}, {:peer_native, peer.id, 0, :create, nil}]}
    else
      {state, []}
    end
  end

  defp handle(state, :peer_job, %{peer: id, group: group, job: job}) do
    peer = state.peers[id]

    if peer && peer.group == group,
      do: update_peer(state, peer, ConferencePeer.enqueue(peer, job, state)),
      else: {state, []}
  end

  defp handle(state, :signal, %{signal: message}) do
    peer = state.peers[message.from]

    if valid_pair?(state, peer, message) && message.peer_generation == peer.peer_generation do
      update_peer(state, peer, ConferencePeer.enqueue(peer, message.data, state))
    else
      {state, []}
    end
  end

  defp handle(state, :native_result, %{event: event, kind: kind} = params)
       when event in ["capture", "device_ready", "ended", "device_status", "mute", "unmute"] do
    device = state.devices[kind]

    if device.group != params.group do
      {state, []}
    else
      device_result(state, kind, device, event, params)
    end
  end

  defp handle(state, :native_result, %{peer: id} = params) do
    peer = state.peers[id]

    if peer && peer.group == params.group do
      peer_result(state, peer, params)
    else
      {state, []}
    end
  end

  defp handle(state, :native_result, %{event: "video_play"}), do: {state, []}

  defp device_result(state, kind, device, "capture", %{status: "ok", result: stream}) do
    {state, [{:adopt_capture, kind, device, stream}]}
  end

  defp device_result(state, kind, device, "device_ready", %{status: "ok", result: result}) do
    next = %{
      device
      | pending: false,
        stream: result.stream,
        track: result.track,
        active: result.active
    }

    tracks_changed(put_device(state, kind, next))
  end

  defp device_result(state, kind, device, "ended", _params) do
    next = %{
      device()
      | error: "#{device_name(kind)} disconnected. You can retry."
    }

    {state, effects} = tracks_changed(put_device(state, kind, next))
    {state, [{:close, device.group} | effects]}
  end

  defp device_result(state, kind, device, event, _params) when event in ["mute", "unmute"] do
    {state, [{:device_status, kind, device}]}
  end

  defp device_result(state, kind, device, "device_status", %{result: active}) do
    publish(put_device(state, kind, %{device | active: active}))
  end

  defp device_result(state, kind, device, _event, params) do
    next = %{device() | error: device_error(kind, params.name)}
    {put_device(state, kind, next), [{:close, device.group}]}
  end

  defp peer_result(state, peer, %{event: "operation", token: token} = params) do
    params =
      if params.status == "ok" and Map.has_key?(params, :result_ref),
        do: Map.put(params, :result, params.result_ref),
        else: params

    if peer.token == token do
      {next, effects} = ConferencePeer.complete(peer, params, state)

      {next, timers} =
        if peer.phase == :creating, do: ConferenceRecovery.started(next), else: {next, []}

      update_peer(state, peer, {next, effects ++ timers})
    else
      {state, []}
    end
  end

  defp peer_result(state, peer, %{event: "recover", token: token}),
    do: update_peer(state, peer, ConferenceRecovery.timeout(peer, token))

  defp peer_result(state, peer, %{event: "negotiate"}),
    do: update_peer(state, peer, ConferencePeer.enqueue(peer, :negotiate, state))

  defp peer_result(state, peer, %{event: "ice", result: %{candidate: candidate}}) do
    {state, if(candidate, do: ConferencePeer.candidate(peer, candidate), else: [])}
  end

  defp peer_result(state, peer, %{event: "track", result: %{track: track}}),
    do: {state, [{:attach_track, peer.id, track}]}

  defp peer_result(state, peer, %{event: "audio", result: audio}) do
    {state, _} = update_peer(state, peer, {%{peer | audio: audio}, []})
    {state, [{:play, peer.id}]}
  end

  defp peer_result(state, peer, %{event: "play"} = params) do
    blocked = params.status != "ok" and Map.get(params, :name) != "AbortError"
    update_peer(state, peer, {%{peer | blocked: blocked}, []})
  end

  defp peer_result(state, peer, %{event: "connection"}),
    do: {state, [{:connection_status, peer.id}]}

  defp peer_result(state, peer, %{event: "connection_status", result: status}) do
    peer = %{peer | connected: status == "connected", connection_state: status}
    state = if status == "connected", do: %{state | error: ""}, else: state
    update_peer(state, peer, ConferenceRecovery.changed(peer, status))
  end

  defp peer_result(state, peer, %{event: "video_track", result: track}),
    do:
      {%{state | peers: Map.put(state.peers, peer.id, %{peer | video_track: track})},
       [{:video_status, peer.id}]}

  defp peer_result(state, peer, %{event: "video_changed"}),
    do: {state, [{:video_status, peer.id}]}

  defp peer_result(state, peer, %{event: "video_status", result: active}),
    do: update_peer(state, peer, {%{peer | video_active: active}, []})

  defp roster(state, snapshot) do
    own = Enum.find(snapshot.seats, &(&1.id == state.self_id))

    if snapshot.epoch != state.epoch or snapshot.roster_revision < state.roster_revision or
         own == nil or own.connection_generation != state.connection_generation do
      {state, []}
    else
      changed = state.own == nil or state.own.conference.generation != own.conference.generation

      state = %{
        state
        | own: own,
          seats: snapshot.seats,
          roster_revision: snapshot.roster_revision
      }

      wanted =
        Map.new(
          Enum.filter(
            snapshot.seats,
            &(&1.id != state.self_id and &1.connected and &1.conference.ready)
          ),
          &{&1.id, &1}
        )

      {peers, effects} =
        Enum.reduce(state.peers, {%{}, []}, fn {id, peer}, {keep, effects} ->
          seat = wanted[id]

          if changed or not own.conference.ready or seat == nil or
               peer.connection_generation != seat.connection_generation or
               peer.conference_generation != seat.conference.generation,
             do: {keep, effects ++ [{:close, peer.group}]},
             else: {Map.put(keep, id, peer), effects}
        end)

      state = %{state | peers: peers}

      if own.conference.ready and state.supported and state.ice_ready do
        Enum.reduce(wanted, {state, effects}, fn {id, seat}, {state, effects} ->
          if Map.has_key?(state.peers, id) do
            {state, effects}
          else
            serial = state.serial + 1
            peer = ConferencePeer.new(seat, state.self_id, "peer:#{serial}")
            state = %{state | serial: serial, peers: Map.put(state.peers, id, peer)}
            {state, effects ++ [{:peer_native, id, 0, :create, nil}]}
          end
        end)
      else
        {state, effects}
      end
    end
  end

  defp tracks_changed(state) do
    {state, effects} =
      Enum.reduce(state.peers, {state, []}, fn {_id, peer}, {state, effects} ->
        {state, next} = update_peer(state, peer, ConferencePeer.enqueue(peer, :sync, state))
        {state, effects ++ next}
      end)

    {state, next} = publish(state)
    {state, effects ++ next}
  end

  defp publish(%{ice_ready: false} = state), do: {%{state | publish_dirty: true}, []}
  defp publish(%{publishing: true} = state), do: {%{state | publish_dirty: true}, []}

  defp publish(state) do
    payload = %{
      epoch: state.epoch,
      connection_generation: state.connection_generation,
      ready: true,
      microphone: state.devices["audio"].active,
      camera: state.devices["video"].active
    }

    {%{state | publishing: true, publish_dirty: false}, [{:publish, payload}]}
  end

  defp request_ice(%{ice_fetching: true} = state), do: {state, []}

  defp request_ice(state) do
    state = %{state | ice_fetching: true, ice_request: state.ice_request + 1}
    {state, [{:cancel_timer, "conference", "ice"}, {:fetch_ice, state.ice_request}]}
  end

  defp ice_timer(_state, nil), do: []

  defp ice_timer(state, delay),
    do: [
      {:later, "conference", "ice", delay, %{event: "refresh_ice", request: state.ice_request}}
    ]

  defp ice_error,
    do:
      "Call network settings could not be refreshed. You can retry; your room is still connected."

  defp configure_peers(state) do
    Enum.reduce(state.peers, {state, []}, fn {_, peer}, {state, effects} ->
      if peer.recovery_stage == :exhausted do
        {state, effects}
      else
        {state, next} = update_peer(state, peer, ConferencePeer.enqueue(peer, :configure, state))
        {state, effects ++ next}
      end
    end)
  end

  defp valid_pair?(state, peer, message) do
    state.own && state.own.conference.ready && peer && message.epoch == state.epoch &&
      message.to_connection_generation == state.connection_generation &&
      message.to_conference_generation == state.own.conference.generation &&
      message.connection_generation == peer.connection_generation &&
      message.conference_generation == peer.conference_generation
  end

  defp update_peer(state, old, {peer, effects}) do
    {errors, effects} = Enum.split_with(effects, &match?({:error, _}, &1))

    error =
      case errors do
        [{:error, error} | _] -> error
        [] -> state.error
      end

    {%{state | peers: Map.put(state.peers, old.id, peer), error: error}, effects}
  end

  defp put_device(state, kind, device),
    do: %{state | devices: Map.put(state.devices, kind, device)}

  defp device,
    do: %{
      track: nil,
      stream: nil,
      group: nil,
      pending: false,
      active: false,
      error: ""
    }

  defp status(%{pending: true}), do: "starting"
  defp status(%{track: nil}), do: "off"
  defp status(_), do: "on"
  defp device_name("audio"), do: "Microphone"
  defp device_name("video"), do: "Camera"

  defp device_error(kind, name) do
    reason =
      case name do
        "NotAllowedError" ->
          "access was denied. Check your browser and system permissions, then retry."

        "NotFoundError" ->
          "was not found. Connect a device and retry."

        "NotReadableError" ->
          "could not be opened. It may be in use by another application."

        "OverconstrainedError" ->
          "could not use the requested settings."

        "SecurityError" ->
          "access was blocked. Use trusted HTTPS and check device permissions."

        _ ->
          "could not be started. Check the device and retry."
      end

    "#{device_name(kind)} #{reason}"
  end
end
