defmodule ReviewProjectWeb.MediaRangeTest do
  use ExUnit.Case, async: true
  alias ReviewProjectWeb.MediaRange

  test "full, bounded, open and suffix byte ranges clamp to file length" do
    assert MediaRange.parse([], 10) == {:ok, 200, 0, 10}
    assert MediaRange.parse(["bytes=0-0"], 10) == {:ok, 206, 0, 1}
    assert MediaRange.parse(["bytes=2-999"], 10) == {:ok, 206, 2, 8}
    assert MediaRange.parse(["bytes=9-"], 10) == {:ok, 206, 9, 1}
    assert MediaRange.parse(["bytes=-3"], 10) == {:ok, 206, 7, 3}
    assert MediaRange.parse(["bytes=-999"], 10) == {:ok, 206, 0, 10}
  end

  test "unsatisfiable, malformed, duplicate and multi-ranges fail boundedly" do
    for header <- [
          "bytes=",
          "bytes=-",
          "bytes=-0",
          "bytes=10-",
          "bytes=5-4",
          "bytes=0-1,3-4",
          "items=0-1",
          "bytes=+1-2",
          "bytes= 1-2",
          "bytes=" <> String.duplicate("9", 200) <> "-"
        ] do
      assert MediaRange.parse([header], 10) == :error
    end

    assert MediaRange.parse(["bytes=0-1", "bytes=2-3"], 10) == :error
    assert MediaRange.parse([], 0) == :error
  end
end
