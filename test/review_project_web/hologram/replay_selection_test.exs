defmodule ReviewProjectWeb.Hologram.ReplaySelectionTest do
  use ExUnit.Case, async: true
  alias ReviewProjectWeb.Hologram.{PlaybackState, ReplaySelectionState}

  test "solo selection emits native preparation and accepts only the current callback" do
    playback = PlaybackState.new()

    {state, []} =
      ReplaySelectionState.event(ReplaySelectionState.new(), :open, %{
        playback: playback
      })

    {state, [{:choose, params}]} =
      ReplaySelectionState.event(state, :choose, %{playback: playback})

    assert params.solo

    result = %{
      request: params.request,
      generation: params.generation,
      status: "accepted",
      message: "",
      result: source()
    }

    assert {^state, []} =
             ReplaySelectionState.event(state, :result, %{
               playback: playback,
               result: %{result | generation: -1}
             })

    {next, [{:local, source}, :cancel]} =
      ReplaySelectionState.event(state, :result, %{playback: playback, result: result})

    refute next.open
    {playback, [{:load, _}]} = PlaybackState.event(playback, :local_replay, %{source: source})
    refute playback.desired.playing
    assert playback.desired.position == 0
    assert playback.enabled
    assert PlaybackState.view(playback).replay_source
  end

  test "cancellation invalidates pending callbacks without changing playback" do
    playback = PlaybackState.new()

    {state, _} =
      ReplaySelectionState.event(ReplaySelectionState.new(), :open, %{
        playback: playback
      })

    {state, [{:choose, params}]} =
      ReplaySelectionState.event(state, :choose, %{playback: playback})

    {state, [:cancel]} = ReplaySelectionState.event(state, :close, %{playback: playback})
    result = Map.merge(params, %{status: "accepted", message: "", result: source()})

    assert {^state, []} =
             ReplaySelectionState.event(state, :result, %{playback: playback, result: result})
  end

  test "replays follow automatically and switching to YouTube preserves local volume" do
    state = PlaybackState.new()
    state = %{state | sample: %{state.sample | volume: 23, muted: true}}
    {state, _} = PlaybackState.event(state, :local_replay, %{source: source()})
    {state, _} = PlaybackState.event(state, :select, %{source: "M7lc1UVf-VE"})

    {state, _} =
      PlaybackState.event(state, :resolved, %{
        request: state.source_request,
        video_id: "M7lc1UVf-VE"
      })

    refute PlaybackState.view(state).replay_source
    assert state.desired.video_source == nil
    assert state.sample.volume == 23
    assert state.sample.muted
  end

  test "a prepared solo callback cannot replace a source selected later" do
    playback = PlaybackState.new()

    {selection, _} =
      ReplaySelectionState.event(ReplaySelectionState.new(), :open, %{
        playback: playback
      })

    {selection, [{:choose, params}]} =
      ReplaySelectionState.event(selection, :choose, %{playback: playback})

    {playback, _} = PlaybackState.event(playback, :select, %{source: "M7lc1UVf-VE"})

    {playback, _} =
      PlaybackState.event(playback, :resolved, %{
        request: playback.source_request,
        video_id: "M7lc1UVf-VE"
      })

    result = Map.merge(params, %{status: "accepted", message: "", result: source()})

    {selection, [:cancel]} =
      ReplaySelectionState.event(selection, :result, %{playback: playback, result: result})

    refute selection.busy
    assert playback.desired.video_id == "M7lc1UVf-VE"
  end

  defp source,
    do: %{
      id: "opaque",
      handle: "opaque",
      delivery: "local",
      kind: "slippi_replay",
      name: "match.slp",
      frames: 60,
      duration: 1
    }
end
