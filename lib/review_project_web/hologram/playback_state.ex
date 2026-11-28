defmodule ReviewProjectWeb.Hologram.PlaybackState do
  @moduledoc "Provider-independent client playback timeline, commands, inference and recovery."
  alias ReviewProjectWeb.Hologram.PlaybackIntent

  def new(room_id \\ "") do
    %{
      room_id: room_id,
      generation: 0,
      room_generation: -1,
      connected: room_id == "",
      self_id: nil,
      desired: nil,
      sample: empty_sample(),
      preview: nil,
      loaded_video: nil,
      source: "",
      error: "",
      loading: false,
      source_request: 0,
      serial: 0,
      pending: nil,
      queued: nil,
      snapshot_request: nil,
      next_poll: 0,
      calibrated: room_id == "",
      offset: 0,
      best_rtt: nil,
      enabled: false,
      resume_enabled: false,
      native: PlaybackIntent.new(),
      last_seek: -10000,
      last_transport: -10000,
      next_check: 0,
      force_seek: false
    }
  end

  defp empty_sample do
    %{
      now: 0,
      position: 0,
      duration: 0,
      state: -1,
      playback_rate: 1.0,
      ready: false,
      blocked: false,
      error: "",
      hidden: false,
      focused: false,
      video_id: "",
      volume: 80,
      muted: false,
      live: false,
      preparing: false
    }
  end

  def solo?(state), do: state.room_id == ""

  def controller?(state),
    do:
      state.connected and
        (solo?(state) or
           (state.desired != nil and state.self_id != nil and
              state.desired.controller_id == state.self_id))

  def view(state) do
    duration = state.sample.duration
    playing = state.desired != nil and state.desired.playing

    timeline_at =
      if state.desired != nil and state.calibrated,
        do: max(state.sample.now, state.desired.server_time_ms - state.offset),
        else: state.sample.now

    position =
      cond do
        state.preview != nil -> state.preview
        state.desired == nil -> 0
        state.calibrated -> target(state, timeline_at)
        true -> state.desired.position
      end

    position = if duration > 0, do: min(position, duration), else: position
    ended = duration > 0 and not playing and position >= duration - 0.35

    controller =
      state.desired &&
        Enum.find(Map.get(state.desired, :seats, []), &(&1.id == state.desired.controller_id))

    %{
      source: state.source,
      file_source: state.desired && Map.get(state.desired, :video_source),
      replay_source: get_in(state.desired || %{}, [:video_source, :kind]) == "slippi_replay",
      source_label: source_label(state),
      video_id: state.desired && state.desired.video_id,
      loading?: state.loading,
      playback_error: state.error,
      player_error: state.sample.error,
      ready: state.sample.ready,
      unsupported: state.sample.live,
      can_control: controller?(state),
      connected: state.connected,
      solo: solo?(state),
      playing: playing,
      ended: ended,
      position: position,
      duration: duration,
      elapsed: timestamp(position),
      total: timestamp(duration),
      volume: state.sample.volume,
      muted: state.sample.muted,
      busy: state.pending != nil,
      enabled: state.enabled,
      blocked: state.sample.blocked,
      controller_name:
        if(controller, do: controller.display_name, else: "the playback controller"),
      playback_status: status(state),
      timeline_at: timeline_at,
      rtt: state.best_rtt || 0,
      player_generation: state.generation,
      playback_revision: if(state.desired, do: state.desired.revision, else: 0),
      authority_revision: if(state.desired, do: state.desired.authority_revision, else: 0)
    }
  end

  defp source_label(%{desired: %{video_source: %{kind: "local_file", name: name}}}), do: name
  defp source_label(%{desired: %{video_source: %{kind: "slippi_replay", name: name}}}), do: name

  defp source_label(%{desired: %{video_id: id}}) when is_binary(id),
    do: "https://www.youtube.com/watch?v=" <> id

  defp source_label(_state), do: ""

  def timestamp(seconds) do
    seconds = trunc(max(0, seconds))
    minutes = div(seconds, 60)
    rest = seconds - minutes * 60
    Integer.to_string(minutes) <> ":" <> String.pad_leading(Integer.to_string(rest), 2, "0")
  end

  defp status(state) do
    cond do
      not state.connected ->
        "Join the room to follow its playback."

      state.desired == nil or state.desired.video_id == nil ->
        if(controller?(state),
          do: nil,
          else: "Waiting for the controller to choose a video."
        )

      get_in(state.desired, [:video_source, :available]) == false ->
        "The file source is unavailable. Playback is paused until it returns; the controller then presses Play."

      state.sample.error != "" ->
        "Playback is unavailable on this device. Retry or choose another video."

      state.sample.blocked ->
        "Your browser blocked playback. Enable playback on this device."

      not state.sample.ready ->
        "Preparing the selected video…"

      not state.enabled ->
        "Enable playback on this device to follow the video."

      state.sample.state == 3 ->
        "Buffering on this device. The room continues; you will catch up."

      state.pending != nil ->
        "Updating playback…"

      true ->
        if(solo?(state), do: "Your video workspace.", else: "Following the room timeline.")
    end
  end

  def event(state, event, params) do
    {state, effects} = transition(state, event, params)
    {expect_player(state, effects), effects}
  end

  defp transition(state, :mounted, %{generation: generation}) do
    state = %{
      state
      | generation: generation,
        loaded_video: nil,
        sample: local_sample(state),
        native: PlaybackIntent.new(),
        pending: nil,
        queued: nil,
        preview: nil,
        loading: false,
        snapshot_request: nil,
        next_poll: 0
    }

    reconcile(state)
  end

  defp transition(state, :joined, params) do
    if params.room_generation >= state.room_generation do
      state = %{
        new(state.room_id)
        | generation: params.generation,
          room_generation: params.room_generation,
          connected: true,
          self_id: params.self_id,
          desired: params.snapshot,
          sample: local_sample(state),
          enabled: state.resume_enabled
      }

      {state, effects} = reconcile(state)
      {state, request} = snapshot(state)
      {state, effects ++ request}
    else
      {state, []}
    end
  end

  defp transition(state, :stopped, params) do
    if params.room_generation >= state.room_generation do
      resume = params.mode == "recover" and (state.enabled or state.resume_enabled)

      next = %{
        new(state.room_id)
        | generation: params.generation,
          room_generation: params.room_generation,
          sample: local_sample(state),
          resume_enabled: resume
      }

      {next, []}
    else
      {state, []}
    end
  end

  defp transition(state, event, params) do
    if Map.get(params, :generation, state.generation) == state.generation,
      do: handle(state, event, params),
      else: {state, []}
  end

  defp handle(state, :room_snapshot, params) do
    if state.connected and params.room_generation == state.room_generation do
      {state, _accepted} = accept(state, params.snapshot)
      reconcile(state)
    else
      {state, []}
    end
  end

  defp handle(state, :visible, params) do
    if state.connected and not solo?(state) and Map.get(params, :visible, true),
      do: snapshot(%{state | snapshot_request: nil, calibrated: false, force_seek: true}),
      else: {state, []}
  end

  defp handle(state, :sample, sample) do
    state = %{state | sample: Map.merge(state.sample, Map.drop(sample, [:generation]))}

    state =
      if sample.ready and sample.focused and sample.state == 1,
        do: %{state | enabled: true},
        else: state

    state =
      if sample.live,
        do: %{
          state
          | sample: %{
              state.sample
              | error: "Live/DVR videos are not supported. Choose a prerecorded video."
            }
        },
        else: state

    {state, native_effects} = infer(state)
    {state, effects} = continue(state, true)

    {state, poll} =
      if state.connected and not solo?(state) and sample.now >= state.next_poll,
        do: snapshot(state),
        else: {state, []}

    {state, native_effects ++ effects ++ poll}
  end

  defp handle(state, :local_replay, %{source: source}) do
    if solo?(state) do
      now = state.sample.now

      desired = %{
        video_id: "slippi_replay:" <> source.id,
        video_source: source,
        position: 0,
        playing: false,
        revision: 0,
        epoch: "solo",
        authority_revision: 0,
        controller_id: nil,
        server_time_ms: now
      }

      reconcile(%{
        state
        | desired: desired,
          enabled: true,
          pending: nil,
          queued: nil,
          loading: false,
          preview: nil,
          native: PlaybackIntent.reset(),
          force_seek: true
      })
    else
      {state, []}
    end
  end

  defp handle(state, :source, %{value: value}), do: {%{state | source: value, error: ""}, []}

  defp handle(state, :select, %{source: source}) do
    if controller?(state) and state.pending == nil and not state.loading do
      id = state.source_request + 1

      {%{state | source: source, loading: true, source_request: id, error: ""},
       [{:resolve, source, id}]}
    else
      {state, []}
    end
  end

  defp handle(state, :resolved, params) do
    if params.request == state.source_request and state.loading and controller?(state) do
      state = %{
        state
        | loading: false,
          native: PlaybackIntent.reset(),
          queued: nil,
          next_check: 0
      }

      submit(state, %{op: "video", video_id: params.video_id})
    else
      {state, []}
    end
  end

  defp handle(state, :invalid, params) do
    if params.request == state.source_request do
      {%{
         state
         | loading: false,
           error:
             "Enter an individual prerecorded YouTube link or video ID. Live streams and playlists alone are not supported."
       }, []}
    else
      {state, []}
    end
  end

  defp handle(state, :enable, _) do
    state = %{
      state
      | enabled: true,
        native: PlaybackIntent.reset()
    }

    # Execute play directly in this local gesture rather than awaiting the room.
    effects =
      if state.sample.ready and not state.sample.live and state.sample.error == "" and
           state.desired != nil and state.desired.playing,
         do: [{:native, "play", nil}],
         else: []

    {state, more} = reconcile(%{state | last_transport: -10000})
    {state, effects ++ more}
  end

  defp handle(state, :toggle, _) do
    cond do
      not controller?(state) or state.desired == nil or state.pending != nil or state.sample.live ->
        {state, []}

      true ->
        replay = view(state).ended
        playing = replay or not state.desired.playing

        command =
          cond do
            replay -> %{op: "set_playback", position: 0, playing: true}
            playing -> %{op: "play"}
            true -> %{op: "pause"}
          end

        {state, effects} =
          submit(%{state | enabled: true, native: PlaybackIntent.reset(), queued: nil}, command)

        # The controller's click also supplies local browser activation. The
        # pending command already protects this optimistic action from echoes.
        operation = if playing, do: "play", else: "pause"

        local =
          if replay,
            do: [{:native, "seek", 0}, {:native, "play", nil}],
            else: [{:native, operation, nil}]

        {state, effects ++ Enum.reject(local, &(&1 in effects))}
    end
  end

  defp handle(state, :preview_seek, %{position: position}) do
    if controller?(state) and state.pending == nil and is_number(position) and
         state.sample.duration > 0 do
      {%{state | preview: max(0, min(position, state.sample.duration))}, []}
    else
      {state, []}
    end
  end

  defp handle(state, :seek, %{position: position} = params) do
    authority = state.desired && state.desired.authority_revision
    revision = state.desired && state.desired.revision

    if controller?(state) and state.pending == nil and is_number(position) and position >= 0 and
         state.sample.duration > 0 and
         Map.get(params, :authority_revision, authority) == authority and
         Map.get(params, :revision, revision) == revision do
      submit(
        %{state | preview: nil, native: PlaybackIntent.reset(), queued: nil, next_check: 0},
        %{
          op: "seek",
          position: min(position, state.sample.duration)
        }
      )
    else
      {%{state | preview: nil}, []}
    end
  end

  defp handle(state, :volume, %{volume: volume}) when is_number(volume) do
    volume = max(0, min(100, volume))
    {%{state | sample: %{state.sample | volume: volume}}, [{:native, "volume", volume}]}
  end

  defp handle(state, :mute, _) do
    value = not state.sample.muted
    {%{state | sample: %{state.sample | muted: value}}, [{:native, "mute", value}]}
  end

  defp handle(state, :snapshot_result, params) do
    if params.request == state.snapshot_request do
      state = %{state | snapshot_request: nil, next_poll: params.received_at_ms + 2000}

      if params.status == "ok" do
        rtt = params.received_at_ms - params.sent_at_ms
        state = %{state | calibrated: true}

        state =
          if state.best_rtt == nil or rtt < state.best_rtt,
            do: %{
              state
              | best_rtt: rtt,
                offset:
                  params.result.server_time_ms - (params.sent_at_ms + params.received_at_ms) / 2,
                calibrated: true
            },
            else: state

        {state, _} = accept(state, params.result)

        state =
          if state.pending != nil and state.pending.resync,
            do: %{state | pending: nil},
            else: state

        continue(state)
      else
        {%{
           state
           | pending: nil,
             calibrated: false,
             error: "Waiting for the room connection. Playback is paused locally."
         }, [{:native, "pause", nil}]}
      end
    else
      {state, []}
    end
  end

  defp handle(state, :control_result, params) do
    if state.pending != nil and state.pending.id == params.request do
      if params.status == "ok" do
        {state, _} = accept(state, params.result)
        continue(%{state | pending: nil, error: ""})
      else
        state = %{
          state
          | pending: %{state.pending | resync: true},
            snapshot_request: nil,
            error: "Playback changed before that action completed. Refreshing the room state."
        }

        snapshot(state)
      end
    else
      {state, []}
    end
  end

  defp handle(state, _, _), do: {state, []}

  defp local_sample(state),
    do: Map.merge(empty_sample(), Map.take(state.sample, [:volume, :muted]))

  defp expect_player(state, effects) do
    expected =
      Enum.reduce(effects, %{position: nil, playing: nil}, fn
        {:native, "seek", position}, expected -> %{expected | position: position}
        {:native, "play", _}, expected -> %{expected | playing: true}
        {:native, "pause", _}, expected -> %{expected | playing: false}
        _, expected -> expected
      end)

    if expected.position != nil or expected.playing != nil,
      do: %{state | native: PlaybackIntent.commanded(state.native, state.sample, expected)},
      else: state
  end

  defp inferred(state, command) do
    if state.pending != nil,
      do: {%{state | queued: %{command: command, at: state.sample.now}}, []},
      else: submit(state, command)
  end

  defp intent_playing(state) do
    command =
      cond do
        state.queued != nil -> state.queued.command
        state.pending != nil -> state.pending.command
        true -> %{}
      end

    case command do
      %{op: "play"} -> true
      %{op: "pause"} -> false
      %{playing: playing} -> playing
      _ -> state.desired.playing
    end
  end

  defp continue(state, fresh? \\ false) do
    if state.calibrated and state.queued != nil and state.pending == nil and
         state.native.pending == nil and
         controller?(state) do
      command = state.queued.command

      elapsed =
        if command.playing and state.sample.state == 1,
          do: max(0, state.sample.now - state.queued.at) / 1000,
          else: 0

      submit(state, %{command | position: command.position + elapsed})
    else
      reconcile(state, fresh?)
    end
  end

  defp snapshot(state) do
    if state.snapshot_request == nil do
      id = state.serial + 1

      {%{state | serial: id, snapshot_request: id, next_poll: state.sample.now + 2000},
       [{:snapshot, id}]}
    else
      {state, []}
    end
  end

  defp accept(state, incoming) do
    old = state.desired

    fresh =
      old == nil or
        (incoming.epoch == old.epoch and
           (incoming.revision > old.revision or
              (incoming.revision == old.revision and incoming.server_time_ms >= old.server_time_ms)))

    if fresh do
      changed = old == nil or incoming.revision != old.revision
      authority_changed = old != nil and incoming.authority_revision != old.authority_revision

      transport_changed =
        old != nil and incoming.playing != old.playing and
          get_in(incoming, [:video_source, :kind]) == "local_file"

      availability_changed =
        old != nil and
          get_in(old, [:video_source, :available]) !=
            get_in(incoming, [:video_source, :available])

      force =
        changed and old != nil and incoming.video_id == old.video_id and
          abs(incoming.position - target(state, state.sample.now)) > 0.15

      next = %{
        state
        | desired: incoming,
          loaded_video: if(availability_changed, do: nil, else: state.loaded_video),
          sample: if(availability_changed, do: local_sample(state), else: state.sample),
          last_transport: if(transport_changed, do: -10000, else: state.last_transport),
          next_check: if(transport_changed, do: 0, else: state.next_check),
          force_seek: state.force_seek or force,
          pending: if(authority_changed, do: nil, else: state.pending),
          queued:
            if(authority_changed or (old != nil and incoming.video_id != old.video_id),
              do: nil,
              else: state.queued
            ),
          preview:
            if(authority_changed or (old != nil and incoming.video_id != old.video_id),
              do: nil,
              else: state.preview
            ),
          loading: if(authority_changed, do: false, else: state.loading),
          native:
            if(authority_changed or (old != nil and incoming.video_id != old.video_id),
              do: PlaybackIntent.reset(),
              else: state.native
            )
      }

      {next, true}
    else
      {state, false}
    end
  end

  defp submit(state, command) do
    if controller?(state) and state.pending == nil and
         (state.desired != nil or command.op == "video") do
      now = state.sample.now
      state = %{state | error: "", queued: nil}

      if solo?(state) do
        old =
          state.desired ||
            %{
              video_source: nil,
              video_id: nil,
              playing: false,
              position: 0,
              revision: 0,
              epoch: "solo",
              authority_revision: 0,
              controller_id: nil,
              server_time_ms: now
            }

        position = if state.desired, do: target(state, now), else: 0
        next = %{old | revision: old.revision + 1, server_time_ms: now, position: position}

        next =
          case command.op do
            "video" ->
              Map.merge(next, %{
                video_id: command.video_id,
                video_source: nil,
                position: 0,
                playing: false
              })

            "seek" ->
              %{next | position: command.position}

            "set_playback" ->
              %{next | position: command.position, playing: command.playing}

            "play" ->
              %{next | playing: true}

            "pause" ->
              %{next | playing: false}
          end

        reconcile(%{
          state
          | desired: next,
            force_seek: command.op in ["video", "seek", "set_playback"]
        })
      else
        id = state.serial + 1

        payload =
          Map.merge(command, Map.take(state.desired, [:epoch, :revision, :authority_revision]))

        pending = %{
          id: id,
          resync: false,
          command: command,
          guards: Map.take(payload, [:epoch, :revision, :authority_revision])
        }

        {%{state | serial: id, pending: pending}, [{:control, payload, id}]}
      end
    else
      {state, []}
    end
  end

  defp infer(state) do
    cond do
      not state.connected or state.desired == nil or state.sample.error != "" or state.sample.live or
          state.sample.video_id != state.desired.video_id ->
        {state, []}

      controller?(state) and state.sample.ready and state.native.expected == nil and
        state.sample.state == 0 and state.desired.playing and state.sample.duration > 0 and
        not state.sample.blocked and
          state.sample.error == "" ->
        inferred(state, %{op: "set_playback", position: state.sample.duration, playing: false})

      controller?(state) and state.native.expected == nil and state.sample.ready and
        state.sample.focused and not state.sample.hidden and
        state.sample.state == 1 and state.sample.position < 1 and not state.desired.playing and
        state.sample.duration > 0 and state.desired.position >= state.sample.duration - 0.35 ->
        inferred(state, %{op: "set_playback", position: state.sample.position, playing: true})

      true ->
        sample =
          Map.merge(state.sample, %{
            controller: controller?(state),
            desired_playing: intent_playing(state)
          })

        {intent, command} = PlaybackIntent.observe(state.native, sample)
        state = %{state | native: intent}
        if command, do: inferred(state, Map.put(command, :op, "set_playback")), else: {state, []}
    end
  end

  def target(state, now) do
    snapshot = state.desired

    snapshot.position +
      if(snapshot.playing,
        do: max(0, now + state.offset - snapshot.server_time_ms) / 1000,
        else: 0
      )
  end

  defp reconcile(state, fresh? \\ false) do
    id = state.desired && state.desired.video_id
    now = state.sample.now

    state =
      if get_in(state.desired || %{}, [:video_source, :kind]) == "slippi_replay",
        do: %{state | enabled: true},
        else: state

    cond do
      not state.connected ->
        {state, []}

      id == nil and state.loaded_video != nil ->
        {%{state | loaded_video: nil, sample: local_sample(state)}, [{:clear_player}]}

      id == nil ->
        {state, []}

      id != state.loaded_video ->
        {%{
           state
           | loaded_video: id,
             sample: %{state.sample | ready: false, duration: 0, position: 0},
             native: PlaybackIntent.reset()
         }, [{:load, id}]}

      not fresh? or (state.sample.hidden and state.sample.muted) ->
        {state, []}

      not state.sample.preparing and state.sample.video_id not in ["", id] and
          state.sample.error == "" ->
        {%{state | native: PlaybackIntent.reset()}, [{:load, id}]}

      state.pending != nil or state.queued != nil or state.native.pending != nil or
          state.native.expected != nil ->
        {state, []}

      not state.calibrated or not state.sample.ready or not state.enabled or
        state.sample.blocked or state.sample.error != "" or state.sample.live ->
        {state, []}

      now < state.next_check and
          not (state.force_seek and get_in(state.desired, [:video_source, :kind]) == "local_file") ->
        {state, []}

      state.sample.video_id != id ->
        {%{state | native: PlaybackIntent.reset()}, [{:load, id}]}

      true ->
        correct(state)
    end
  end

  defp correct(state) do
    now = state.sample.now
    state = %{state | next_check: now + 500}
    playing = state.desired.playing
    duration = state.sample.duration
    target = target(state, now)
    target = if duration > 0, do: min(target, duration), else: target
    tolerance = if playing, do: 0.2, else: 0.15
    uploaded? = get_in(state.desired, [:video_source, :kind]) == "local_file"
    drift = target - state.sample.position
    buffering = state.sample.state == 3
    at_end = state.sample.state == 0 and duration > 0 and target >= duration - 0.35

    # Repeated small HTML5 seeks can cost as much decode time as the drift they
    # correct, leaving the player in a seek/wait loop during an active call.
    # Correct modest playing drift with local speed; explicit/large jumps still
    # seek, and YouTube keeps its existing reconciliation policy.
    seek_tolerance = if uploaded? and playing and not state.force_seek, do: 0.5, else: tolerance

    seek =
      not at_end and abs(drift) > seek_tolerance and
        (state.force_seek or (now - state.last_seek >= 1000 and not buffering))

    transport =
      cond do
        playing and state.sample.state != 1 and not buffering and
            not at_end ->
          "play"

        not playing and state.sample.state not in [-1, 2, 5, 0] ->
          "pause"

        true ->
          nil
      end

    rate =
      cond do
        not playing or state.sample.state != 1 or seek or state.force_seek or at_end -> 1.0
        drift > 0.1 -> 1.05
        drift < -0.1 -> 0.95
        true -> 1.0
      end

    effects =
      if uploaded? and state.sample.playback_rate != rate,
        do: [{:native, "rate", rate}],
        else: []

    effects = effects ++ if(seek, do: [{:native, "seek", target}], else: [])
    state = if seek, do: %{state | last_seek: now}, else: state

    {state, effects} =
      if transport != nil and now - state.last_transport >= 1500 do
        {%{state | last_transport: now}, effects ++ [{:native, transport, nil}]}
      else
        {state, effects}
      end

    state = %{state | force_seek: false}

    {state, effects}
  end
end
