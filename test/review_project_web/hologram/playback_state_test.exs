defmodule ReviewProjectWeb.Hologram.PlaybackStateTest do
  use ExUnit.Case, async: true
  alias ReviewProjectWeb.Hologram.{PlaybackState, PlaybackIntent}

  defp snapshot(attrs \\ %{}) do
    Map.merge(
      %{
        epoch: "epoch",
        revision: 1,
        authority_revision: 1,
        controller_id: "host",
        video_id: "M7lc1UVf-VE",
        position: 10,
        playing: false,
        server_time_ms: 1000,
        seats: [%{id: "host", display_name: "Host"}],
        roster_revision: 1
      },
      attrs
    )
  end

  defp joined(attrs \\ %{}, self_id \\ "host") do
    {state, _} =
      PlaybackState.event(PlaybackState.new("room"), :joined, %{
        generation: 1,
        room_generation: 1,
        self_id: self_id,
        snapshot: snapshot(attrs)
      })

    request = state.snapshot_request

    {state, _} =
      PlaybackState.event(state, :snapshot_result, %{
        generation: 1,
        request: request,
        status: "ok",
        sent_at_ms: 100,
        received_at_ms: 200,
        result: snapshot(attrs)
      })

    state
  end

  defp sample(state, now, attrs \\ %{}) do
    observation =
      Map.merge(state.sample, %{
        now: now,
        ready: true,
        state: 2,
        position: 10,
        duration: 100,
        focused: true,
        video_id: "M7lc1UVf-VE"
      })
      |> Map.merge(attrs)

    PlaybackState.event(state, :sample, Map.put(observation, :generation, state.generation))
  end

  test "projection uses calibrated monotonic time and obsolete snapshots cannot rewind it" do
    state = joined(%{playing: true})
    assert PlaybackState.target(state, 2100) == 11.95

    {next, _} =
      PlaybackState.event(state, :room_snapshot, %{
        room_generation: 1,
        snapshot: snapshot(%{revision: 0, position: 0})
      })

    assert next.desired == state.desired

    {next, _} =
      PlaybackState.event(state, :room_snapshot, %{
        room_generation: 1,
        snapshot: snapshot(%{epoch: "old", revision: 99})
      })

    assert next.desired == state.desired
  end

  test "native pause is held through broadcast and acknowledgement without corrective play or seek" do
    state = joined(%{playing: true})
    {state, _} = sample(state, 2000, %{state: 1, position: 11.9})
    {state, effects} = sample(state, 2100, %{state: 2, position: 12.0})
    assert state.native.pending != nil
    assert effects == []
    {state, effects} = sample(state, 2300, %{state: 2, position: 12.0})
    assert [{:control, payload, request}] = Enum.filter(effects, &match?({:control, _, _}, &1))
    assert payload.op == "set_playback" and payload.playing == false and payload.position == 12.0
    refute Enum.any?(effects, &match?({:native, _, _}, &1))
    updated = snapshot(%{revision: 2, position: 12.0, playing: false, server_time_ms: 3200})

    {state, effects} =
      PlaybackState.event(state, :room_snapshot, %{room_generation: 1, snapshot: updated})

    assert state.pending != nil
    assert effects == []

    {state, effects} =
      PlaybackState.event(state, :control_result, %{
        generation: 1,
        request: request,
        status: "ok",
        result: updated
      })

    assert state.pending == nil
    refute Enum.any?(effects, &match?({:native, "play", _}, &1))
  end

  test "playing seeks preserve intent through temporary pause and buffering" do
    base = %{
      controller: true,
      focused: true,
      hidden: false,
      ready: true,
      blocked: false,
      desired_playing: true
    }

    {intent, nil} =
      PlaybackIntent.observe(
        PlaybackIntent.new(),
        Map.merge(base, %{now: 0, position: 20, state: 1})
      )

    {intent, nil} =
      PlaybackIntent.observe(intent, Map.merge(base, %{now: 100, position: 30, state: 2}))

    for state <- [1, 2] do
      {buffered, nil} =
        PlaybackIntent.observe(intent, Map.merge(base, %{now: 110, position: 30, state: 3}))

      assert buffered.pending.kind == :seek

      {settling, nil} =
        PlaybackIntent.observe(buffered, Map.merge(base, %{now: 300, position: 30, state: state}))

      {_, command} =
        PlaybackIntent.observe(
          settling,
          Map.merge(base, %{now: 500, position: if(state == 1, do: 30.2, else: 30), state: state})
        )

      assert command.playing
    end
  end

  test "followers never publish native actions; volume and mute stay local" do
    state = joined(%{}, "guest")
    {state, _} = sample(state, 2000)
    {state, _} = sample(state, 2100, %{position: 50, state: 1})
    {state, effects} = sample(state, 2400, %{position: 50.3, state: 1})
    refute Enum.any?(effects, &match?({:control, _, _}, &1))
    assert state.pending == nil
    {state, effects} = PlaybackState.event(state, :volume, %{volume: 25})
    assert effects == [{:native, "volume", 25}]
    {_, effects} = PlaybackState.event(state, :mute, %{})
    assert effects == [{:native, "mute", true}]
  end

  test "authority handoff drops old pending input and enables the new controller" do
    state = joined()
    {state, _} = PlaybackState.event(state, :toggle, %{})
    old_request = state.pending.id
    new = snapshot(%{authority_revision: 2, revision: 2, controller_id: "guest"})
    {state, _} = PlaybackState.event(state, :room_snapshot, %{room_generation: 1, snapshot: new})
    refute PlaybackState.controller?(state)
    assert state.pending == nil

    {state, _} =
      PlaybackState.event(state, :control_result, %{
        generation: 1,
        request: old_request,
        status: "ok",
        result: snapshot()
      })

    assert state.desired == new
    guest = joined(%{}, "guest")
    {guest, _} = PlaybackState.event(guest, :room_snapshot, %{room_generation: 1, snapshot: new})
    assert PlaybackState.controller?(guest)
  end

  test "end is committed only by the controller and replay is atomic" do
    state = joined(%{playing: true})
    {state, effects} = sample(state, 2000, %{state: 0, position: 100})
    assert [{:control, %{op: "set_playback", position: 100, playing: false}, request}] = effects
    ended = snapshot(%{revision: 2, position: 100, playing: false, server_time_ms: 2900})

    {state, _} =
      PlaybackState.event(state, :control_result, %{
        generation: 1,
        request: request,
        status: "ok",
        result: ended
      })

    assert PlaybackState.view(state).ended
    {_, effects} = PlaybackState.event(state, :toggle, %{})

    assert Enum.any?(
             effects,
             &match?({:control, %{op: "set_playback", position: 0, playing: true}, _}, &1)
           )

    {_, effects} = sample(joined(%{playing: true}, "guest"), 2000, %{state: 0, position: 100})
    refute Enum.any?(effects, &match?({:control, _, _}, &1))
  end

  test "rejection requests a new snapshot instead of reusing an outstanding poll" do
    state = joined()
    {state, _} = PlaybackState.event(state, :toggle, %{})
    old = state.pending.id
    {state, _} = PlaybackState.event(state, :visible, %{})
    poll = state.snapshot_request

    {state, effects} =
      PlaybackState.event(state, :control_result, %{
        generation: 1,
        request: old,
        status: "error",
        result: %{reason: "stale_revision"}
      })

    assert [{:snapshot, fresh}] = effects
    refute fresh == poll
    assert state.pending.resync

    {next, _} =
      PlaybackState.event(state, :snapshot_result, %{
        generation: 1,
        request: poll,
        status: "ok",
        result: snapshot(),
        sent_at_ms: 200,
        received_at_ms: 300
      })

    assert next == state
  end

  test "disconnect clears commands, preserves enable only for recovery, and rejects stale native events" do
    state = joined()
    {state, _} = PlaybackState.event(state, :enable, %{})

    {stopped, []} =
      PlaybackState.event(state, :stopped, %{room_generation: 2, generation: 2, mode: "recover"})

    refute stopped.connected
    assert stopped.resume_enabled
    {next, []} = PlaybackState.event(stopped, :sample, Map.put(state.sample, :generation, 1))
    assert next == stopped

    {left, []} =
      PlaybackState.event(stopped, :stopped, %{room_generation: 3, generation: 3, mode: "stop"})

    refute left.resume_enabled
  end

  test "buffering does not issue routine seeks or mutate the shared timeline" do
    state = joined(%{playing: true}, "guest")
    {state, _} = PlaybackState.event(state, :enable, %{})
    {_, effects} = sample(state, 2000, %{state: 3, position: 0})
    refute Enum.any?(effects, &match?({:native, "seek", _}, &1))
    refute Enum.any?(effects, &match?({:control, _, _}, &1))
  end

  test "Replay acknowledgements cannot turn a stale ended sample into another room-wide stop" do
    state = joined(%{playing: true})
    {state, [{:control, _, ended_request}]} = sample(state, 2000, %{state: 0, position: 100})
    ended = snapshot(%{revision: 2, position: 100, playing: false, server_time_ms: 2850})

    {state, _} =
      PlaybackState.event(state, :control_result, %{
        generation: 1,
        request: ended_request,
        status: "ok",
        result: ended
      })

    {state, _} = PlaybackState.event(state, :toggle, %{})
    request = state.pending.id
    replay = snapshot(%{revision: 3, position: 0, playing: true, server_time_ms: 2950})

    {state, _} =
      PlaybackState.event(state, :control_result, %{
        generation: 1,
        request: request,
        status: "ok",
        result: replay
      })

    {_, effects} = sample(state, 2100, %{state: 0, position: 100})
    refute Enum.any?(effects, &match?({:control, _, _}, &1))
  end

  test "local audio preferences survive reconnect and retry generations" do
    state = joined()
    {state, _} = PlaybackState.event(state, :volume, %{volume: 25})
    {state, _} = PlaybackState.event(state, :mute, %{})

    {state, _} =
      PlaybackState.event(state, :stopped, %{generation: 2, room_generation: 2, mode: "recover"})

    {state, _} =
      PlaybackState.event(state, :joined, %{
        generation: 3,
        room_generation: 3,
        self_id: "host",
        snapshot: snapshot()
      })

    assert PlaybackState.view(state).volume == 25
    assert PlaybackState.view(state).muted
  end

  test "seek preview survives playback ticks and a delayed commit cannot cross revisions" do
    {state, _} = sample(joined(), 2000)
    {state, []} = PlaybackState.event(state, :preview_seek, %{position: 40})
    {state, _} = sample(state, 2100)
    assert PlaybackState.view(state).position == 40
    assert state.pending == nil

    {committed, effects} =
      PlaybackState.event(state, :seek, %{position: 40, authority_revision: 1, revision: 1})

    assert committed.preview == nil
    assert [{:control, %{op: "seek", position: 40}, _}] = effects
    newer = snapshot(%{revision: 2, video_id: "aqz-KE-bpKQ"})

    {state, _} =
      PlaybackState.event(state, :room_snapshot, %{room_generation: 1, snapshot: newer})

    {state, effects} =
      PlaybackState.event(state, :seek, %{position: 40, authority_revision: 1, revision: 1})

    assert state.preview == nil
    assert effects == []
  end

  test "an obsolete seek on the same video releases its preview without sending a command" do
    {state, _} = sample(joined(), 2000)
    {state, _} = PlaybackState.event(state, :preview_seek, %{position: 40})

    {state, _} =
      PlaybackState.event(state, :room_snapshot, %{
        room_generation: 1,
        snapshot: snapshot(%{revision: 2, position: 20})
      })

    {state, effects} =
      PlaybackState.event(state, :seek, %{position: 40, authority_revision: 1, revision: 1})

    assert state.preview == nil
    assert PlaybackState.view(state).position == 20
    assert effects == []
  end

  test "errored and unsupported players never publish inferred playback changes" do
    for attrs <- [%{error: "unavailable"}, %{live: true}] do
      {state, _} = sample(joined(%{playing: true}), 2000, %{state: 1, position: 11.85})
      {state, _} = sample(state, 2100, Map.merge(%{state: 2, position: 30}, attrs))
      {state, effects} = sample(state, 2400, Map.merge(%{state: 2, position: 30}, attrs))
      assert state.pending == nil
      refute Enum.any?(effects, &match?({:control, _, _}, &1))
    end
  end

  test "ended players do not repeatedly seek the difference between duration and the final frame" do
    for playing <- [true, false] do
      state = joined(%{position: 100, playing: playing}, "guest")
      {state, _} = PlaybackState.event(state, :enable, %{})
      {_, effects} = sample(state, 2000, %{state: 0, position: 99.66, duration: 100})
      refute Enum.any?(effects, &match?({:native, _, _}, &1))
    end
  end

  test "fresh snapshots wait for a fresh player sample and project from their own timestamp" do
    {state, _} = sample(joined(%{playing: true}, "guest"), 2000, %{state: 1, position: 11.85})
    {state, _} = PlaybackState.event(state, :enable, %{})
    newer = snapshot(%{revision: 2, position: 30, playing: true, server_time_ms: 5000})

    {state, effects} =
      PlaybackState.event(state, :room_snapshot, %{room_generation: 1, snapshot: newer})

    assert effects == []
    assert PlaybackState.view(state).timeline_at == 4150
    assert PlaybackState.view(state).position == 30
    {_, effects} = sample(state, 4200, %{state: 1, position: 12, focused: false})
    assert Enum.any?(effects, &match?({:native, "seek", _}, &1))
  end

  test "unmeasured server clocks never inflate the initial displayed position" do
    {state, _} =
      PlaybackState.event(PlaybackState.new("room"), :joined, %{
        generation: 1,
        room_generation: 1,
        self_id: "guest",
        snapshot: snapshot(%{playing: true, server_time_ms: -500_000_000})
      })

    assert PlaybackState.view(state).position == 10
  end

  test "hidden muted playback defers correction and visibility recalibrates with a slower reply" do
    {state, _} = sample(joined(%{playing: true}, "guest"), 2000, %{state: 1, position: 11.85})
    {state, _} = PlaybackState.event(state, :enable, %{})

    {state, effects} =
      sample(state, 3000, %{state: 1, position: 11.85, hidden: true, muted: true, focused: false})

    refute Enum.any?(effects, &match?({:native, _, _}, &1))
    previous_request = state.snapshot_request
    {state, _} = PlaybackState.event(state, :visible, %{visible: true})
    refute state.calibrated
    refute state.snapshot_request == previous_request

    {state, effects} =
      PlaybackState.event(state, :snapshot_result, %{
        request: state.snapshot_request,
        status: "ok",
        sent_at_ms: 4000,
        received_at_ms: 4500,
        result: snapshot(%{position: 10, playing: true, server_time_ms: 5000})
      })

    assert state.calibrated
    assert state.best_rtt == 100
    assert effects == []

    {_, effects} =
      sample(state, 4600, %{state: 1, position: 11.85, hidden: false, focused: false})

    assert Enum.any?(effects, &match?({:native, "seek", _}, &1))
  end
end
