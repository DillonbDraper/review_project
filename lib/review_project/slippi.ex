defmodule ReviewProject.Slippi do
  @moduledoc "Bounded streaming validation of the supported Slippi raw event corpus. Metadata is not required."
  import Bitwise
  @header <<123, 85, 3, "raw", 91, 36, 85, 35, 108>>

  def inspect_file(path) do
    with {:ok, file} <-
           :file.open(String.to_charlist(path), [:read, :binary, :raw, {:read_ahead, 262_144}]) do
      try do
        with {:ok, %{size: bytes}} <- File.stat(path),
             {:ok, <<@header, length::unsigned-big-32>>} <- :file.read(file, 15),
             true <- length > 0 and length <= bytes - 15,
             {:ok, <<0x35, size>>} <- :file.read(file, 2),
             true <- size > 1 and size < length and rem(size - 1, 3) == 0,
             {:ok, table} <- :file.read(file, size - 1),
             entries = for(<<code, size::unsigned-big-16 <- table>>, do: {code, size}),
             sizes = Map.new(entries),
             true <- map_size(sizes) == length(entries),
             {:ok, result} <-
               events(file, sizes, length - size - 1, %{
                 last: -1,
                 ended: false,
                 stage: nil,
                 required: 0,
                 frames: %{}
               }),
             true <- result.ended and result.last >= 0,
             true <- complete_frames?(result) do
          {:ok, %{duration: (result.last + 1) / 60, frames: result.last + 1, stage: result.stage}}
        else
          _ -> {:error, :invalid_replay}
        end
      after
        :file.close(file)
      end
    else
      _ -> {:error, :storage_unavailable}
    end
  end

  defp events(_file, _sizes, 0, result), do: {:ok, result}

  defp events(file, sizes, remaining, result) when remaining > 0 do
    with {:ok, <<code>>} <- :file.read(file, 1),
         size when is_integer(size) and size > 0 and size < remaining <- sizes[code],
         {:ok, payload} when byte_size(payload) == size <- :file.read(file, size),
         {:ok, result} <- event(code, payload, result) do
      events(file, sizes, remaining - size - 1, result)
    else
      _ -> {:error, :invalid_replay}
    end
  end

  defp events(_, _, _, _), do: {:error, :invalid_replay}

  defp event(0x36, payload, %{stage: nil} = result) when byte_size(payload) >= 320 do
    <<_::binary-size(18), stage::unsigned-big-16, _::binary>> = payload
    players = for i <- 0..3, :binary.at(payload, 101 + 36 * i) != 3, do: i

    valid =
      stage in [2, 3, 8, 28, 31, 32] and length(players) in [2, 4] and
        Enum.all?(players, fn i ->
          :binary.at(payload, 101 + 36 * i) in [0, 1] and
            :binary.at(payload, 100 + 36 * i) <= 25 and :binary.at(payload, 109 + 36 * i) <= 2
        end)

    required = Enum.reduce(players, 0, fn i, mask -> mask ||| 1 <<< i ||| 1 <<< (i + 4) end)

    if valid,
      do: {:ok, %{result | stage: stage, required: required}},
      else: {:error, :invalid_replay}
  end

  defp event(0x36, _, _), do: {:error, :invalid_replay}
  defp event(_, _, %{stage: nil}), do: {:error, :invalid_replay}
  defp event(_, _, %{ended: true}), do: {:error, :invalid_replay}

  defp event(code, payload, result) when code in [0x37, 0x38, 0x3A, 0x3B, 0x3C, 0x3F] do
    minimum = %{0x37 => 58, 0x38 => 33, 0x3A => 8, 0x3B => 37, 0x3C => 4, 0x3F => 9}

    with true <- byte_size(payload) >= minimum[code],
         <<raw::signed-big-32, _::binary>> <- payload,
         frame = raw + 123,
         true <- frame >= 0 and frame <= result.last + 1,
         {:ok, result} <- frame_event(code, payload, frame, result) do
      {:ok, result}
    else
      _ -> {:error, :invalid_replay}
    end
  end

  defp event(0x39, _, result), do: {:ok, %{result | ended: true}}
  defp event(_, _, result), do: {:ok, result}

  defp frame_event(code, payload, frame, result) do
    # A new simulation of a previous frame invalidates its following frames.
    rollback? = frame < result.last or (code == 0x3A and Map.has_key?(result.frames, frame))

    frames =
      if rollback?,
        do: Map.reject(result.frames, fn {i, _} -> i >= frame end),
        else: result.frames

    result = %{result | frames: frames, last: frame}
    mask = frames[frame] || 0

    cond do
      code in [0x37, 0x38] ->
        <<_::binary-size(4), player, nana, _::binary>> = payload
        valid = player < 4 and nana in [0, 1] and (result.required &&& 1 <<< player) != 0

        valid =
          valid and
            (code != 0x38 or
               (:binary.at(payload, 6) <= 26 and floats?(payload, [9, 13, 17, 21, 25])))

        valid = valid and (code != 0x37 or floats?(payload, [24, 28, 32, 36, 40, 50, 54]))
        bit = player + if(code == 0x38, do: 4, else: 0) + nana * 8

        if valid,
          do:
            {:ok,
             %{
               result
               | frames:
                   Map.put(frames, frame, mask ||| 1 <<< bit ||| stock_bit(code, payload, player))
             }},
          else: {:error, :invalid_replay}

      code == 0x3F ->
        if :binary.at(payload, 4) in [0, 1] and floats?(payload, [5]),
          do: {:ok, %{result | frames: Map.put(frames, frame, mask)}},
          else: {:error, :invalid_replay}

      true ->
        {:ok, %{result | frames: Map.put(frames, frame, mask)}}
    end
  end

  defp floats?(payload, offsets),
    do:
      Enum.all?(offsets, fn offset ->
        <<bits::unsigned-big-32>> = binary_part(payload, offset, 4)
        (bits &&& 0x7F800000) != 0x7F800000
      end)

  defp stock_bit(0x38, <<_::binary-size(5), 0, _::binary>> = payload, player),
    do: 1 <<< (player + if(:binary.at(payload, 32) == 0, do: 16, else: 20))

  defp stock_bit(_, _, _), do: 0

  defp complete_frames?(result) do
    Enum.reduce_while(0..result.last, 0, fn frame, eliminated ->
      mask = result.frames[frame] || 0
      pre = mask &&& 15
      post = mask >>> 4 &&& 15
      missing = result.required &&& 15 &&& bnot(pre)

      if pre != 0 and pre == post and (missing &&& bnot(eliminated)) == 0 and
           (mask >>> 8 &&& 15) == (mask >>> 12 &&& 15) do
        {:cont, (eliminated ||| (mask >>> 16 &&& 15)) &&& bnot(mask >>> 20 &&& 15)}
      else
        {:halt, false}
      end
    end) != false
  end
end
