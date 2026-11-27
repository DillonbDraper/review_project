defmodule ReviewProject.Rooms.MediaProbeTest do
  use ExUnit.Case, async: true
  alias ReviewProject.Rooms.MediaProbe

  test "AV1 accepts only verified WebM Main 8-bit 4:2:0 with Opus or no audio" do
    video = %{
      "codec_type" => "video",
      "codec_name" => "av1",
      "profile" => "Main",
      "pix_fmt" => "yuv420p"
    }

    audio = %{"codec_type" => "audio", "codec_name" => "opus"}

    format = %{
      "format_name" => "matroska,webm",
      "webm_verified" => true,
      "duration" => "2424.181"
    }

    data = %{"format" => format, "streams" => [video, audio]}

    assert {:ok, %{mime: "video/webm", duration: 2424.181}} =
             MediaProbe.validate(data)

    assert {:ok, _} = MediaProbe.validate(%{data | "streams" => [video]})

    for invalid <- [
          %{data | "format" => Map.delete(format, "webm_verified")},
          %{
            data
            | "format" => %{
                "format_name" => "mov,mp4,m4a,3gp,3g2,mj2",
                "duration" => "1",
                "tags" => %{"major_brand" => "isom"}
              }
          },
          %{data | "streams" => [Map.put(video, "profile", "High"), audio]},
          %{data | "streams" => [Map.put(video, "pix_fmt", "yuv420p10le"), audio]},
          %{data | "streams" => [video, Map.put(audio, "codec_name", "vorbis")]},
          %{data | "streams" => [video, audio, audio]}
        ] do
      assert {:error, :unsupported_media} = MediaProbe.validate(invalid)
    end
  end

  @tag :tmp_dir
  test "real AV1 WebM bytes are accepted by the normal validator", %{tmp_dir: root} do
    path = Path.join(root, "av1.webm")

    assert {_, 0} =
             System.cmd(
               "ffmpeg",
               [
                 "-v",
                 "error",
                 "-f",
                 "lavfi",
                 "-i",
                 "color=size=32x32:rate=1",
                 "-t",
                 "1",
                 "-c:v",
                 "libaom-av1",
                 "-cpu-used",
                 "8",
                 "-threads",
                 "1",
                 "-pix_fmt",
                 "yuv420p",
                 path
               ],
               stderr_to_stdout: true
             )

    assert {:ok, %{mime: "video/webm"}} = MediaProbe.probe(path)
  end

  test "URLs, relative paths, directories and malformed metadata fail closed" do
    for path <- [
          "https://example.com/video.mp4",
          "file:///etc/hosts",
          "relative.mp4",
          System.tmp_dir!()
        ] do
      assert {:error, _} = MediaProbe.probe(path)
    end

    for data <- [
          nil,
          %{},
          %{"format" => nil, "streams" => []},
          %{"format" => %{}, "streams" => [nil]},
          %{"format" => %{}, "streams" => "bad"}
        ] do
      assert {:error, _} = MediaProbe.validate(data)
    end
  end

  test "real byte inspection accepts H264 and WebM, rejects renamed MKV and garbage" do
    root = Path.join(System.tmp_dir!(), Ecto.UUID.generate())
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    for {extension, codec, mime} <- [
          {"mp4", "libx264", "video/mp4"},
          {"webm", "libvpx", "video/webm"}
        ] do
      path = Path.join(root, "video." <> extension)

      assert {_, 0} =
               System.cmd(
                 "ffmpeg",
                 [
                   "-v",
                   "error",
                   "-f",
                   "lavfi",
                   "-i",
                   "color=size=32x32:rate=1",
                   "-t",
                   "1",
                   "-c:v",
                   codec,
                   "-pix_fmt",
                   "yuv420p",
                   path
                 ],
                 stderr_to_stdout: true
               )

      assert {:ok, %{mime: ^mime, duration: duration}} = MediaProbe.probe(path)
      assert duration > 0
    end

    mkv = Path.join(root, "renamed.mp4")

    assert {_, 0} =
             System.cmd(
               "ffmpeg",
               [
                 "-v",
                 "error",
                 "-f",
                 "lavfi",
                 "-i",
                 "color=size=32x32:rate=1",
                 "-t",
                 "1",
                 "-c:v",
                 "libvpx",
                 "-f",
                 "matroska",
                 mkv
               ],
               stderr_to_stdout: true
             )

    assert {:error, _} = MediaProbe.probe(mkv)
    File.write!(mkv, "not media")
    assert {:error, _} = MediaProbe.probe(mkv)
  end
end
