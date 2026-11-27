defmodule ReviewProjectWeb.MediaRange do
  @moduledoc "Single byte ranges for private native-video delivery. Multipart ranges are rejected."

  def parse([], size) when size > 0, do: {:ok, 200, 0, size}

  def parse([value], size) when size > 0 and byte_size(value) <= 128 do
    case Regex.run(~r/\Abytes=(\d*)-(\d*)\z/, value) do
      [_, "", ""] -> :error
      [_, "", suffix] -> suffix_range(String.to_integer(suffix), size)
      [_, first, ""] -> range(String.to_integer(first), size - 1, size)
      [_, first, last] -> range(String.to_integer(first), String.to_integer(last), size)
      _ -> :error
    end
  end

  def parse(_, _), do: :error

  defp suffix_range(0, _), do: :error
  defp suffix_range(length, size), do: {:ok, 206, max(0, size - length), min(length, size)}

  defp range(first, last, size) when first < size and last >= first,
    do: {:ok, 206, first, min(last, size - 1) - first + 1}

  defp range(_, _, _), do: :error
end
