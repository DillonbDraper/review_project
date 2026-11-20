defmodule ReviewProjectWeb.Hologram.ConferenceTilesTest do
  use ExUnit.Case, async: true
  alias ReviewProjectWeb.Hologram.{ConferencePeer, ConferenceState, ConferenceTiles}

  test "tiles include self and connected members before any media or readiness event" do
    state = state()

    assert [
             %{id: "self", local?: true, video?: false},
             %{id: "guest", local?: false, video?: false}
           ] = ConferenceTiles.list(state)

    assert Enum.all?(ConferenceTiles.list(state), &(&1.stream == nil))
  end

  test "reserved disconnected seats stay out of the tile strip" do
    state = state()
    away = %{seat("away") | connected: false}

    assert Enum.map(ConferenceTiles.list(%{state | seats: state.seats ++ [away]}), & &1.id) == [
             "self",
             "guest"
           ]
  end

  test "camera arrival does not reorder participants or replace display names" do
    state = state()
    before = Enum.map(ConferenceTiles.list(state), &{&1.id, &1.name})
    state = live_peer(state)
    assert Enum.map(ConferenceTiles.list(state), &{&1.id, &1.name}) == before
    assert Enum.at(ConferenceTiles.list(state), 1).video?
  end

  test "camera-off roster hides a live remote track and detaches its video binding" do
    state = live_peer(state())

    state = %{
      state
      | seats: Enum.map(state.seats, &%{&1 | conference: %{&1.conference | camera: false}})
    }

    [_, tile] = ConferenceTiles.list(state)
    refute tile.video?
    assert tile.stream == nil
    assert tile.status == "Camera off"
    assert state.peers["guest"].audio == "audio-element"
  end

  test "advertised camera waits for live received video instead of displaying stale frames" do
    state = live_peer(state())
    peer = %{state.peers["guest"] | video_active: false}
    [_, tile] = ConferenceTiles.list(%{state | peers: %{"guest" => peer}})
    refute tile.video?
    assert tile.status == "Waiting for video…"
    assert tile.stream == nil
  end

  test "local preview and microphone status use actual independent local devices" do
    state =
      put_in(state().devices["video"], %{
        track: "local-video",
        stream: "local-stream",
        pending: false,
        active: true
      })

    [tile, _] = ConferenceTiles.list(state)
    assert tile.video?
    assert tile.stream == "local-stream"
    refute tile.microphone?
    state = put_in(state.devices["video"].active, false)
    [tile, _] = ConferenceTiles.list(state)
    refute tile.video?
    assert tile.stream == nil
  end

  test "disconnected peers show reconnecting with a black tile while remaining admitted" do
    state = live_peer(state())
    peer = %{state.peers["guest"] | connected: false, connection_state: "disconnected"}
    [_, tile] = ConferenceTiles.list(%{state | peers: %{"guest" => peer}})
    assert tile.status == "Reconnecting…"
    refute tile.video?
  end

  test "unsupported calling retains named tiles and stopped membership clears them" do
    state = %{state() | supported: false}
    assert length(ConferenceTiles.list(state)) == 2
    assert Enum.all?(ConferenceTiles.list(state), &(&1.status == "Calling unavailable"))
    assert ConferenceTiles.list(%{state | connected: false}) == []
  end

  defp state do
    %{
      ConferenceState.new()
      | connected: true,
        self_id: "self",
        seats: [seat("self"), seat("guest")]
    }
  end

  defp seat(id),
    do: %{
      id: id,
      display_name: "Name #{id}",
      connected: true,
      connection_generation: 1,
      conference: %{ready: false, generation: 0, camera: false, microphone: false}
    }

  defp live_peer(state) do
    guest = %{
      seat("guest")
      | conference: %{ready: true, generation: 1, camera: true, microphone: true}
    }

    peer = %{
      ConferencePeer.new(guest, "self", "peer:1")
      | stream: "remote-stream",
        audio: "audio-element",
        connected: true,
        connection_state: "connected",
        video_track: "remote-video",
        video_active: true
    }

    %{state | seats: [hd(state.seats), guest], peers: %{"guest" => peer}}
  end
end
