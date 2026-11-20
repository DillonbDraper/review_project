defmodule ReviewProjectWeb.Hologram.ConferenceTiles do
  @moduledoc "Participant presentation follows the admitted roster, independently of media arrival."

  def list(%{connected: false}), do: []

  def list(state) do
    state.seats
    |> Enum.filter(& &1.connected)
    |> Enum.map(&tile(state, &1))
  end

  defp tile(state, seat) do
    local? = seat.id == state.self_id
    peer = state.peers[seat.id]
    camera = state.devices["video"]

    video? =
      state.supported and
        if local?,
          do: camera.track != nil and camera.active,
          else:
            peer != nil and peer.connected and peer.video_active and
              Map.get(seat.conference, :camera, false)

    status =
      cond do
        not state.supported -> "Calling unavailable"
        local? and camera.pending -> "Starting camera…"
        video? -> "Camera on"
        local? -> "Camera off"
        peer != nil and peer.recovery_stage == :exhausted -> "Connection unavailable"
        peer != nil and peer.connection_state in ["disconnected", "failed"] -> "Reconnecting…"
        not seat.conference.ready or peer == nil or not peer.connected -> "Connecting…"
        Map.get(seat.conference, :camera, false) -> "Waiting for video…"
        true -> "Camera off"
      end

    %{
      id: seat.id,
      name: Map.get(seat, :display_name, "Participant"),
      local?: local?,
      video?: video?,
      microphone?:
        if(local?,
          do: state.devices["audio"].active,
          else: Map.get(seat.conference, :microphone, false)
        ),
      status: status,
      stream: if(video?, do: if(local?, do: camera.stream, else: peer.stream), else: nil)
    }
  end
end
