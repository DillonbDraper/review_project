defmodule ReviewProject.Rooms.TimelineTest do
  use ExUnit.Case, async: true
  alias ReviewProject.Rooms.Timeline

  test "local_fileed playback end accounts for seek and elapsed time" do
    source = %{kind: "local_file", id: "asset", duration: 60.0}
    timeline = Timeline.select_file(Timeline.new(0), source, 0)

    assert {:ok, timeline} =
             Timeline.command(
               timeline,
               %{"op" => "set_playback", "position" => 20, "playing" => true},
               1000
             )

    assert Timeline.playback_end(timeline) == 41_000
    assert Timeline.playing?(timeline, 40_999)
    refute Timeline.playing?(timeline, 41_000)
    assert Timeline.playback_end(Timeline.bump(timeline, 2000)) == 41_000
    assert {:ok, paused} = Timeline.command(timeline, %{"op" => "pause"}, 2000)
    assert Timeline.playback_end(paused) == nil
  end

  test "raw local_fileed ids and malformed playback commands cannot select media" do
    timeline = Timeline.new(0)

    assert {:error, :invalid_video} =
             Timeline.command(timeline, %{"op" => "video", "video_id" => "local_file:asset"}, 0)

    assert {:error, :no_video} =
             Timeline.command(
               timeline,
               %{"op" => "video", "source" => %{"kind" => "local_file", "id" => "asset"}},
               0
             )

    assert {:ok, selected} =
             Timeline.command(timeline, %{"op" => "video", "video_id" => "abcdefghijk"}, 0)

    assert {:error, :invalid_command} =
             Timeline.command(selected, %{"op" => "seek", "position" => -1}, 0)

    assert {:error, :invalid_command} =
             Timeline.command(
               selected,
               %{"op" => "set_playback", "position" => 0, "playing" => "true"},
               0
             )
  end
end
