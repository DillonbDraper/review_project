defmodule ReviewProject.SyncSpikes.ICETest do
  use ExUnit.Case, async: true
  alias ReviewProject.SyncSpikes.ICE

  setup do
    path = Path.join(System.tmp_dir!(), "turn-secret-#{System.unique_integer([:positive])}")
    File.write!(path, "research-secret-not-for-production\n")
    on_exit(fn -> File.rm!(path) end)
    %{config: %{host: "192.168.1.58", secret_file: path, ttl_seconds: 3600}}
  end

  test "relay mode restricts transport and signs expiring member credentials", %{config: config} do
    now = System.system_time(:second)
    assert {:ok, ice} = ICE.issue("member-uuid", "relay-tcp", config)
    assert ice.policy == "relay"
    assert ice.expires_at in (now + 3600)..(now + 3601)
    assert ice.refresh_after == 1800
    assert [server] = ice.servers
    assert server.urls == ["turn:192.168.1.58:3478?transport=tcp"]
    assert server.username == "#{ice.expires_at}:member-uuid"

    expected =
      :crypto.mac(:hmac, :sha, "research-secret-not-for-production", server.username)
      |> Base.encode64()

    assert server.credential == expected
    refute inspect(ice) =~ "research-secret"
  end

  test "each forced transport has one URL, automatic includes STUN, and STUN has no credentials",
       %{config: config} do
    for mode <- ~w(relay-udp relay-tcp relay-tls) do
      assert {:ok, %{servers: [%{urls: [_]}], policy: "relay"}} =
               ICE.issue("member", mode, config)
    end

    assert {:ok, %{servers: [stun, turn], policy: "all"}} = ICE.issue("member", "auto", config)
    assert Map.keys(stun) == [:urls]
    assert length(turn.urls) == 3
    assert {:ok, %{servers: [^stun]}} = ICE.issue("member", "stun", config)
  end

  test "direct works without TURN; forced relay fails closed without configuration" do
    assert {:ok, %{servers: [], policy: "all"}} = ICE.issue("member", "direct", nil)
    assert {:ok, %{servers: []}} = ICE.issue("member", "auto", nil)
    assert {:error, :turn_not_configured} = ICE.issue("member", "relay-udp", nil)
    assert {:error, :invalid_ice_mode} = ICE.issue("member", "made-up", nil)
  end

  test "TLS uses its certificate hostname while UDP keeps the LAN address", %{config: config} do
    config = Map.put(config, :tls_host, "turn-spike.example.test")

    assert {:ok, %{servers: [%{urls: ["turns:turn-spike.example.test:5349?transport=tcp"]}]}} =
             ICE.issue("member", "relay-tls", config)

    assert {:ok, %{servers: [%{urls: ["turn:192.168.1.58:3478?transport=udp"]}]}} =
             ICE.issue("member", "relay-udp", config)
  end
end
