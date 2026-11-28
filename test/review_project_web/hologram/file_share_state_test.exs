defmodule ReviewProjectWeb.Hologram.FileShareStateTest do
  use ExUnit.Case, async: true
  alias ReviewProjectWeb.Hologram.FileShareState, as: Share

  defp source(attrs \\ %{}),
    do:
      Map.merge(
        %{
          kind: "local_file",
          id: "file",
          generation: 1,
          seat_id: "host",
          size: 1000,
          duration: 10.0,
          available: true,
          name: "clip.mp4",
          mime: "video/mp4",
          codec: "video/mp4; codecs=\"avc1.42E01E\""
        },
        attrs
      )

  defp snapshot(attrs \\ %{}),
    do:
      Map.merge(
        %{
          room_id: "room",
          epoch: "epoch",
          revision: 1,
          roster_revision: 1,
          authority_revision: 1,
          controller_id: "host",
          video_source: nil,
          seats: [
            %{id: "host", connected: true, connection_generation: 1},
            %{id: "guest", connected: true, connection_generation: 2}
          ]
        },
        attrs
      )

  defp joined(snapshot \\ snapshot(), self_id \\ "host", retained \\ nil) do
    {state, _} =
      Share.event(Share.new(), :joined, %{
        generation: 1,
        room_generation: 1,
        self_id: self_id,
        connection_generation: if(self_id == "host", do: 1, else: 2),
        snapshot: snapshot,
        retained: retained
      })

    state
  end

  defp owned, do: %{source_id: "file", source_generation: 1, handle: "file:accepted"}

  defp tracks,
    do: %{
      tracks: [
        %{type: "General", format: "MPEG-4", duration: 10.0, codec_id: "isom"},
        %{
          type: "Video",
          format: "AVC",
          duration: 10.0,
          profile: "High",
          bit_depth: 8,
          chroma: "4:2:0"
        }
      ]
    }

  defp preparing(state) do
    {state, _} = Share.event(state, :open, %{})
    {state, [{:choose_file, request}]} = Share.event(state, :choose, %{})

    {state, _} =
      Share.event(state, :chosen, %{
        request: request,
        handle: "file:new",
        name: "new.mp4",
        size: 100
      })

    state
  end

  defp publishing(state) do
    state = preparing(state)
    request = state.selection.request

    {state, [{:check_decode, ^request, _}]} =
      Share.event(state, :inspected, %{request: request, status: "ok", result: tracks()})

    {state, [{:offer, selection}]} =
      Share.event(state, :decoded, %{request: request, supported: true})

    assert selection.guards == Share.selection_guards(state)
    state
  end

  defp connected_receiver do
    state = joined(snapshot(%{video_source: source()}), "guest")

    {state, _} =
      Share.event(state, :ice_ready, %{
        request: state.ice_request,
        ref: "ice:1",
        refresh_after: 60
      })

    state
  end

  defp envelope(state, attrs) do
    Map.merge(
      %{
        epoch: "epoch",
        source_id: "file",
        source_generation: 1,
        from: "host",
        connection_generation: 1,
        to_connection_generation: state.connection_generation,
        peer_generation: 0
      },
      attrs
    )
  end

  defp signal(state, data, attrs \\ %{}), do: envelope(state, Map.merge(%{data: data}, attrs))

  defp offer,
    do: %{type: "description", negotiation_id: "n", description: %{type: "offer", sdp: "bounded"}}

  test "selection inspection failure retains the source and closes only the pending handle" do
    state = joined(snapshot(%{video_source: source()}), "host", owned()) |> preparing()

    {failed, effects} =
      Share.event(state, :inspected, %{
        request: state.selection.request,
        status: "error",
        reason: "inspection_timeout"
      })

    assert failed.source == state.source
    assert failed.owned == state.owned
    assert failed.open
    assert failed.selection == nil
    assert effects == [{:release_file, "file:new"}]
    assert failed.message =~ "ten seconds"
  end

  test "publication acceptance commits the native handle, selects the source and closes the dialog" do
    pending = publishing(joined())
    result = snapshot(%{revision: 2, video_source: source(%{id: "new", generation: 2})})

    {state, effects} =
      Share.event(pending, :offered, %{
        request: pending.selection.request,
        status: "ok",
        result: result
      })

    refute state.open
    assert state.selection == nil
    assert state.owned.source_id == "new"
    assert hd(effects) == {:adopt_file, "file:new", result.video_source}
    assert Enum.any?(effects, &match?({:fetch_ice, _}, &1))
  end

  test "publication rejection and late superseded replies cannot replace the current selection" do
    pending = publishing(joined())

    {failed, effects} =
      Share.event(pending, :offered, %{
        request: pending.selection.request,
        status: "error",
        result: %{reason: "stale_authority"}
      })

    assert failed.source == nil
    assert effects == [{:release_file, "file:new"}]
    {changed, _} = Share.event(pending, :snapshot, %{snapshot: snapshot(%{revision: 5})})

    {changed, effects} =
      Share.event(changed, :offered, %{
        request: pending.selection.request,
        status: "ok",
        result: snapshot(%{revision: 2, video_source: source()})
      })

    assert changed.source == nil
    assert effects == [{:release_file, "file:new"}]
  end

  test "preparation guards fail locally after authority changes and stale callbacks are ignored" do
    state = preparing(joined())

    assert Share.event(state, :inspected, %{
             generation: 0,
             request: state.selection.request,
             status: "ok",
             result: tracks()
           }) == {state, []}

    {state, effects} =
      Share.event(state, :snapshot, %{
        snapshot: snapshot(%{authority_revision: 2, revision: 2, controller_id: "guest"})
      })

    assert state.selection == nil
    refute state.open
    assert {:release_file, "file:new"} in effects
  end

  test "closing or cancelling inspection releases it, while an in-flight accepted offer can still commit" do
    state = preparing(joined())
    {cancelled, effects} = Share.event(state, :cancel, %{})
    assert cancelled.open
    assert cancelled.selection == nil
    assert effects == [{:release_file, "file:new"}]
    pending = publishing(joined())
    {closed, effects} = Share.event(pending, :close, %{})
    refute closed.open
    assert closed.selection == pending.selection
    assert effects == []

    {accepted, _} =
      Share.event(closed, :offered, %{
        request: pending.selection.request,
        status: "ok",
        result: snapshot(%{revision: 2, video_source: source()})
      })

    assert accepted.owned.handle == "file:new"
  end

  test "oversize files and followers cannot start inspection" do
    state = joined() |> preparing()
    {state, _} = Share.event(state, :cancel, %{})
    {state, [{:choose_file, request}]} = Share.event(state, :choose, %{})

    {state, effects} =
      Share.event(state, :chosen, %{
        request: request,
        handle: "large",
        name: "large.mp4",
        size: 1_073_741_825
      })

    assert state.selection == nil
    assert effects == [{:release_file, "large"}]
    follower = joined(snapshot(), "guest")
    assert Share.event(follower, :choose, %{}) == {follower, []}
  end

  test "a guest supplier retains a publishing selection when the host reclaims control" do
    pending = joined(snapshot(%{controller_id: "guest"}), "guest") |> publishing()
    selected = source(%{seat_id: "guest"})

    {pending, _} =
      Share.event(pending, :snapshot, %{
        snapshot: snapshot(%{revision: 3, authority_revision: 2, video_source: selected})
      })

    assert pending.selection.phase == :publishing

    {state, effects} =
      Share.event(pending, :offered, %{
        request: pending.selection.request,
        status: "ok",
        result: snapshot(%{revision: 2, controller_id: "guest", video_source: selected})
      })

    refute Share.controller?(state)
    assert Share.supplier?(state)
    assert Share.owns?(state)
    assert Enum.any?(effects, &match?({:adopt_file, _, _}, &1))
  end

  test "only a retained matching native file restores availability, never playback" do
    params = %{
      generation: 2,
      room_generation: 2,
      self_id: "host",
      connection_generation: 3,
      snapshot: snapshot(%{video_source: source(%{available: false})}),
      retained: owned()
    }

    {state, effects} = Share.event(Share.new(), :joined, params)
    assert {:restore, "file"} in effects
    assert state.restoring
    refute Enum.any?(effects, &match?({:signal, _, %{op: "play"}}, &1))

    for retained <- [nil, %{owned() | source_id: "superseded"}] do
      {state, effects} = Share.event(Share.new(), :joined, %{params | retained: retained})
      assert state.owned == nil
      refute {:restore, "file"} in effects
    end
  end

  test "signals can arrive before admission and are bounded, scoped and queued until native creation completes" do
    message = signal(%{connection_generation: 2}, offer())
    params = %{room_generation: 1, kind: "signal", payload: message}
    {waiting, _} = Share.event(Share.new(), :room_signal, params)

    waiting =
      Enum.reduce(1..100, waiting, fn _, state ->
        elem(Share.event(state, :room_signal, params), 0)
      end)

    assert length(waiting.pending_room) == 64

    {state, _} =
      Share.event(waiting, :joined, %{
        generation: 1,
        room_generation: 1,
        self_id: "guest",
        connection_generation: 2,
        snapshot: snapshot(%{video_source: source()}),
        retained: nil
      })

    assert length(state.early["host"]) == 64

    {state, _} =
      Share.event(state, :ice_ready, %{request: state.ice_request, ref: "ice", refresh_after: nil})

    assert length(state.peers["host"].queue) == 64
    assert state.peers["host"].phase == :creating
  end

  test "signaling does not depend on conferencing and rejects stale scopes" do
    state = connected_receiver()

    for attrs <- [
          %{source_generation: 0},
          %{epoch: "old"},
          %{to_connection_generation: 0},
          %{connection_generation: 0},
          %{peer_generation: 7},
          %{from: "stranger"}
        ] do
      assert Share.event(state, :signal, %{signal: signal(state, offer(), attrs)}) == {state, []}
    end

    {state, _} = Share.event(state, :signal, %{signal: signal(state, offer())})
    assert state.peers["host"].queue == [offer()]
  end

  test "peer replacement invalidates old callbacks and a new connection starts at peer generation zero" do
    state = connected_receiver()
    old = state.peers["host"]

    {state, effects} =
      Share.event(state, :peer_reset, %{peer: envelope(state, %{peer_generation: 1})})

    assert {:close_peer, old.group} in effects
    assert state.peers["host"].peer_generation == 1

    assert Share.event(state, :native, %{
             event: "operation",
             peer: "host",
             group: old.group,
             token: old.token,
             status: "error",
             result: nil
           }) == {state, []}

    seats = [
      %{id: "host", connected: true, connection_generation: 4},
      %{id: "guest", connected: true, connection_generation: 2}
    ]

    {state, _} =
      Share.event(state, :snapshot, %{
        snapshot: snapshot(%{video_source: source(), roster_revision: 2, seats: seats})
      })

    assert state.peers["host"].connection_generation == 4
    assert state.peers["host"].peer_generation == 0
  end

  test "recovery is per peer, deduplicated and cancelled by connection readiness" do
    state = connected_receiver()
    peer = state.peers["host"]

    {state, effects} =
      Share.event(state, :native, %{
        event: "connection",
        peer: "host",
        group: peer.group,
        status: "failed"
      })

    assert [{:later, group, "recovery", 2000, timer}] = effects
    assert group == peer.group

    assert Share.event(state, :native, %{event: "channel_closed", peer: "host", group: group}) ==
             {state, []}

    {state, [{:reset_peer, "host"}]} = Share.event(state, :native, Map.put(timer, :group, group))

    {state, effects} =
      Share.event(state, :reset_result, %{peer: "host", group: group, status: "error"})

    assert [{:later, ^group, "recovery", 4000, _}] = effects
    {state, _} = Share.event(state, :native, %{event: "channel_open", peer: "host", group: group})
    assert Share.event(state, :native, Map.put(timer, :group, group)) == {state, []}
  end

  test "credentials are represented only by scoped native handles and refresh effects" do
    state = connected_receiver()
    assert state.ice_ref == "ice:1"

    {state, effects} =
      Share.event(state, :native, %{event: "refresh_ice", request: state.ice_request})

    assert [{:fetch_ice, request}] = effects

    {state, effects} =
      Share.event(state, :ice_ready, %{request: request, ref: "ice:2", refresh_after: 120})

    assert state.ice_ref == "ice:2"
    assert {:release_ice, "ice:1"} in effects

    assert {:later, "file-ice", "refresh", 120_000, %{event: "refresh_ice", request: request}} in effects

    refute Map.has_key?(state, :servers)
  end

  test "source replacement and stop invalidate delayed native and room events" do
    state = connected_receiver()
    {replaced, effects} = Share.event(state, :snapshot, %{snapshot: snapshot(%{revision: 2})})
    assert replaced.peers == %{}
    assert replaced.source == nil
    assert {:configure_source, nil, "receiver"} in effects
    {stopped, _} = Share.event(replaced, :stopped, %{generation: 2, room_generation: 2})

    assert Share.event(stopped, :room_signal, %{room_generation: 1, kind: "signal", payload: %{}}) ==
             {stopped, []}

    assert Share.event(stopped, :native, %{generation: 1, event: "metrics"}) == {stopped, []}
  end
end
