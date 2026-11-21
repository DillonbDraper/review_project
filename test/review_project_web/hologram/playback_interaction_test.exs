defmodule ReviewProjectWeb.Hologram.PlaybackInteractionTest do
  use ExUnit.Case, async: true
  alias ReviewProjectWeb.Hologram.PlaybackState, as: Playback

  # A settled player, after preparation and clock calibration.
  defp settled(playing \\ true, room? \\ false) do
    state = %{
      Playback.new(if(room?, do: "room", else: ""))
      | generation: 1,
        connected: true,
        self_id: "host",
        calibrated: true,
        enabled: true,
        loaded_video: "M7lc1UVf-VE",
        next_poll: 1_000_000,
        desired: %{
          video_id: "M7lc1UVf-VE",
          position: 10,
          playing: playing,
          revision: 7,
          epoch: "epoch",
          authority_revision: 1,
          controller_id: "host",
          server_time_ms: 10_000
        }
    }

    {state, []} = sample(state, 10_000, if(playing, do: 1, else: 2), 10)
    state
  end

  defp sample(state, now, code, position) do
    observation =
      Map.merge(state.sample, %{
        generation: 1,
        now: now,
        ready: true,
        state: code,
        position: position,
        duration: 180,
        focused: true,
        video_id: "M7lc1UVf-VE"
      })

    Playback.event(state, :sample, observation)
  end

  defp reply(state, position, revision, at, status \\ "ok") do
    Playback.event(state, :control_result, %{
      request: state.pending.id,
      status: status,
      result: %{state.desired | position: position, revision: revision, server_time_ms: at}
    })
  end

  test "successive native seeks within 1.2 seconds keep the latest position" do
    Enum.reduce([{10_100, 40}, {10_400, 80}, {10_700, 20}], settled(), fn {at, position}, state ->
      {state, []} = sample(state, at, 1, position)
      {state, effects} = sample(state, at + 200, 1, position + 0.2)
      assert state.desired.position == position + 0.2
      assert state.desired.playing
      assert state.native.expected == nil
      refute Enum.any?(effects, &match?({:native, "seek", _}, &1))
      state
    end)
  end

  test "native Play immediately after native Pause survives buffering" do
    {state, []} = sample(settled(), 10_100, 2, 10.1)
    {state, []} = sample(state, 10_300, 2, 10.1)
    refute state.desired.playing
    {state, a} = sample(state, 10_400, 3, 10.1)
    {state, b} = sample(state, 10_500, 1, 10.1)
    {state, c} = sample(state, 10_700, 1, 10.3)
    assert state.desired.playing
    refute Enum.any?(a ++ b ++ c, &match?({:native, "pause", _}, &1))
  end

  test "a playing seek retains play through temporary Pause Buffer Pause and resumes locally" do
    {state, []} = sample(settled(), 10_100, 2, 40)
    {state, []} = sample(state, 10_110, 3, 40)
    {state, []} = sample(state, 10_300, 2, 40)
    {state, effects} = sample(state, 10_500, 2, 40)
    assert state.desired.playing
    assert state.desired.position == 40
    assert {:native, "play", nil} in effects
    {state, a} = sample(state, 10_600, 3, 40)
    {state, b} = sample(state, 11_000, 1, 40.1)
    assert state.desired.playing
    refute Enum.any?(a ++ b, &match?({:native, "pause", _}, &1))
  end

  test "a paused native seek stays paused even when the SDK briefly reports Playing" do
    {state, []} = sample(settled(false), 10_100, 1, 40)
    {state, []} = sample(state, 10_110, 3, 40)
    {state, []} = sample(state, 10_300, 2, 40)
    {state, _} = sample(state, 10_500, 2, 40)
    refute state.desired.playing
    assert state.desired.position == 40
  end

  test "an app Pause is acknowledged without publishing an echo; immediate native Play is accepted" do
    {state, _} = Playback.event(settled(), :toggle, %{})
    revision = state.desired.revision
    assert state.native.expected.playing == false
    {state, []} = sample(state, 10_100, 1, 10.1)
    {state, []} = sample(state, 10_200, 2, 10.1)
    assert state.native.expected == nil
    assert state.desired.revision == revision
    {state, []} = sample(state, 10_300, 1, 10.1)
    {state, effects} = sample(state, 10_500, 1, 10.3)
    assert state.desired.playing
    assert state.desired.revision == revision + 1
    refute {:native, "pause", nil} in effects
  end

  test "new native seek supersedes an app seek before its expected response arrives" do
    {state, _} = Playback.event(settled(), :seek, %{position: 40})
    {state, effects} = sample(state, 10_100, 1, 10.1)
    assert {:native, "seek", 40.1} in effects
    {state, []} = sample(state, 10_200, 1, 80)
    {state, effects} = sample(state, 10_400, 1, 80.2)
    assert state.desired.position == 80.2
    refute Enum.any?(effects, &match?({:native, "seek", _}, &1))
  end

  test "room acknowledgement never rolls back a newer native seek, whether it has settled yet or not" do
    for ack_before_settle <- [true, false] do
      {state, []} = sample(settled(true, true), 10_100, 1, 40)
      {state, [{:control, _, _}]} = sample(state, 10_300, 1, 40.2)
      {state, []} = sample(state, 10_400, 1, 80)

      {state, effects} =
        if ack_before_settle, do: reply(state, 40.2, 8, 10_300), else: {state, []}

      assert effects == []
      {state, effects} = sample(state, 10_600, 1, 80.2)

      {state, effects} =
        if ack_before_settle, do: {state, effects}, else: reply(state, 40.2, 8, 10_300)

      assert [{:control, %{op: "set_playback", position: 80.2, revision: 8}, _}] = effects
      assert state.queued == nil
      {state, []} = reply(state, 80.2, 9, 10_600)
      {state, effects} = sample(state, 10_700, 1, 80.3)
      assert state.desired.revision == 9
      refute Enum.any?(effects, &match?({:native, "seek", _}, &1))
    end
  end

  test "room pending input coalesces to the latest intent and handoff discards it" do
    {state, _} = sample(settled(true, true), 10_100, 1, 40)
    {state, _} = sample(state, 10_300, 1, 40.2)
    {state, _} = sample(state, 10_400, 1, 80)
    {state, _} = sample(state, 10_600, 1, 80.2)
    {state, _} = sample(state, 10_700, 1, 120)
    {state, _} = sample(state, 10_900, 1, 120.2)
    assert state.queued.command.position == 120.2
    {_, effects} = reply(state, 40.2, 8, 10_300)
    assert [{:control, %{position: 120.2}, _}] = effects
    snapshot = %{state.desired | controller_id: "guest", authority_revision: 2, revision: 8}

    {state, []} =
      Playback.event(state, :room_snapshot, %{room_generation: -1, snapshot: snapshot})

    assert state.queued == nil
    assert state.pending == nil
    refute Playback.controller?(state)
  end

  test "rejection refreshes the room before submitting newer input without retrying the rejected seek" do
    {state, _} = sample(settled(true, true), 10_100, 1, 40)
    {state, _} = sample(state, 10_300, 1, 40.2)
    {state, _} = sample(state, 10_400, 1, 80)
    {state, _} = sample(state, 10_600, 1, 80.2)
    {state, [{:snapshot, request}]} = reply(state, 40.2, 8, 10_300, "error")
    assert state.pending.resync
    snapshot = %{state.desired | revision: 8, server_time_ms: 10_650}

    {state, effects} =
      Playback.event(state, :snapshot_result, %{
        request: request,
        status: "ok",
        sent_at_ms: 10_600,
        received_at_ms: 10_700,
        result: snapshot
      })

    assert [{:control, %{position: 80.2, revision: 8}, _}] = effects
    assert state.queued == nil
  end

  test "roster messages cannot repeatedly cue a new source using an old player observation" do
    state = settled(true, true)

    snapshot = %{
      state.desired
      | video_id: "aqz-KE-bpKQ",
        position: 0,
        playing: false,
        revision: 8
    }

    {state, [{:load, "aqz-KE-bpKQ"}]} =
      Playback.event(state, :room_snapshot, %{
        room_generation: -1,
        snapshot: snapshot
      })

    {_, []} = Playback.event(state, :room_snapshot, %{room_generation: -1, snapshot: snapshot})
  end

  test "explicitly selecting the current source resets to paused zero without inheriting native intent" do
    {state, _} = sample(settled(), 10_100, 1, 40)
    {state, _} = Playback.event(state, :select, %{source: "M7lc1UVf-VE"})

    {state, _} =
      Playback.event(state, :resolved, %{request: state.source_request, video_id: "M7lc1UVf-VE"})

    {state, effects} = sample(state, 10_200, 1, 40.1)
    assert state.desired.position == 0
    refute state.desired.playing
    assert {:native, "seek", 0} in effects
    assert {:native, "pause", nil} in effects
  end
end
