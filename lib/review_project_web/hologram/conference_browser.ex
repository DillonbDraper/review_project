defmodule ReviewProjectWeb.Hologram.ConferenceBrowser do
  @moduledoc "Elixir browser API calls. Only scoped handles and plain data cross the JS bridge."
  use Hologram.JS
  alias ReviewProjectWeb.Hologram.ConferenceTiles

  js_import from: "../../../assets/js/conference_native.mjs", as: :Native
  js_import from: "../../../assets/js/room_browser.mjs", as: :Browser

  def invalidate(minimum) do
    JS.call(:Native, :invalidate, [minimum]) || minimum + 1
  end

  def supported?, do: JS.call(:Native, :supported, []) == true

  def perform(state, effect) do
    if JS.call(:Native, :current, [state.generation]), do: execute(state, effect), else: []
  end

  # This action's reply is ephemeral. Only the opaque handle is saved in
  # Hologram state; credentials never enter page snapshots or component state.
  def retain_ice(state, params) do
    fallback = params.status != "ok"

    if fallback and state.ice_ready do
      {:ice_failed, %{request: params.request}}
    else
      group = "ice:#{params.request}"
      servers = if fallback, do: [], else: params.result.servers
      result = sync(state, group, %{op: "keep", value: %{iceServers: servers}})

      if result.status == "ok" do
        {:ice_ready,
         %{
           request: params.request,
           group: group,
           ref: result.result,
           fallback: fallback,
           refresh_after: if(fallback, do: nil, else: params.result.refresh_after)
         }}
      else
        {:ice_failed, %{request: params.request}}
      end
    end
  end

  # Called by a chained action after Hologram renders the roster's containers.
  # The video itself is native-owned: moving a container during a roster diff
  # must not replace a participant's media element or restart its stream.
  def sync_tiles(state) do
    if JS.call(:Native, :current, [state.generation]) do
      tiles = ConferenceTiles.list(state)
      wanted = Enum.map(tiles, & &1.id)

      for {id, view} <- state.views, id not in wanted, do: JS.call(:Native, :close, [view.group])

      views =
        Enum.reduce(tiles, Map.take(state.views, wanted), fn tile, views ->
          group = "view:#{tile.id}"

          root =
            value(
              state,
              group,
              call("document", "getElementById", ["conference-media-#{tile.id}"])
            )

          if root do
            stored = views[tile.id]

            # Restored Hologram state may carry released handles. An ID can
            # also be reused by a new document, so verify both kind and seat.
            view =
              if stored && read(state, group, stored.video, ["tagName"]) == "VIDEO" &&
                   read(state, group, stored.video, ["dataset", "conferenceSeat"]) == tile.id,
                 do: stored,
                 else: create_view(state, group, tile.id)

            moved? =
              read(state, group, view.video, ["isConnected"]) != true or
                read(state, group, view.video, ["parentNode", "id"]) !=
                  "conference-media-#{tile.id}"

            if moved?, do: sync(state, group, call(root, "append", [view.video]))

            if view.stream != tile.stream do
              sync(state, group, %{
                op: "set",
                ref: view.video,
                property: "srcObject",
                value: tile.stream
              })
            end

            if tile.stream && (view.stream != tile.stream or moved?) do
              run(state, group, call(view.video, "play", []), %{event: "video_play"})
            end

            Map.put(views, tile.id, %{view | stream: tile.stream})
          else
            views
          end
        end)

      %{state | views: views}
    else
      state
    end
  end

  defp create_view(state, group, seat_id) do
    video = value(state, group, call("document", "createElement", ["video"]))
    sync(state, group, call(video, "setAttribute", ["data-conference-seat", seat_id]))

    for {property, value} <- [
          {"className", "conference-video"},
          {"autoplay", true},
          {"muted", true},
          {"playsInline", true}
        ] do
      sync(state, group, %{op: "set", ref: video, property: property, value: value})
    end

    %{group: group, video: video, stream: nil}
  end

  defp execute(_state, {:close, nil}), do: []

  defp execute(_state, {:close, group}) do
    JS.call(:Native, :close, [group])
    []
  end

  defp execute(state, {:later, group, key, delay, metadata}) do
    JS.call(:Native, :later, [state.generation, group, key, delay, metadata])
    []
  end

  defp execute(state, {:cancel_timer, group, key}) do
    JS.call(:Native, :cancel, [state.generation, group, key])
    []
  end

  defp execute(_state, {:peer_job, id, group, job}),
    do: [{:peer_job, %{peer: id, group: group, job: job}}]

  defp execute(state, {:fetch_ice, request}) do
    push(
      state,
      "conference_ice",
      %{epoch: state.epoch, connection_generation: state.connection_generation},
      :ice_result,
      %{request: request}
    )

    []
  end

  defp execute(state, {:reset_peer, id}) do
    peer = state.peers[id]

    push(state, "conference_reset", envelope(state, peer), :reset_result, %{
      peer: id,
      group: peer.group
    })

    []
  end

  defp execute(state, {:publish, payload}) do
    push(state, "conference_state", payload, :published, %{})
    []
  end

  defp execute(state, {:signal, id, data}) do
    peer = state.peers[id]

    if peer do
      payload = Map.put(envelope(state, peer), :data, data)

      push(state, "conference_signal", payload, :signaled, %{group: peer.group})
    end

    []
  end

  defp execute(state, {:capture, kind, device}) do
    settings =
      if kind == "audio",
        do: %{echoCancellation: true},
        else: %{width: %{ideal: 320}, height: %{ideal: 180}, frameRate: %{ideal: 15, max: 15}}

    constraints = %{
      audio: if(kind == "audio", do: settings, else: false),
      video: if(kind == "video", do: settings, else: false)
    }

    run(state, device.group, call("mediaDevices", "getUserMedia", [constraints]), %{
      event: "capture",
      kind: kind
    })

    []
  end

  defp execute(state, {:adopt_capture, kind, device, stream}) do
    group = device.group
    tracks = value(state, group, call(stream, "getTracks", []))

    track =
      Enum.find(
        tracks,
        &(read(state, group, &1, ["kind"]) == kind and
            read(state, group, &1, ["readyState"]) == "live")
      )

    for other <- tracks, other != track, do: sync(state, group, call(other, "stop", []))

    result =
      if track do
        for event <- ["ended", "mute", "unmute"],
            do: listen(state, group, track, event, [], %{event: event, kind: kind})

        ok(%{stream: stream, track: track, active: active?(state, group, track)})
      else
        %{status: "error", name: "NotFoundError", result: nil}
      end

    reply(state, group, %{event: "device_ready", kind: kind}, result)
  end

  defp execute(state, {:device_status, kind, device}) do
    reply(
      state,
      device.group,
      %{event: "device_status", kind: kind},
      ok(active?(state, device.group, device.track))
    )
  end

  defp execute(state, {:peer_native, id, token, operation, args}) do
    peer = state.peers[id]
    metadata = %{event: "operation", peer: id, token: token}
    peer_operation(state, peer, operation, args, metadata)
  end

  defp execute(state, {:connection_status, id}) do
    peer = state.peers[id]
    connected = read(state, peer.group, peer.pc, ["connectionState"])
    reply(state, peer.group, %{event: "connection_status", peer: id}, ok(connected))
  end

  defp execute(state, {:video_status, id}) do
    peer = state.peers[id]
    active = peer.video_track != nil and active?(state, peer.group, peer.video_track)
    reply(state, peer.group, %{event: "video_status", peer: id}, ok(active))
  end

  defp execute(state, {:attach_track, id, track}) do
    peer = state.peers[id]
    group = peer.group
    tracks = value(state, group, call(peer.stream, "getTracks", []))
    if track not in tracks, do: sync(state, group, call(peer.stream, "addTrack", [track]))

    case read(state, group, track, ["kind"]) do
      "audio" when peer.audio == nil ->
        audio = value(state, group, call("document", "createElement", ["audio"]))
        sync(state, group, %{op: "set", ref: audio, property: "autoplay", value: true})
        sync(state, group, %{op: "set", ref: audio, property: "srcObject", value: peer.stream})
        root = value(state, group, call("document", "getElementById", ["conference-audio"]))
        if root, do: sync(state, group, call(root, "append", [audio]))
        reply(state, group, %{event: "audio", peer: id}, ok(audio))

      "video" ->
        for event <- ["ended", "mute", "unmute"],
            do: listen(state, group, track, event, [], %{event: "video_changed", peer: id})

        reply(state, group, %{event: "video_track", peer: id}, ok(track))

      _ ->
        []
    end
  end

  defp execute(state, {:play, id}) do
    peer = state.peers[id]
    run(state, peer.group, call(peer.audio, "play", []), %{event: "play", peer: id})
    []
  end

  defp peer_operation(state, peer, :create, _args, metadata) do
    group = peer.group

    with %{status: "ok", result: pc} <-
           sync(state, group, %{op: "new", type: "RTCPeerConnection", args: [state.ice_ref]}),
         %{status: "ok", result: stream} <-
           sync(state, group, %{op: "new", type: "MediaStream", args: []}) do
      # Firefox may leave an all-inactive audio/video answer without an ICE
      # transport. A negotiated, unused channel keeps receive-only pairs alive;
      # it carries no application data and closes with its peer connection.
      sync(
        state,
        group,
        call(pc, "createDataChannel", ["conference", %{negotiated: true, id: 0}])
      )

      for {event, name, fields} <- [
            {"icecandidate", "ice", ["candidate"]},
            {"track", "track", ["track"]},
            {"negotiationneeded", "negotiate", []},
            {"connectionstatechange", "connection", []}
          ] do
        listen(state, group, pc, event, fields, %{event: name, peer: peer.id})
      end

      # The answerer adopts the offered transceivers before adding local tracks.
      # Precreating its own transceivers caused one-way media in native checks.
      if not peer.polite do
        for kind <- ["audio", "video"],
            do: sync(state, group, call(pc, "addTransceiver", [kind, %{direction: "recvonly"}]))
      end

      reply(state, group, metadata, ok(%{pc: pc, stream: stream}))
    else
      error -> reply(state, group, metadata, error)
    end
  end

  defp peer_operation(state, peer, :inspect, _args, metadata) do
    result = %{
      remote: read(state, peer.group, peer.pc, ["remoteDescription"]) != nil,
      signaling: read(state, peer.group, peer.pc, ["signalingState"])
    }

    reply(state, peer.group, metadata, ok(result))
  end

  defp peer_operation(state, peer, :configure, _args, metadata),
    do:
      reply(
        state,
        peer.group,
        metadata,
        sync(state, peer.group, call(peer.pc, "setConfiguration", [state.ice_ref]))
      )

  defp peer_operation(state, peer, :restart, _args, metadata),
    do:
      reply(state, peer.group, metadata, sync(state, peer.group, call(peer.pc, "restartIce", [])))

  defp peer_operation(state, peer, :description, _args, metadata) do
    description = read(state, peer.group, peer.pc, ["localDescription"])
    reply(state, peer.group, metadata, ok(%{type: description["type"], sdp: description["sdp"]}))
  end

  defp peer_operation(state, peer, :sync_track, %{kind: kind, device: device}, metadata) do
    sender = peer.senders[kind]

    cond do
      sender == nil and device.track != nil ->
        peer_operation(state, peer, :add_track, %{kind: kind, device: device}, metadata)

      sender != nil and read(state, peer.group, sender, ["track"]) != device.track ->
        run(
          state,
          peer.group,
          call(sender, "replaceTrack", [device.track]),
          Map.put(metadata, :result_ref, sender)
        )

        []

      true ->
        reply(state, peer.group, metadata, ok(sender))
    end
  end

  defp peer_operation(state, peer, :add_track, %{kind: kind, device: device}, metadata) do
    if peer.senders[kind],
      do: sync(state, peer.group, call(peer.pc, "removeTrack", [peer.senders[kind]]))

    result = sync(state, peer.group, call(peer.pc, "addTrack", [device.track, device.stream]))
    reply(state, peer.group, metadata, result)
  end

  defp peer_operation(state, peer, :video_sender, _args, metadata) do
    senders = value(state, peer.group, call(peer.pc, "getSenders", []))
    sender = Enum.find(senders, &(read(state, peer.group, &1, ["track", "kind"]) == "video"))
    reply(state, peer.group, metadata, ok(sender))
  end

  defp peer_operation(state, peer, :replace_track, args, metadata) do
    run(state, peer.group, call(args.sender, "replaceTrack", [args.track]), metadata)
    []
  end

  defp peer_operation(state, peer, operation, args, metadata) do
    {method, args} =
      case operation do
        :set_remote -> {"setRemoteDescription", [args]}
        :set_local -> {"setLocalDescription", []}
        :add_candidate -> {"addIceCandidate", [args]}
      end

    run(state, peer.group, call(peer.pc, method, args), metadata)
    []
  end

  defp active?(state, group, track) do
    read(state, group, track, ["enabled"]) and not read(state, group, track, ["muted"]) and
      read(state, group, track, ["readyState"]) == "live"
  end

  defp push(state, event, payload, action, metadata),
    do:
      JS.call(:Browser, :push, [
        event,
        payload,
        "conference-panel",
        action,
        Map.put(metadata, :generation, state.generation)
      ])

  defp envelope(state, peer),
    do: %{
      epoch: state.epoch,
      connection_generation: state.connection_generation,
      conference_generation: state.own.conference.generation,
      to: peer.id,
      to_connection_generation: peer.connection_generation,
      to_conference_generation: peer.conference_generation,
      peer_generation: peer.peer_generation
    }

  defp listen(state, group, ref, event, fields, metadata),
    do: JS.call(:Native, :listen, [state.generation, group, ref, event, fields, metadata])

  defp run(state, group, command, metadata),
    do: JS.call(:Native, :run, [state.generation, group, command, metadata])

  defp sync(state, group, command) do
    result = JS.call(:Native, :sync, [state.generation, group, command])
    %{status: result["status"], result: result["result"], name: result["name"]}
  end

  defp value(state, group, command), do: sync(state, group, command).result
  defp read(state, group, ref, path), do: value(state, group, %{op: "get", ref: ref, path: path})
  defp call(ref, method, args), do: %{op: "call", ref: ref, method: method, args: args}
  defp ok(result), do: %{status: "ok", result: result}

  defp reply(state, group, metadata, result),
    do: [
      {:native_result,
       Map.merge(Map.merge(metadata, result), %{generation: state.generation, group: group})}
    ]
end
