defmodule ReviewProject.Rooms.MediaProbe do
  @moduledoc "Bounded local-only ffprobe inspection; never decodes or transcodes uploads."
  @limit 65_536

  def probe(path) do
    with true <- is_binary(path) and Path.type(path) == :absolute,
         {:ok, %{type: :regular}} <- File.lstat(path),
         ffprobe when is_binary(ffprobe) <- System.find_executable("ffprobe"),
         timeout when is_binary(timeout) <- System.find_executable("timeout"),
         prlimit when is_binary(prlimit) <- System.find_executable("prlimit") do
      args = [
        "--signal=KILL",
        "12",
        prlimit,
        "--as=536870912",
        "--cpu=10",
        "--nofile=32",
        "--",
        ffprobe,
        "-v",
        "error",
        "-max_alloc",
        "67108864",
        "-threads",
        "1",
        "-protocol_whitelist",
        "file",
        "-format_whitelist",
        "mov,matroska,webm",
        "-probesize",
        "5000000",
        "-analyzeduration",
        "5000000",
        "-show_entries",
        "format=format_name,duration:format_tags=major_brand:stream=codec_type,codec_name,profile,pix_fmt",
        "-of",
        "json",
        Path.expand(path)
      ]

      port =
        Port.open({:spawn_executable, timeout}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: args
        ])

      try do
        case collect(port, "", System.monotonic_time(:millisecond) + 13_000) do
          {:ok, data} -> validate(put_in(data, ["format", "webm_verified"], webm?(path)))
          error -> error
        end
      after
        if Port.info(port), do: Port.close(port)
      end
    else
      _ -> {:error, :probe_unavailable}
    end
  rescue
    _ -> {:error, :invalid_media}
  end

  defp collect(port, output, deadline) do
    receive do
      {^port, {:data, bytes}} when byte_size(output) + byte_size(bytes) <= @limit ->
        collect(port, output <> bytes, deadline)

      {^port, {:data, _}} ->
        {:error, :probe_output_limit}

      {^port, {:exit_status, 0}} ->
        Jason.decode(output)

      {^port, {:exit_status, _}} ->
        {:error, :invalid_media}
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> {:error, :probe_timeout}
    end
  end

  defp webm?(path) do
    {:ok, io} = File.open(path, [:read, :binary])

    try do
      case IO.binread(io, 4096) do
        <<0x1A, 0x45, 0xDF, 0xA3, rest::binary>> ->
          case vint(rest) do
            {size, bytes} when size <= 4080 and byte_size(bytes) >= size ->
              <<header::binary-size(^size), _::binary>> = bytes
              doctype(header) == "webm"

            _ ->
              false
          end

        _ ->
          false
      end
    after
      File.close(io)
    end
  end

  defp vint(<<first, rest::binary>>) do
    width = Enum.find(1..8, fn n -> Bitwise.band(first, Bitwise.bsl(1, 8 - n)) != 0 end)

    if width && byte_size(rest) >= width - 1 do
      <<tail::binary-size(^width - 1), remaining::binary>> = rest

      value =
        :binary.decode_unsigned(<<Bitwise.band(first, Bitwise.bsl(1, 8 - width) - 1)>> <> tail)

      {value, remaining}
    else
      :error
    end
  end

  defp vint(_), do: :error

  defp doctype(<<0x42, 0x82, rest::binary>>) do
    case vint(rest) do
      {size, bytes} when size <= byte_size(bytes) -> binary_part(bytes, 0, size)
      _ -> nil
    end
  end

  defp doctype(<<first, rest::binary>>) do
    width = Enum.find(1..4, fn n -> Bitwise.band(first, Bitwise.bsl(1, 8 - n)) != 0 end)

    if width && byte_size(rest) >= width - 1 do
      <<_::binary-size(^width - 1), sizes::binary>> = rest

      case vint(sizes) do
        {size, bytes} when size <= byte_size(bytes) ->
          doctype(binary_part(bytes, size, byte_size(bytes) - size))

        _ ->
          nil
      end
    end
  end

  defp doctype(_), do: nil

  @doc false
  def validate(%{"format" => format, "streams" => streams})
      when is_map(format) and is_list(streams) do
    video = Enum.filter(streams, &(&1["codec_type"] == "video"))
    audio = Enum.filter(streams, &(&1["codec_type"] == "audio"))
    brand = get_in(format, ["tags", "major_brand"])

    mp4? =
      format["format_name"] == "mov,mp4,m4a,3gp,3g2,mj2" and
        brand in ["isom", "iso2", "mp41", "mp42", "avc1", "M4V "]

    # ffprobe shares a demuxer for MKV and WebM; require the actual EBML doctype separately.
    webm? = format["format_name"] == "matroska,webm" and format["webm_verified"] == true
    duration = parse_duration(format["duration"])

    valid =
      case {mp4?, webm?, video, audio} do
        {true, _, [%{"codec_name" => "h264", "pix_fmt" => "yuv420p", "profile" => profile}],
         audio} ->
          profile in ["Constrained Baseline", "Baseline", "Main", "High"] and
            valid_audio?(audio, "aac", "LC")

        {_, true, [%{"codec_name" => codec, "pix_fmt" => "yuv420p"} = stream], audio} ->
          webm_video?(codec, stream) and valid_audio?(audio, "opus", nil)

        _ ->
          false
      end

    if valid and duration > 0 and length(streams) == length(video) + length(audio),
      do: {:ok, %{mime: if(mp4?, do: "video/mp4", else: "video/webm"), duration: duration}},
      else: {:error, :unsupported_media}
  rescue
    _ -> {:error, :invalid_media}
  end

  def validate(_), do: {:error, :invalid_media}

  defp webm_video?(codec, _) when codec in ["vp8", "vp9"], do: true

  defp webm_video?("av1", %{"profile" => "Main"}), do: true

  defp webm_video?(_, _), do: false
  defp valid_audio?([], _, _), do: true

  defp valid_audio?([a], codec, profile),
    do: a["codec_name"] == codec and (profile == nil or a["profile"] == profile)

  defp valid_audio?(_, _, _), do: false

  defp parse_duration(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} when number > 0 and number < 1.0e9 -> number
      _ -> 0
    end
  end

  defp parse_duration(_), do: 0
end
