import Config

# Compile and start the real Hologram runtime for endpoint integration tests.
System.put_env("HOLOGRAM_START", "1")

# Exercise the development-only playback transport in channel tests.
config :review_project, :youtube_sync_spike, true

# Only in tests, remove the complexity from the password hashing algorithm
config :argon2_elixir, t_cost: 1, m_cost: 8

# Enable log in with Google. Tests never contact Google.
config :ueberauth, Ueberauth.Strategy.Google.OAuth,
  client_id: "test-client-id",
  client_secret: "test-client-secret"

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :review_project, ReviewProject.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database:
    System.get_env("ROOMS_TEST_DATABASE") ||
      "review_project_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :review_project, ReviewProjectWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "FeRO+PzwzBOK8z8t6Nn31fOkUwVh4jJvxLp1CB0jrBzQ7s4xUac784VonbOmEGXB",
  server: false

# In test we don't send emails
config :review_project, ReviewProject.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
