defmodule ReviewProject.Rooms.LocalFile do
  @moduledoc "Bounded, untrusted descriptors for ephemeral browser-owned files. Never receives bytes."
  @max_bytes 1_073_741_824

  def descriptor(%{"metadata" => metadata, "page_id" => page_id}, seat_id, generation)
      when is_map(metadata) and is_binary(page_id) and byte_size(page_id) in 1..64 do
    with %{
           "name" => name,
           "size" => size,
           "duration" => duration,
           "mime" => mime,
           "video_codec" => video,
           "audio_codec" => audio,
           "codec" => codec
         } <- metadata,
         true <- is_binary(name) and byte_size(name) in 1..1024,
         true <- is_integer(size) and size in 1..@max_bytes,
         true <- is_number(duration) and duration > 0 and duration < 1.0e9,
         true <- is_binary(codec) and byte_size(codec) in 1..256,
         true <- valid_codecs?(mime, video, audio),
         true <- Regex.match?(~r/\A[^\x00-\x1F\x7F]+\z/u, name) do
      {:ok,
       %{
         kind: "local_file",
         id: Ecto.UUID.generate(),
         seat_id: seat_id,
         generation: generation,
         name: name,
         size: size,
         duration: duration * 1.0,
         mime: mime,
         video_codec: video,
         audio_codec: audio,
         codec: codec,
         available: true
       }, page_id}
    else
      _ -> {:error, :unsupported_media}
    end
  end

  def descriptor(_, _, _), do: {:error, :unsupported_media}

  defp valid_codecs?("video/mp4", "h264", audio), do: audio in ["aac", "none"]

  defp valid_codecs?("video/webm", video, audio),
    do: video in ["vp8", "vp9", "av1"] and audio in ["opus", "none"]

  defp valid_codecs?(_, _, _), do: false
end
