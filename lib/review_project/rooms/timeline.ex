defmodule ReviewProject.Rooms.Timeline do
  @moduledoc false

  def new(now), do: %{video_id: nil, position: 0.0, playing: false, revision: 0, at: now}

  def snapshot(timeline, now) do
    timeline
    |> Map.put(:position, position(timeline, now))
    |> Map.put(:server_time_ms, now)
    |> Map.delete(:at)
  end

  def bump(timeline, now),
    do: %{timeline | position: position(timeline, now), at: now, revision: timeline.revision + 1}

  def command(timeline, command, now) do
    next = bump(timeline, now)

    case command do
      %{"op" => "video", "video_id" => id} when is_binary(id) ->
        if Regex.match?(~r/\A[A-Za-z0-9_-]{11}\z/, id),
          do: {:ok, %{next | video_id: id, playing: false, position: 0.0}},
          else: {:error, :invalid_video}

      _ when is_nil(timeline.video_id) ->
        {:error, :no_video}

      %{"op" => "play"} ->
        {:ok, %{next | playing: true}}

      %{"op" => "pause"} ->
        {:ok, %{next | playing: false}}

      %{"op" => "set_playback", "position" => value, "playing" => playing}
      when is_number(value) and value >= 0 and value <= 1_000_000 and is_boolean(playing) ->
        {:ok, %{next | position: value * 1.0, playing: playing}}

      %{"op" => "seek", "position" => value}
      when is_number(value) and value >= 0 and value <= 1_000_000 ->
        {:ok, %{next | position: value * 1.0}}

      _ ->
        {:error, :invalid_command}
    end
  end

  defp position(timeline, now),
    do: timeline.position + if(timeline.playing, do: max(0, now - timeline.at) / 1000, else: 0)
end
