# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :review_project, :scopes,
  user: [
    default: true,
    module: ReviewProject.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: ReviewProject.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :review_project,
  ecto_repos: [ReviewProject.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :review_project, ReviewProjectWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ReviewProjectWeb.ErrorHTML, json: ReviewProjectWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ReviewProject.PubSub,
  live_view: [signing_salt: "89kXNykF"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :review_project, ReviewProject.Mailer, adapter: Swoosh.Adapters.Local
config :review_project, :mail_sender, {"Review Project", "noreply@whatgrabsme.org"}

# Configure log in with Google. The OAuth client credentials are read
# from the environment in config/runtime.exs.
config :ueberauth, Ueberauth,
  base_path: "/users/auth",
  providers: [
    google: {Ueberauth.Strategy.Google, [default_scope: "email", prompt: "select_account"]}
  ]

# Make OAuth2 requests with Mint, which verifies TLS certificates by
# default, instead of the :httpc adapter.
config :oauth2, adapter: Tesla.Adapter.Mint

# Configure esbuild (the version is required)
# On NixOS, use the Nix-provided binary instead of Phoenix's downloaded
# generic Linux executable in _build, which cannot run without patching.
config :esbuild,
  version: System.get_env("ESBUILD_VERSION") || "0.25.4",
  version_check: false,
  path:
    System.get_env("MIX_ESBUILD_PATH") || System.get_env("ESBUILD_PATH") ||
      System.find_executable("esbuild"),
  review_project: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
# On NixOS, use the Nix-provided binary instead of Phoenix's downloaded
# generic Linux executable in _build, which cannot run without patching.
config :tailwind,
  version: System.get_env("TAILWIND_VERSION") || "4.1.12",
  version_check: false,
  path:
    System.get_env("MIX_TAILWIND_PATH") || System.get_env("TAILWIND_PATH") ||
      System.find_executable("tailwindcss"),
  review_project: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Browser/session and room invitation credentials, and the OAuth
# authorization codes from log in with Google, must not enter request logs.
config :phoenix, :filter_parameters, [
  "password",
  "token",
  "host_token",
  "invitation",
  "credential",
  "secret",
  "_csrf_token",
  "code",
  "browser_identity"
]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
