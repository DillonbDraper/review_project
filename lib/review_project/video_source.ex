defmodule ReviewProject.VideoSource do
  @moduledoc "Validates YouTube sources and constructs embeds from video IDs only."

  @youtube_hosts ~w(youtube.com www.youtube.com m.youtube.com music.youtube.com youtube-nocookie.com www.youtube-nocookie.com)
  @short_hosts ~w(youtu.be www.youtu.be)
  @id_pattern ~r/\A[A-Za-z0-9_-]{11}\z/

  @spec youtube_id(term()) :: {:ok, String.t()} | :error
  def youtube_id(source) when is_binary(source) and byte_size(source) <= 2048 do
    source = String.trim(source)

    if Regex.match?(@id_pattern, source) do
      {:ok, source}
    else
      source
      |> normalize_url()
      |> URI.parse()
      |> id_from_uri()
      |> validate_id()
    end
  rescue
    ArgumentError -> :error
  end

  def youtube_id(_source), do: :error

  def embed_url(video_id), do: "https://www.youtube-nocookie.com/embed/#{video_id}"

  defp normalize_url("https://" <> _rest = source), do: source
  defp normalize_url("http://" <> _rest = source), do: source
  defp normalize_url(source), do: "https://" <> source

  defp id_from_uri(%URI{scheme: scheme, host: host, path: path, query: query, userinfo: nil})
       when scheme in ["http", "https"] do
    host = String.downcase(host || "")
    segments = String.split(path || "", "/", trim: true)

    cond do
      host in @short_hosts and length(segments) == 1 -> hd(segments)
      host in @youtube_hosts -> youtube_path_id(segments, query)
      true -> nil
    end
  end

  defp id_from_uri(_uri), do: nil

  defp youtube_path_id(["watch"], query), do: URI.decode_query(query || "")["v"]
  defp youtube_path_id([kind, id], _query) when kind in ["embed", "shorts", "live"], do: id
  defp youtube_path_id(_segments, _query), do: nil

  defp validate_id(id) when is_binary(id) do
    if Regex.match?(@id_pattern, id), do: {:ok, id}, else: :error
  end

  defp validate_id(_id), do: :error
end
