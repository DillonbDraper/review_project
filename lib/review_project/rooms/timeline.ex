defmodule ReviewProject.Rooms.Timeline do
  @moduledoc false

  def new(now),
    do: %{video_id: nil, video_source: nil, position: 0.0, playing: false, revision: 0, at: now}

  def snapshot(timeline, now) do
    timeline
    |> Map.put(:position, position(timeline, now))
    |> Map.put(:server_time_ms, now)
    |> Map.delete(:at)
  end

  def bump(timeline, now),
    do: %{timeline | position: position(timeline, now), at: now, revision: timeline.revision + 1}

  # The session supplies this descriptor only after checking private staged media.
  def select_upload(timeline, source, now) do
    next = bump(timeline, now)

    %{
      next
      | video_id: "upload:" <> source.id,
        video_source: source,
        playing: false,
        position: 0.0
    }
  end

  def clear(timeline, now) do
    next = bump(timeline, now)
    %{next | video_id: nil, video_source: nil, playing: false, position: 0.0}
  end

  # Preserve the actual end across arbitrarily delayed maintenance and authority bumps.
  def playback_end(%{playing: true, video_source: %{duration: duration}} = timeline)
      when is_number(duration) and duration > 0,
      do: timeline.at + ceil(max(0, duration - timeline.position) * 1000)

  def playback_end(_timeline), do: nil

  def playing?(%{playing: false}, _now), do: false

  def playing?(timeline, now) do
    duration = timeline.video_source && Map.get(timeline.video_source, :duration)
    timeline.video_id != nil and (is_nil(duration) or position(timeline, now) < duration)
  end

  def command(timeline, command, now) do
    next = bump(timeline, now)

    case command do
      %{"op" => "video", "video_id" => id} when is_binary(id) ->
        if Regex.match?(~r/\A[A-Za-z0-9_-]{11}\z/, id),
          do:
            {:ok,
             %{
               next
               | video_id: id,
                 video_source: %{kind: "youtube", id: id},
                 playing: false,
                 position: 0.0
             }},
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
