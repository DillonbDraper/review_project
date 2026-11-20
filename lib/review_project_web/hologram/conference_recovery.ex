defmodule ReviewProjectWeb.Hologram.ConferenceRecovery do
  @moduledoc "Bounded recovery for one peer; other peers, capture, chat, and the player continue."

  def connected(peer) do
    {%{peer | recovery_stage: :idle, recovery_token: peer.recovery_token + 1, rebuilds: 0},
     [{:cancel_timer, peer.group, "recovery"}]}
  end

  def changed(peer, status) do
    cond do
      status == "connected" ->
        connected(peer)

      peer.recovery_stage in [:idle, :connecting] and status == "failed" ->
        schedule(peer, :grace, 0)

      peer.recovery_stage == :idle and status == "disconnected" ->
        schedule(peer, :grace, 3_000)

      true ->
        {peer, []}
    end
  end

  def started(peer), do: schedule(peer, :connecting, 15_000)

  def timeout(peer, token) do
    cond do
      token != peer.recovery_token or peer.connected ->
        {peer, []}

      peer.recovery_stage in [:grace, :connecting] and peer.rebuilds == 0 ->
        {peer, effects} = schedule(peer, :restart, 10_000)
        {peer, [{:peer_job, peer.id, peer.group, :restart} | effects]}

      peer.recovery_stage == :restart and peer.rebuilds == 0 ->
        {peer, effects} = schedule(peer, :resetting, 10_000)
        {peer, [{:reset_peer, peer.id} | effects]}

      true ->
        exhausted(peer)
    end
  end

  def retry(peer), do: schedule(%{peer | rebuilds: 0}, :grace, 0)

  def exhausted(peer) do
    {%{peer | recovery_stage: :exhausted, recovery_token: peer.recovery_token + 1},
     [{:cancel_timer, peer.group, "recovery"}]}
  end

  defp schedule(peer, stage, delay) do
    peer = %{peer | recovery_stage: stage, recovery_token: peer.recovery_token + 1}

    {peer,
     [
       {:later, peer.group, "recovery", delay,
        %{event: "recover", peer: peer.id, token: peer.recovery_token}}
     ]}
  end
end
