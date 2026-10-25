defmodule ReviewProject.SyncSpikes.Timeline do
  @moduledoc "Shared monotonic playback timeline for development room spikes."

  def new(now) do
    %{video_id: "M7lc1UVf-VE", position: 0.0, playing: false, revision: 0, at: now}
  end

  def snapshot(room, now) do
    %{
      video_id: room.video_id,
      playing: room.playing,
      position: position(room, now),
      revision: room.revision,
      server_time_ms: now
    }
  end

  def update(room, command, now) do
    next = %{room | position: position(room, now), at: now, revision: room.revision + 1}

    case command do
      %{"op" => "play"} ->
        {:ok, %{next | playing: true}}

      %{"op" => "pause"} ->
        {:ok, %{next | playing: false}}

      %{"op" => "seek", "position" => value}
      when is_number(value) and value >= 0 and value <= 86_400 ->
        {:ok, %{next | position: value * 1.0}}

      %{"op" => "video", "video_id" => id} when is_binary(id) ->
        if Regex.match?(~r/\A[A-Za-z0-9_-]{11}\z/, id),
          do: {:ok, %{next | video_id: id, position: 0.0, playing: false}},
          else: {:error, :invalid_video}

      _ ->
        {:error, :invalid_command}
    end
  end

  defp position(room, now),
    do: room.position + if(room.playing, do: max(0, now - room.at) / 1000, else: 0)
end
