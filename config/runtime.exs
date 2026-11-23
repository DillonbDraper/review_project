import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/review_project start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :review_project, ReviewProjectWeb.Endpoint, server: true
end

config :review_project, ReviewProjectWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Shared by development and releases. Only the secret's file path is configured;
# the secret itself is read server-side when an admitted member requests ICE.
if path = System.get_env("CONFERENCE_ICE_CONFIG") do
  ice =
    with {:ok, json} <- File.read(path),
         {:ok, config} when is_map(config) <- Jason.decode(json),
         do: config

  config :review_project, :conference_ice, if(is_map(ice), do: ice, else: :unavailable)
end

# Log in with Google is enabled when its OAuth client credentials are set.
# Tests use the fixed credentials from config/test.exs instead.
if config_env() != :test and System.get_env("GOOGLE_CLIENT_ID") do
  config :ueberauth, Ueberauth.Strategy.Google.OAuth,
    client_id: System.fetch_env!("GOOGLE_CLIENT_ID"),
    client_secret: System.fetch_env!("GOOGLE_CLIENT_SECRET")
end

# Opt-in development spike. Never put the shared secret into browser assets.
if config_env() == :dev and System.get_env("TURN_SPIKE_CONFIG") do
  turn = System.fetch_env!("TURN_SPIKE_CONFIG") |> File.read!() |> Jason.decode!()
  {:ok, address} = :inet.parse_ipv4_address(String.to_charlist(turn["host"]))

  true =
    match?({10, _, _, _}, address) or match?({192, 168, _, _}, address) or
      (elem(address, 0) == 172 and elem(address, 1) in 16..31)

  ttl = turn["ttl_seconds"]
  true = is_integer(ttl) and ttl in 60..86_400
  secret = turn["secret_file"] |> File.read!() |> String.trim()
  true = byte_size(secret) >= 32
  tls_host = turn["tls_host"] || turn["host"]

  true =
    is_binary(tls_host) and byte_size(tls_host) <= 253 and
      Regex.match?(~r/\A[a-zA-Z0-9.-]+\z/, tls_host)

  config :review_project, :turn_spike, %{
    host: turn["host"],
    tls_host: tls_host,
    secret_file: turn["secret_file"],
    ttl_seconds: ttl
  }
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  database_ssl =
    if System.get_env("DATABASE_SSL") in ~w(true 1) do
      database_host = URI.parse(database_url).host || raise "DATABASE_URL must include a host"

      extra_certs =
        if path = System.get_env("DATABASE_CA_CERT_FILE") do
          case path |> File.read!() |> :public_key.pem_decode() do
            [] ->
              raise "DATABASE_CA_CERT_FILE must contain PEM certificates"

            entries ->
              Enum.map(entries, fn
                {:Certificate, der, :not_encrypted} -> der
                _ -> raise "DATABASE_CA_CERT_FILE must contain only PEM certificates"
              end)
          end
        else
          []
        end

      [
        verify: :verify_peer,
        cacerts: extra_certs ++ :public_key.cacerts_get(),
        server_name_indication: String.to_charlist(database_host),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    else
      false
    end

  config :review_project, ReviewProject.Repo,
    ssl: database_ssl,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.fetch_env!("PHX_HOST")

  config :review_project, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :review_project, ReviewProjectWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :review_project, ReviewProjectWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :review_project, ReviewProjectWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  resend_api_key = System.get_env("RESEND_API_KEY")

  if is_nil(resend_api_key) or String.trim(resend_api_key) == "" do
    raise "environment variable RESEND_API_KEY is required for production email"
  end

  config :review_project, ReviewProject.Mailer,
    adapter: Swoosh.Adapters.Resend,
    api_key: resend_api_key
end
