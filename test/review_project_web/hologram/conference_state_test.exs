defmodule ReviewProjectWeb.Hologram.ConferenceStateTest do
  use ExUnit.Case, async: true
  alias ReviewProjectWeb.Hologram.{ConferencePeer, ConferenceState}

  test "admission publishes receive-only readiness after fetching ICE without capturing devices" do
    {state, effects} = joined()
    assert state.connected
    assert ConferenceState.view(state).microphone == "off"

    assert {:publish,
            %{
              epoch: "epoch",
              connection_generation: 1,
              ready: true,
              microphone: false,
              camera: false
            }} in effects
  end

  test "unsupported calling leaves membership usable without advertising readiness" do
    {state, effects} = joined(false)
    assert state.connected
    refute state.supported
    assert effects == []
  end

  test "pending microphone capture does not block independent camera capture or cancellation" do
    {state, _} = joined()
    {state, [{:capture, "audio", microphone}]} = event(state, :toggle, %{kind: "audio"})
    {state, [{:capture, "video", camera}]} = event(state, :toggle, %{kind: "video"})
    assert microphone.pending and camera.pending

    {state, _} =
      native(state, "video", camera.group, "device_ready", %{
        stream: "camera-stream",
        track: "camera-track",
        active: true
      })

    assert ConferenceState.view(state).microphone == "starting"
    assert ConferenceState.view(state).camera == "on"
    {state, effects} = event(state, :toggle, %{kind: "audio"})
    assert {:close, microphone.group} in effects
    assert ConferenceState.view(state).microphone == "off"
    {late, []} = native(state, "audio", microphone.group, "capture", "old-stream")
    assert late == state
  end

  test "denied devices provide independent errors while remaining joined" do
    {state, _} = joined()

    state =
      Enum.reduce(["audio", "video"], state, fn kind, state ->
        {state, [{:capture, ^kind, device}]} = event(state, :toggle, %{kind: kind})

        {state, [{:close, _}]} =
          event(state, :native_result, %{
            event: "capture",
            kind: kind,
            group: device.group,
            status: "error",
            name: "NotAllowedError"
          })

        state
      end)

    view = ConferenceState.view(state)
    assert view.connected
    assert view.microphone_error =~ "denied"
    assert view.camera_error =~ "denied"
  end

  test "device loss releases only that device and permits retry" do
    {state, _} = joined()
    {state, [{:capture, "video", device}]} = event(state, :toggle, %{kind: "video"})

    {state, _} =
      native(state, "video", device.group, "device_ready", %{
        stream: "stream",
        track: "track",
        active: true
      })

    {state, effects} = native(state, "video", device.group, "ended", %{})
    assert {:close, device.group} in effects
    assert ConferenceState.view(state).camera_error =~ "disconnected"
    {state, [{:capture, "video", replacement}]} = event(state, :toggle, %{kind: "video"})
    assert replacement.group != device.group
    assert state.devices["audio"].track == nil
  end

  test "state publication is serialized and coalesces concurrent device changes" do
    {state, _} = joined()
    {state, [{:capture, "audio", audio}]} = event(state, :toggle, %{kind: "audio"})

    {state, []} =
      native(state, "audio", audio.group, "device_ready", %{
        stream: "stream",
        track: "track",
        active: true
      })

    assert state.publish_dirty
    {state, effects} = event(state, :published, %{status: "ok", result: snapshot(1, true)})
    assert [{:publish, %{microphone: true, camera: false}}] = effects
    assert state.publishing
    refute state.publish_dirty
  end

  test "older rosters cannot resurrect peers and changing generations closes obsolete resources" do
    {state, _} = joined()
    roster = snapshot(1, true, true)

    {state, [{:peer_native, "remote", 0, :create, nil}]} =
      event(state, :roster, %{snapshot: roster})

    peer = state.peers["remote"]
    {state, [{:close, group}]} = event(state, :roster, %{snapshot: snapshot(2, true)})
    assert group == peer.group
    assert {^state, []} = event(state, :roster, %{snapshot: roster})
    {state, _} = event(state, :roster, %{snapshot: %{roster | roster_revision: 3}})
    new_group = state.peers["remote"].group
    refute new_group == peer.group

    assert {^state, []} =
             event(state, :native_result, %{
               event: "operation",
               peer: "remote",
               group: peer.group,
               token: 0,
               status: "ok",
               result: %{pc: "old", stream: "old"}
             })
  end

  test "stopped generations reject all late native and signaling callbacks" do
    {state, _} = joined()
    {state, []} = ConferenceState.event(state, :stopped, %{generation: 2})

    assert {^state, []} =
             ConferenceState.event(state, :published, %{
               generation: 1,
               status: "ok",
               result: snapshot(1, true)
             })

    refute state.connected
    assert state.peers == %{}
  end

  test "each signaling generation is checked before queuing work" do
    {state, _} = ready_peer()

    message = %{
      epoch: "epoch",
      from: "remote",
      connection_generation: 1,
      conference_generation: 1,
      peer_generation: 0,
      to_connection_generation: 1,
      to_conference_generation: 1,
      data: %{type: "candidate", negotiation_id: "offer", candidate: %{candidate: "ice"}}
    }

    for change <- [
          %{epoch: "old"},
          %{connection_generation: 0},
          %{conference_generation: 0},
          %{to_connection_generation: 0},
          %{to_conference_generation: 0}
        ] do
      assert {^state, []} = event(state, :signal, %{signal: Map.merge(message, change)})
    end

    state =
      Enum.reduce(1..150, state, fn _, state ->
        {state, []} = event(state, :signal, %{signal: message})
        state
      end)

    assert length(state.peers["remote"].candidates) == 128
  end

  test "impolite peer ignores colliding offers and their ICE" do
    {context, peer} = peer_context(false)

    data = %{
      type: "description",
      negotiation_id: "collision",
      description: %{type: "offer", sdp: "sdp"}
    }

    {peer, _} = ConferencePeer.enqueue(peer, data, context)

    {peer, []} =
      ConferencePeer.complete(peer, ok(%{remote: true, signaling: "have-local-offer"}), context)

    assert "collision" in peer.ignored

    {peer, []} =
      ConferencePeer.enqueue(
        peer,
        %{type: "candidate", negotiation_id: "collision", candidate: %{}},
        context
      )

    assert peer.candidates == []
  end

  test "polite rollback rebinds video only after the native answer commits" do
    {context, peer} = peer_context(true)
    context = put_in(context.devices["video"], %{track: "video-track", stream: "stream"})
    peer = %{peer | senders: %{"video" => "sender"}}

    data = %{
      type: "description",
      negotiation_id: "collision",
      description: %{type: "offer", sdp: "sdp"}
    }

    {peer, _} = ConferencePeer.enqueue(peer, data, context)

    {peer, [{:peer_native, _, _, :set_remote, _}]} =
      ConferencePeer.complete(peer, ok(%{remote: true, signaling: "have-local-offer"}), context)

    {peer, [{:peer_native, _, _, :sync_track, %{kind: "audio"}}]} =
      ConferencePeer.complete(peer, ok(nil), context)

    {peer, [{:peer_native, _, _, :sync_track, %{kind: "video"}}]} =
      ConferencePeer.complete(peer, ok(nil), context)

    {peer, [{:peer_native, _, _, :set_local, _}]} =
      ConferencePeer.complete(peer, ok("sender"), context)

    {peer, [{:peer_native, _, _, :description, _}]} =
      ConferencePeer.complete(peer, ok(nil), context)

    {peer, [{:peer_native, _, _, :video_sender, _}]} =
      ConferencePeer.complete(peer, ok(%{type: "answer", sdp: "a=ice-ufrag:answer\r\n"}), context)

    {peer, [{:peer_native, _, _, :replace_track, %{track: nil}}]} =
      ConferencePeer.complete(peer, ok("sender"), context)

    {peer, [{:peer_native, _, _, :replace_track, %{track: "video-track"}}]} =
      ConferencePeer.complete(peer, ok(nil), context)

    {peer, [{:signal, _, %{negotiation_id: "collision"}}]} =
      ConferencePeer.complete(peer, ok(nil), context)

    assert peer.phase == :idle

    assert [{:signal, _, %{negotiation_id: "collision"}}] =
             ConferencePeer.candidate(peer, %{usernameFragment: "answer"})
  end

  test "answers to an obsolete local negotiation are ignored" do
    {context, peer} = peer_context(false)
    peer = %{peer | local_id: "current"}

    data = %{
      type: "description",
      negotiation_id: "old",
      description: %{type: "answer", sdp: "sdp"}
    }

    {peer, _} = ConferencePeer.enqueue(peer, data, context)

    {peer, []} =
      ConferencePeer.complete(peer, ok(%{remote: true, signaling: "have-local-offer"}), context)

    assert peer.phase == :idle
    assert peer.local_id == "current"
  end

  test "same-page recovery remembers enabled devices, clears capture, and consumes the preference once" do
    {state, _} = joined()
    {state, [{:capture, "video", camera}]} = event(state, :toggle, %{kind: "video"})

    {state, _} =
      native(state, "video", camera.group, "device_ready", %{
        stream: "s",
        track: "t",
        active: true
      })

    {state, _} = event(state, :toggle, %{kind: "audio"})
    {stopped, []} = ConferenceState.event(state, :stopped, %{generation: 2, mode: "recover"})
    assert stopped.devices["video"].track == nil
    assert stopped.resume.kinds == ["video"]
    {stopped, []} = ConferenceState.event(stopped, :stopped, %{generation: 3, mode: "continue"})

    {resumed, effects} =
      ConferenceState.event(stopped, :joined, %{
        generation: 4,
        supported: true,
        resume: true,
        self_id: "self",
        connection_generation: 1,
        snapshot: snapshot(0, false)
      })

    assert Enum.any?(effects, &match?({:capture, "video", _}, &1))
    refute Enum.any?(effects, &match?({:capture, "audio", _}, &1))
    assert resumed.resume == nil

    for mode <- ["stop", "pagehide"] do
      {fresh, []} = ConferenceState.event(state, :stopped, %{generation: 5, mode: mode})
      assert fresh.resume == nil
    end
  end

  test "credential failures retain working configuration and stale refresh replies are ignored" do
    {state, _} = joined()
    {state, effects} = event(state, :retry_call, %{})
    assert {:fetch_ice, 2} in effects
    {state, _} = event(state, :ice_failed, %{request: 2})
    assert state.ice_ref == "ice-config"
    assert state.ice_error != ""
    assert state.connected
    assert {^state, []} = event(state, :ice_failed, %{request: 1})
  end

  test "background credential renewal respects exhausted peer recovery" do
    {state, _} = ready_peer()
    state = put_in(state.peers["remote"].recovery_stage, :exhausted)
    {state, _} = event(state, :retry_call, %{})
    # Simulate a later failure before the fetch finishes.
    state = put_in(state.peers["remote"].recovery_stage, :exhausted)

    {state, effects} =
      event(state, :ice_ready, %{
        request: state.ice_request,
        group: "ice:2",
        ref: "renewed",
        refresh_after: 30
      })

    assert state.ice_ref == "renewed"
    refute Enum.any?(effects, &match?({:peer_native, _, _, :configure, _}, &1))
    assert state.peers["remote"].recovery_stage == :exhausted
  end

  test "pair replacement closes only the failed pair and rejects its native completions and signals" do
    {state, _} = ready_peer()
    old = state.peers["remote"]

    message = %{
      epoch: "epoch",
      from: "remote",
      connection_generation: 1,
      conference_generation: 1,
      to_connection_generation: 1,
      to_conference_generation: 1,
      peer_generation: 1
    }

    {state, effects} = event(state, :peer_reset, %{peer: message})
    assert {:close, old.group} in effects
    assert state.peers["remote"].peer_generation == 1
    refute state.peers["remote"].group == old.group
    assert state.peers["remote"].rebuilds == 1
    assert {^state, []} = event(state, :peer_reset, %{peer: message})

    assert {^state, []} =
             event(state, :signal, %{signal: Map.merge(message, %{peer_generation: 0, data: %{}})})

    assert {^state, []} =
             event(state, :native_result, %{
               peer: "remote",
               group: old.group,
               event: "recover",
               token: 1
             })
  end

  defp joined(supported \\ true) do
    {state, effects} =
      ConferenceState.event(ConferenceState.new(), :joined, %{
        generation: 1,
        self_id: "self",
        connection_generation: 1,
        snapshot: snapshot(0, false),
        supported: supported
      })

    if supported do
      assert {:fetch_ice, 1} in effects

      event(state, :ice_ready, %{
        request: 1,
        group: "ice:1",
        ref: "ice-config",
        refresh_after: nil
      })
    else
      {state, effects}
    end
  end

  defp ready_peer do
    {state, _} = joined()
    {state, _} = event(state, :roster, %{snapshot: snapshot(1, true, true)})
    peer = state.peers["remote"]

    event(state, :native_result, %{
      event: "operation",
      peer: "remote",
      group: peer.group,
      token: 0,
      status: "ok",
      result: %{pc: "pc", stream: "stream"}
    })
  end

  defp peer_context(polite) do
    {context, _} = ready_peer()
    {context, %{context.peers["remote"] | polite: polite}}
  end

  defp snapshot(revision, ready, remote \\ false) do
    own = %{
      id: "self",
      connected: true,
      connection_generation: 1,
      conference: %{ready: ready, generation: if(ready, do: 1, else: 0)}
    }

    seats =
      if remote,
        do: [own, %{own | id: "remote", conference: %{ready: true, generation: 1}}],
        else: [own]

    %{epoch: "epoch", roster_revision: revision, seats: seats}
  end

  defp event(state, event, params),
    do: ConferenceState.event(state, event, Map.put(params, :generation, 1))

  defp native(state, kind, group, event, result),
    do:
      event(state, :native_result, %{
        event: event,
        kind: kind,
        group: group,
        status: "ok",
        result: result
      })

  defp ok(result), do: %{status: "ok", result: result}
end
