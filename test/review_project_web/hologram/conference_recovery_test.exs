defmodule ReviewProjectWeb.Hologram.ConferenceRecoveryTest do
  use ExUnit.Case, async: true
  alias ReviewProjectWeb.Hologram.{ConferencePeer, ConferenceRecovery}

  test "transient loss is cancelled; a sustained failure gets one restart and one rebuild" do
    seat = %{id: "peer", connection_generation: 1, conference: %{generation: 1}}
    peer = ConferencePeer.new(seat, "self", "pair")
    {peer, [{:later, _, _, 3000, _}]} = ConferenceRecovery.changed(peer, "disconnected")
    token = peer.recovery_token
    {peer, [{:cancel_timer, _, _}]} = ConferenceRecovery.connected(peer)
    assert {^peer, []} = ConferenceRecovery.timeout(peer, token)
    {peer, _} = ConferenceRecovery.changed(peer, "failed")
    {peer, effects} = ConferenceRecovery.timeout(peer, peer.recovery_token)
    assert {:peer_job, "peer", "pair", :restart} in effects
    {peer, effects} = ConferenceRecovery.timeout(peer, peer.recovery_token)
    assert {:reset_peer, "peer"} in effects
    {peer, _} = ConferenceRecovery.started(%{peer | rebuilds: 1})
    {peer, [{:cancel_timer, _, _}]} = ConferenceRecovery.timeout(peer, peer.recovery_token)
    assert peer.recovery_stage == :exhausted
    {peer, _} = ConferenceRecovery.retry(peer)
    assert peer.rebuilds == 0
    {peer, _} = ConferenceRecovery.connected(peer)
    assert peer.recovery_stage == :idle
  end
end
