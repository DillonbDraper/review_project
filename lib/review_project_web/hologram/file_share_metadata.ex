defmodule ReviewProjectWeb.Hologram.FileShareMetadata do
  @moduledoc "Client-side format policy applied to bounded, untrusted inspection results."

  def validate(file, %{tracks: tracks}) when is_list(tracks) do
    general = Enum.find(tracks, &(&1.type == "General"))
    videos = Enum.filter(tracks, &(&1.type == "Video"))
    audio = Enum.filter(tracks, &(&1.type == "Audio"))

    case {general, videos, audio} do
      {general, [video], audio} when general != nil and length(audio) <= 1 ->
        duration = general.duration || video.duration

        common =
          length(tracks) == 2 + length(audio) and is_number(duration) and
            duration > 0 and duration < 1.0e9 and video.bit_depth == 8 and video.chroma == "4:2:0"

        kind = format(file.name, general, video, audio)

        if common and kind,
          do: {:ok, descriptor(file, video, audio, kind, duration)},
          else: {:error, unsupported()}

      _ ->
        {:error, unsupported()}
    end
  end

  def validate(_, _), do: {:error, unsupported()}

  defp format(name, general, video, audio) do
    cond do
      String.ends_with?(String.downcase(name), ".mp4") and general.format == "MPEG-4" and
        general.codec_id in ["isom", "iso2", "mp41", "mp42", "avc1", "M4V "] and
        video.format == "AVC" and is_binary(video.profile) and
        Regex.match?(~r/\A(Constrained Baseline|Baseline|Main|High)(@|\z)/, video.profile) and
          audio?(audio, "AAC") ->
        :mp4

      String.ends_with?(String.downcase(name), ".webm") and general.format == "WebM" and
        (video.format in ["VP8", "VP9"] or (video.format == "AV1" and video.profile == "Main")) and
          audio?(audio, "Opus") ->
        :webm

      true ->
        nil
    end
  end

  defp audio?([], _format), do: true

  defp audio?([%{format: "AAC"} = audio], "AAC"),
    do: audio.features == "LC" or audio.profile == "LC"

  defp audio?([%{format: "Opus"}], "Opus"), do: true
  defp audio?(_, _), do: false

  defp descriptor(file, video, audio, kind, duration) do
    mime = if kind == :mp4, do: "video/mp4", else: "video/webm"
    video_codec = if kind == :mp4, do: "h264", else: String.downcase(video.format)

    codec =
      case video_codec do
        "h264" -> "avc1.42E01E"
        "vp8" -> "vp8"
        "vp9" -> "vp9"
        "av1" -> "av01.0.08M.08"
      end

    audio_codec = if audio == [], do: "none", else: if(kind == :mp4, do: "aac", else: "opus")

    codecs =
      codec <> if(audio == [], do: "", else: if(kind == :mp4, do: ", mp4a.40.2", else: ", opus"))

    %{
      name: file.name,
      size: file.size,
      duration: duration,
      mime: mime,
      video_codec: video_codec,
      audio_codec: audio_codec,
      codec: mime <> "; codecs=\"" <> codecs <> "\""
    }
  end

  defp unsupported,
    do:
      "Unsupported format. Use 8-bit MP4 H.264/AAC-LC or WebM VP8, VP9 or AV1 Main with Opus (or no audio)."
end
