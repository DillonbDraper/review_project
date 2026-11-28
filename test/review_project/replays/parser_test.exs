defmodule ReviewProject.Replays.ParserTest do
  use ExUnit.Case, async: true
  alias ReviewProject.Slippi

  for name <- ~w(unranked_game1 doubles FodPlatforms synthetic-rollback-characters) do
    test "accepts browser-supported corpus #{name}" do
      path = unpack(unquote(name))
      assert {:ok, %{frames: frames, duration: duration}} = Slippi.inspect_file(path)
      assert frames > 0
      assert duration == frames / 60
    end
  end

  for name <-
        ~w(incomplete invalid-player invalid-required-float invalid-frame-allocation unsupported-character invalid-container-allocation invalid-event-bounds) do
    test "rejects browser-rejected corpus #{name}" do
      assert {:error, :invalid_replay} = Slippi.inspect_file(unpack(unquote(name)))
    end
  end

  defp unpack(name) do
    path = Path.join(System.tmp_dir!(), "replay-parser-#{Ecto.UUID.generate()}.slp")
    File.write!(path, File.read!("test/fixtures/slippi/#{name}.slp.gz") |> :zlib.gunzip())
    on_exit(fn -> File.rm(path) end)
    path
  end
end
