defmodule ReviewProjectWeb.Hologram.ConferencePeer do
  @moduledoc "Pure, serialized WebRTC negotiation. Native completions resume one peer at a time."

  def new(seat, self_id, group) do
    %{
      id: seat.id,
      connection_generation: seat.connection_generation,
      conference_generation: seat.conference.generation,
      group: group,
      peer_generation: 0,
      recovery_stage: :idle,
      recovery_token: 0,
      rebuilds: 0,
      polite: self_id > seat.id,
      pc: nil,
      stream: nil,
      audio: nil,
      blocked: false,
      connected: false,
      connection_state: "new",
      video_track: nil,
      video_active: false,
      phase: :creating,
      token: 0,
      queue: [],
      senders: %{},
      has_remote: false,
      local_id: nil,
      remote_id: nil,
      local_ice: [],
      ignored: [],
      candidates: [],
      data: nil,
      collision: false,
      description: nil,
      sync_kinds: [],
      sync_device: nil,
      after_sync: :finish,
      flush: [],
      restoring: nil
    }
  end

  def enqueue(peer, job, context) do
    if length(peer.queue) < 128,
      do: advance(%{peer | queue: peer.queue ++ [job]}, context),
      else: {peer, []}
  end

  def complete(peer, %{status: "error"} = result, context) do
    if peer.phase == :sync_track and result.name == "InvalidModificationError" and
         peer.sync_device.track != nil do
      request(peer, :add_track, :sync_fallback, %{
        kind: hd(peer.sync_kinds),
        device: peer.sync_device
      })
    else
      {peer, effects} = finish(peer, context)

      {peer,
       [{:error, "A conference connection could not be updated (#{result.name})."} | effects]}
    end
  end

  def complete(%{phase: :creating} = peer, %{result: refs}, context) do
    advance(%{peer | pc: refs.pc, stream: refs.stream, phase: :idle}, context)
  end

  def complete(%{phase: :inspect} = peer, %{result: info}, context) do
    peer = %{peer | has_remote: info.remote}

    case peer.data do
      :negotiate ->
        if (peer.polite and not info.remote) or info.signaling != "stable",
          do: finish(peer, context),
          else: sync(peer, :offer, context)

      %{description: description} = data ->
        collision = description.type == "offer" and info.signaling != "stable"

        cond do
          not peer.polite and collision ->
            ignored = Enum.take([data.negotiation_id | peer.ignored], 8)
            candidates = Enum.reject(peer.candidates, &(&1.negotiation_id == data.negotiation_id))
            finish(%{peer | ignored: ignored, candidates: candidates}, context)

          description.type == "answer" and data.negotiation_id != peer.local_id ->
            finish(peer, context)

          true ->
            request(%{peer | collision: collision}, :set_remote, :remote_description, description)
        end
    end
  end

  def complete(%{phase: :remote_description} = peer, _result, context) do
    candidates = Enum.filter(peer.candidates, &(&1.negotiation_id == peer.data.negotiation_id))

    flush(
      %{
        peer
        | has_remote: true,
          remote_id: peer.data.negotiation_id,
          candidates: [],
          flush: candidates
      },
      context
    )
  end

  def complete(%{phase: :flush} = peer, _result, context), do: flush(peer, context)
  def complete(%{phase: :candidate} = peer, _result, context), do: finish(peer, context)
  def complete(%{phase: :restarted} = peer, _result, context), do: finish(peer, context)

  def complete(%{phase: :configured} = peer, _result, _context),
    do: request(peer, :restart, :restarted, nil)

  def complete(%{phase: :sync_track} = peer, %{result: sender}, context) do
    [kind | remaining] = peer.sync_kinds
    senders = if sender, do: Map.put(peer.senders, kind, sender), else: peer.senders
    sync_next(%{peer | senders: senders, sync_kinds: remaining}, context)
  end

  def complete(%{phase: :sync_fallback} = peer, result, context),
    do: complete(%{peer | phase: :sync_track}, result, context)

  def complete(%{phase: :local_description} = peer, _result, _context) do
    request(peer, :description, :description, nil)
  end

  def complete(%{phase: :description} = peer, %{result: description}, context) do
    ufrags =
      description.sdp
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "a=ice-ufrag:"))
      |> Enum.map(&{String.trim(String.replace_prefix(&1, "a=ice-ufrag:", "")), peer.local_id})

    ice = Enum.take(Enum.uniq_by(ufrags ++ peer.local_ice, &elem(&1, 0)), 8)
    peer = %{peer | description: description, local_ice: ice}

    if peer.collision and peer.polite and peer.data != :negotiate and
         peer.data.description.type == "offer" and context.devices["video"].track do
      request(peer, :video_sender, :video_sender, nil)
    else
      send_description(peer, context)
    end
  end

  def complete(%{phase: :video_sender} = peer, %{result: sender}, context) do
    track = context.devices["video"].track

    if sender && track do
      peer = %{peer | senders: Map.put(peer.senders, "video", sender), restoring: track}
      request(peer, :replace_track, :restore_clear, %{sender: sender, track: nil})
    else
      send_description(peer, context)
    end
  end

  def complete(%{phase: :restore_clear} = peer, _result, context) do
    # Chrome rollback can detach the source. Rebind AFTER committing the answer;
    # doing this while the remote offer is pending can stall the native sender.
    if context.devices["video"].track == peer.restoring and peer.restoring != nil do
      request(peer, :replace_track, :restore_video, %{
        sender: peer.senders["video"],
        track: peer.restoring
      })
    else
      send_description(peer, context)
    end
  end

  def complete(%{phase: :restore_video} = peer, _result, context),
    do: send_description(peer, context)

  def candidate(peer, candidate) do
    id =
      Enum.find_value(peer.local_ice, fn {ufrag, id} ->
        if ufrag == Map.get(candidate, :usernameFragment), do: id
      end) || peer.local_id

    if id,
      do: [{:signal, peer.id, %{type: "candidate", negotiation_id: id, candidate: candidate}}],
      else: []
  end

  defp advance(%{phase: :idle, queue: [job | rest]} = peer, context) do
    peer = %{peer | queue: rest, token: peer.token + 1, data: job, collision: false}

    case job do
      :sync -> sync(peer, :finish, context)
      :restart -> request(peer, :restart, :restarted, nil)
      :configure -> request(peer, :configure, :configured, nil)
      :negotiate -> request(peer, :inspect, :inspect, nil)
      %{type: "description"} -> request(peer, :inspect, :inspect, nil)
      %{type: "candidate"} = data -> receive_candidate(peer, data, context)
    end
  end

  defp advance(peer, _context), do: {peer, []}

  defp receive_candidate(peer, data, context) do
    cond do
      data.negotiation_id in peer.ignored ->
        finish(peer, context)

      peer.has_remote and peer.remote_id == data.negotiation_id ->
        request(peer, :add_candidate, :candidate, data.candidate)

      true ->
        finish(%{peer | candidates: Enum.take(peer.candidates ++ [data], 128)}, context)
    end
  end

  defp sync(peer, after_sync, context) do
    if peer.polite and not peer.has_remote,
      do: after_sync(%{peer | after_sync: after_sync}, context),
      else: sync_next(%{peer | sync_kinds: ["audio", "video"], after_sync: after_sync}, context)
  end

  defp sync_next(%{sync_kinds: []} = peer, context), do: after_sync(peer, context)

  defp sync_next(peer, context) do
    kind = hd(peer.sync_kinds)
    device = context.devices[kind]

    request(%{peer | sync_device: device}, :sync_track, :sync_track, %{kind: kind, device: device})
  end

  defp after_sync(%{after_sync: :finish} = peer, context), do: finish(peer, context)

  defp after_sync(peer, context) do
    id =
      if peer.after_sync == :offer,
        do: "#{context.self_id}:#{peer.token}",
        else: peer.data.negotiation_id

    request(%{peer | local_id: id}, :set_local, :local_description, nil)
  end

  defp flush(%{flush: [candidate | rest]} = peer, _context),
    do: request(%{peer | flush: rest}, :add_candidate, :flush, candidate.candidate)

  defp flush(peer, context) do
    if peer.data.description.type == "offer",
      do: sync(peer, :answer, context),
      else: finish(peer, context)
  end

  defp send_description(peer, context) do
    effect =
      {:signal, peer.id,
       %{type: "description", negotiation_id: peer.local_id, description: peer.description}}

    {peer, effects} = finish(peer, context)
    {peer, [effect | effects]}
  end

  defp finish(peer, context),
    do:
      advance(
        %{
          peer
          | phase: :idle,
            data: nil,
            description: nil,
            sync_device: nil,
            restoring: nil,
            flush: []
        },
        context
      )

  defp request(peer, operation, phase, args) do
    {%{peer | phase: phase}, [{:peer_native, peer.id, peer.token, operation, args}]}
  end
end
