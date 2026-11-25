defmodule ReviewProject.Rooms.ICETest do
  use ExUnit.Case, async: true
  alias ReviewProject.Rooms.ICE

  @tag :tmp_dir
  test "signed credentials expire independently of the room and renew before expiry", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "secret")
    secret = String.duplicate("s", 32)
    File.write!(path, secret)

    config = %{
      "stun_urls" => ["stun:relay.example.com:3478"],
      "turn_urls" => [
        "turn:relay.example.com:3478?transport=udp",
        "turn:relay.example.com:3478?transport=tcp",
        "turns:relay.example.com:5349?transport=tcp"
      ],
      "secret_file" => path,
      "ttl_seconds" => 60
    }

    assert {:ok, %{servers: [_, relay], expires_at: 1060, refresh_after: 30}} =
             ICE.issue("seat", config, 1000)

    assert relay.username == "1060:seat"
    assert relay.credential == Base.encode64(:crypto.mac(:hmac, :sha, secret, "1060:seat"))
    refute inspect(relay) =~ secret
    assert {:ok, %{servers: [_, renewed], expires_at: 1090}} = ICE.issue("seat", config, 1030)
    refute renewed.credential == relay.credential

    assert {:error, :ice_unavailable} =
             ICE.issue("seat", %{config | "secret_file" => path <> "missing"}, 1000)
  end

  @tag :tmp_dir
  test "staging metadata issues credentials only with a usable secret file", %{tmp_dir: dir} do
    config = File.read!("priv/conference/staging-ice.json") |> Jason.decode!()

    assert Enum.sort(Map.keys(config)) ==
             Enum.sort(["stun_urls", "turn_urls", "secret_file", "ttl_seconds"])

    assert config["stun_urls"] == ["stun:turn.whatgrabsme.org:3478"]

    assert config["turn_urls"] == [
             "turn:turn.whatgrabsme.org:3478?transport=udp",
             "turn:turn.whatgrabsme.org:3478?transport=tcp",
             "turns:turn.whatgrabsme.org:5349?transport=tcp"
           ]

    assert config["ttl_seconds"] == 3600
    assert config["secret_file"] == "/app/secrets/conference-turn-secret"
    path = Path.join(dir, "dummy-secret")
    config = Map.put(config, "secret_file", path)
    assert ICE.issue("seat", config, 1000) == {:error, :ice_unavailable}

    for contents <- ["", "short", String.duplicate(" ", 40)] do
      File.write!(path, contents)
      assert ICE.issue("seat", config, 1000) == {:error, :ice_unavailable}
    end

    secret = String.duplicate("dummy-only", 4)
    File.write!(path, secret <> "\n")

    assert {:ok, %{servers: [stun, relay], expires_at: 4600, refresh_after: 1800}} =
             ICE.issue("seat", config, 1000)

    assert stun.urls == config["stun_urls"]
    assert relay.urls == config["turn_urls"]
    assert relay.username == "4600:seat"
    assert relay.credential == Base.encode64(:crypto.mac(:hmac, :sha, secret, "4600:seat"))
    refute inspect(relay) =~ secret
    File.rm!(path)
    assert ICE.issue("seat", config, 1000) == {:error, :ice_unavailable}

    assert ICE.issue("seat", Map.put(config, "secret_file", dir), 1000) ==
             {:error, :ice_unavailable}
  end

  test "absent relay configuration is direct and invalid configuration fails closed" do
    assert {:ok, %{servers: [], expires_at: nil, refresh_after: nil}} = ICE.issue("seat", nil, 0)

    for config <- [
          :unavailable,
          %{"turn_urls" => "turn:relay"},
          %{"stun_urls" => ["https://relay"]},
          %{"turn_urls" => ["turn:relay"], "ttl_seconds" => 0},
          %{"turn_urls" => ["turn:relay"]}
        ] do
      assert {:error, :ice_unavailable} = ICE.issue("seat", config, 0)
    end
  end
end
