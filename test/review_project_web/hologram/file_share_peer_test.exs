defmodule ReviewProjectWeb.Hologram.FileSharePeerTest do
  use ExUnit.Case, async: true
  alias ReviewProjectWeb.Hologram.FileSharePeer, as: Peer

  defp peer(offering),
    do: Peer.new(%{id: "peer", connection_generation: 1}, 0, "group", offering, "local-id")

  defp complete(peer, result \\ nil), do: Peer.complete(peer, result)

  test "source API sequencing creates and binds the channel before constructing and publishing the offer" do
    peer = peer(true)
    assert {^peer, [{:peer_operation, "peer", 1, :create, nil}]} = Peer.start(peer)
    {peer, [{:peer_operation, _, _, :create_channel, nil}]} = complete(peer)

    {peer, [{:bind_channel, "peer", "channel"}, {:peer_operation, _, _, :create_offer, nil}]} =
      complete(peer, "channel")

    offer = %{type: "offer", sdp: "offer"}
    {peer, [{:peer_operation, _, _, :set_local, ^offer}]} = complete(peer, offer)
    {peer, [{:peer_operation, _, _, :description, nil}]} = complete(peer)
    {peer, effects} = complete(peer, offer)

    assert [
             {:signal, "peer",
              %{type: "description", negotiation_id: "local-id", description: ^offer}}
           ] = effects

    assert peer.phase == :idle
    assert peer.data == nil
  end

  test "receiver serializes candidates and descriptions and flushes only the matching negotiation" do
    peer = peer(false)
    good = %{type: "candidate", negotiation_id: "n", candidate: %{candidate: "good"}}
    wrong = %{good | negotiation_id: "other"}
    {peer, []} = Peer.enqueue(peer, good)
    {peer, []} = Peer.enqueue(peer, wrong)
    {peer, []} = complete(peer)
    assert length(peer.candidates) == 2

    offer = %{
      type: "description",
      negotiation_id: "n",
      description: %{type: "offer", sdp: "offer"}
    }

    {peer, [{:peer_operation, _, _, :set_remote, _}]} = Peer.enqueue(peer, offer)
    {peer, [{:peer_operation, _, _, :add_candidate, %{candidate: "good"}}]} = complete(peer)
    {peer, [{:peer_operation, _, _, :create_answer, nil}]} = complete(peer)
    assert peer.candidates == []
    assert peer.remote_id == "n"
    answer = %{type: "answer", sdp: "answer"}
    {peer, _} = complete(peer, answer)
    {peer, _} = complete(peer)

    {peer, [{:signal, "peer", %{negotiation_id: "n", description: ^answer}}]} =
      complete(peer, answer)

    assert peer.phase == :idle
  end

  test "source ignores answers for an obsolete negotiation and queues are bounded" do
    {peer, _} = complete(peer(true))
    peer = %{peer | phase: :idle}

    answer = %{
      type: "description",
      negotiation_id: "obsolete",
      description: %{type: "answer", sdp: "answer"}
    }

    {peer, []} = Peer.enqueue(peer, answer)
    assert peer.remote_id == nil
    waiting = peer(false)
    waiting = Enum.reduce(1..100, waiting, fn _, p -> elem(Peer.enqueue(p, answer), 0) end)
    assert length(waiting.queue) == 64
  end
end
