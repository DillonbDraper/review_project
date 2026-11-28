defmodule ReviewProjectWeb.Hologram.FileShareMetadataTest do
  use ExUnit.Case, async: true
  alias ReviewProjectWeb.Hologram.FileShareMetadata
  defp file(name), do: %{name: name, size: 100}

  defp tracks(format, video, audio \\ []) do
    %{
      tracks:
        [
          %{type: "General", format: format, codec_id: "isom", duration: 10.0},
          Map.merge(
            %{
              type: "Video",
              format: "AVC",
              profile: "High",
              bit_depth: 8,
              chroma: "4:2:0",
              duration: 10.0
            },
            video
          )
        ] ++ audio
    }
  end

  test "format policy accepts the approved MP4 and native WebM codecs" do
    audio = [%{type: "Audio", format: "AAC", features: "LC", profile: nil}]

    assert {:ok, %{video_codec: "h264", audio_codec: "aac"}} =
             FileShareMetadata.validate(file("clip.mp4"), tracks("MPEG-4", %{}, audio))

    for format <- ["VP8", "VP9", "AV1"] do
      assert {:ok, %{mime: "video/webm"}} =
               FileShareMetadata.validate(
                 file("clip.webm"),
                 tracks("WebM", %{format: format, profile: "Main"})
               )
    end
  end

  test "HEVC, AV1 MP4, 10-bit, wrong profiles, audio and hidden tracks are rejected" do
    for video <- [
          %{format: "HEVC"},
          %{format: "AV1"},
          %{bit_depth: 10},
          %{profile: "High 10"},
          %{chroma: "4:4:4"}
        ] do
      assert {:error, _} = FileShareMetadata.validate(file("clip.mp4"), tracks("MPEG-4", video))
    end

    assert {:error, _} =
             FileShareMetadata.validate(file("clip.webm"), tracks("Matroska", %{format: "VP9"}))

    assert {:error, _} =
             FileShareMetadata.validate(
               file("clip.mp4"),
               tracks("MPEG-4", %{}, [
                 %{type: "Audio", format: "AAC", features: "SBR", profile: nil}
               ])
             )

    data = tracks("MPEG-4", %{})

    assert {:error, _} =
             FileShareMetadata.validate(file("clip.mp4"), %{
               data
               | tracks: data.tracks ++ [%{type: "Text"}]
             })
  end
end
