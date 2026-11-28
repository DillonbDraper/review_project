defmodule ReviewProjectWeb.Hologram.FileSharePeer do
  @moduledoc "Serialized file-peer negotiation, independent of native browser objects."

  def new(seat, generation, group, offering, negotiation) do
    %{
      id: seat.id,
      connection_generation: seat.connection_generation,
      peer_generation: generation,
      group: group,
      offering: offering,
      local_id: if(offering, do: negotiation),
      remote_id: nil,
      phase: :creating,
      token: 1,
      queue: [],
      candidates: [],
      flush: [],
      data: nil,
      description: nil,
      connected: false,
      retry_token: 0,
      retry_pending: false,
      retries: 0
    }
  end

  def start(peer), do: {peer, [operation(peer, :create, nil)]}

  def enqueue(peer, job) do
    if length(peer.queue) < 64,
      do: advance(%{peer | queue: peer.queue ++ [job]}),
      else: {peer, []}
  end

  def complete(%{phase: :creating} = peer, _result) do
    if peer.offering,
      do: request(peer, :create_channel, :channel, nil),
      else: finish(peer)
  end

  def complete(%{phase: :channel} = peer, channel) do
    {next, effects} = request(peer, :create_offer, :offer, nil)
    {next, [{:bind_channel, peer.id, channel} | effects]}
  end

  def complete(%{phase: phase} = peer, description) when phase in [:offer, :answer],
    do: request(peer, :set_local, :local, description)

  def complete(%{phase: :local} = peer, _result),
    do: request(peer, :description, :description, nil)

  def complete(%{phase: :description} = peer, description) do
    data = %{type: "description", negotiation_id: peer.local_id, description: description}
    {next, effects} = finish(peer)
    {next, [{:signal, peer.id, data} | effects]}
  end

  def complete(%{phase: :remote} = peer, _result) do
    id = peer.data.negotiation_id
    flush = Enum.filter(peer.candidates, &(&1.negotiation_id == id))
    flush(%{peer | remote_id: id, candidates: [], flush: flush})
  end

  def complete(%{phase: :flush} = peer, _result), do: flush(peer)

  def complete(%{phase: phase} = peer, _result) when phase in [:candidate, :configured],
    do: finish(peer)

  def candidate(%{local_id: nil}, _candidate), do: []

  def candidate(peer, candidate),
    do: [
      {:signal, peer.id,
       %{type: "candidate", negotiation_id: peer.local_id, candidate: candidate}}
    ]

  defp advance(%{phase: :idle, queue: [job | rest]} = peer) do
    peer = %{peer | queue: rest, token: peer.token + 1, data: job}

    case job do
      :configure ->
        request(peer, :configure, :configured, nil)

      %{type: "description", description: %{type: "offer"}} = data when not peer.offering ->
        request(%{peer | local_id: data.negotiation_id}, :set_remote, :remote, data.description)

      %{type: "description", description: %{type: "answer"}} = data when peer.offering ->
        if data.negotiation_id == peer.local_id,
          do: request(peer, :set_remote, :remote, data.description),
          else: finish(peer)

      %{type: "candidate"} = data ->
        cond do
          peer.remote_id == data.negotiation_id ->
            request(peer, :add_candidate, :candidate, data.candidate)

          length(peer.candidates) < 64 ->
            finish(%{peer | candidates: peer.candidates ++ [data]})

          true ->
            finish(peer)
        end

      _ ->
        finish(peer)
    end
  end

  defp advance(peer), do: {peer, []}

  defp flush(%{flush: [candidate | rest]} = peer),
    do: request(%{peer | flush: rest}, :add_candidate, :flush, candidate.candidate)

  defp flush(peer) do
    if peer.data.description.type == "offer",
      do: request(peer, :create_answer, :answer, nil),
      else: finish(peer)
  end

  defp finish(peer), do: advance(%{peer | phase: :idle, data: nil, description: nil, flush: []})

  defp request(peer, operation, phase, args) do
    peer = %{peer | phase: phase}
    {peer, [operation(peer, operation, args)]}
  end

  defp operation(peer, operation, args),
    do: {:peer_operation, peer.id, peer.token, operation, args}
end
