defmodule ReviewProject.VideoSourceTest do
  use ExUnit.Case, async: true

  alias ReviewProject.VideoSource

  @id "M7lc1UVf-VE"

  test "accepts common YouTube link formats and bare video IDs" do
    for source <- [
          @id,
          "  #{@id}  ",
          "https://www.youtube.com/watch?v=#{@id}&t=12",
          "https://m.youtube.com/watch?v=#{@id}",
          "https://youtu.be/#{@id}?si=share-code",
          "youtube.com/shorts/#{@id}",
          "https://www.youtube.com/live/#{@id}",
          "https://www.youtube-nocookie.com/embed/#{@id}"
        ] do
      assert VideoSource.youtube_id(source) == {:ok, @id}
    end
  end

  test "rejects other hosts, malformed IDs, credentials, and executable input" do
    for source <- [
          "",
          nil,
          42,
          "https://example.com/watch?v=#{@id}",
          "https://youtube.com.evil.example/watch?v=#{@id}",
          "https://youtube.com@evil.example/watch?v=#{@id}",
          "https://user:password@youtube.com/watch?v=#{@id}",
          "https://youtu.be/#{@id}/extra",
          "https://www.youtube.com/playlist?list=123",
          "https://www.youtube.com/watch?v=short",
          "https://www.youtube.com/watch?v=#{@id}%22",
          "javascript:alert(1)",
          "<iframe src='https://evil.example'></iframe>",
          String.duplicate("x", 2049)
        ] do
      assert VideoSource.youtube_id(source) == :error
    end
  end

  test "embeds use a fixed YouTube host and discard supplied query parameters" do
    assert {:ok, id} =
             VideoSource.youtube_id(
               "https://youtu.be/#{@id}?autoplay=1&origin=https://evil.example"
             )

    assert VideoSource.embed_url(id) == "https://www.youtube-nocookie.com/embed/#{@id}"
  end
end
