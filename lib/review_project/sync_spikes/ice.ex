defmodule ReviewProject.SyncSpikes.ICE do
  @moduledoc "Temporary coturn REST credentials for the development mesh spike only."

  @modes ~w(direct auto stun relay-udp relay-tcp relay-tls)

  def issue(member_id, mode, config \\ Application.get_env(:review_project, :turn_spike)) do
    cond do
      mode not in @modes -> {:error, :invalid_ice_mode}
      mode == "direct" -> {:ok, %{servers: [], policy: "all", mode: mode}}
      is_nil(config) and mode == "auto" -> {:ok, %{servers: [], policy: "all", mode: mode}}
      is_nil(config) -> {:error, :turn_not_configured}
      true -> credentials(member_id, mode, config)
    end
  end

  defp credentials(member_id, mode, config) do
    ttl = config.ttl_seconds
    expires = System.system_time(:second) + ttl
    username = "#{expires}:#{member_id}"
    secret = config.secret_file |> File.read!() |> String.trim()
    password = :crypto.mac(:hmac, :sha, secret, username) |> Base.encode64()
    host = config.host
    tls_host = Map.get(config, :tls_host, host)

    urls = %{
      "relay-udp" => "turn:#{host}:3478?transport=udp",
      "relay-tcp" => "turn:#{host}:3478?transport=tcp",
      "relay-tls" => "turns:#{tls_host}:5349?transport=tcp"
    }

    stun = %{urls: ["stun:#{host}:3478"]}
    turn = fn urls -> %{urls: urls, username: username, credential: password} end

    servers =
      case mode do
        "stun" ->
          [stun]

        "auto" ->
          [stun, turn.(Enum.map(~w(relay-udp relay-tcp relay-tls), &Map.fetch!(urls, &1)))]

        relay ->
          [turn.([Map.fetch!(urls, relay)])]
      end

    {:ok,
     %{
       servers: servers,
       policy: if(String.starts_with?(mode, "relay-"), do: "relay", else: "all"),
       mode: mode,
       expires_at: expires,
       refresh_after: div(ttl, 2)
     }}
  end
end
