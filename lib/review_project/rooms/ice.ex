defmodule ReviewProject.Rooms.ICE do
  @moduledoc "Runtime ICE configuration and short-lived coturn REST credentials."

  def issue(
        seat_id,
        config \\ Application.get_env(:review_project, :conference_ice),
        now \\ System.system_time(:second)
      )

  def issue(_seat_id, nil, _now),
    do: {:ok, %{servers: [], expires_at: nil, refresh_after: nil}}

  def issue(seat_id, config, now) when is_map(config) do
    stun = Map.get(config, "stun_urls", [])
    turn = Map.get(config, "turn_urls", [])
    ttl = Map.get(config, "ttl_seconds", 3600)

    with true <- urls?(stun, ~r/\Astun:[a-zA-Z0-9.\-\[\]:]+\z/),
         true <- urls?(turn, ~r/\Aturns?:[a-zA-Z0-9.\-\[\]:]+(?:\?transport=(?:udp|tcp))?\z/),
         true <- is_integer(ttl) and ttl in 60..86_400,
         {:ok, relay} <- relay(seat_id, config, turn, now + ttl) do
      servers = if stun == [], do: relay, else: [%{urls: stun} | relay]

      {:ok,
       %{
         servers: servers,
         expires_at: if(turn != [], do: now + ttl),
         refresh_after: if(turn != [], do: div(ttl, 2))
       }}
    else
      _ -> {:error, :ice_unavailable}
    end
  end

  def issue(_seat_id, _config, _now), do: {:error, :ice_unavailable}

  defp relay(_seat_id, _config, [], _expires), do: {:ok, []}

  defp relay(seat_id, config, urls, expires) do
    with path when is_binary(path) <- config["secret_file"],
         {:ok, contents} <- File.read(path),
         secret = String.trim(contents),
         true <- byte_size(secret) >= 32 do
      username = "#{expires}:#{seat_id}"
      password = :crypto.mac(:hmac, :sha, secret, username) |> Base.encode64()
      {:ok, [%{urls: urls, username: username, credential: password}]}
    else
      _ -> {:error, :ice_unavailable}
    end
  end

  defp urls?(urls, pattern) when is_list(urls),
    do: Enum.all?(urls, &(is_binary(&1) and byte_size(&1) <= 1024 and Regex.match?(pattern, &1)))

  defp urls?(_urls, _pattern), do: false
end
