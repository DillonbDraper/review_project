defmodule ReviewProject.MixProject do
  use Mix.Project

  def project do
    [
      app: :review_project,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers() ++ [:hologram],
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {ReviewProject.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:argon2_elixir, "~> 4.0"},
      {:ueberauth, "~> 0.10.8"},
      {:ueberauth_google, "~> 0.12.1"},
      {:phoenix, "~> 1.8.2"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:tidewave, "~> 0.9", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},

      # --- Hologram: Elixir->JS for client-side drawing / interop (Phase 2) ---
      {:hologram, "~> 0.12.1"},
      # Hologram uses the old :uuid app; Membrane uses its renamed :elixir_uuid
      # successor. Both packages define UUID and UUID.Mixfile, breaking clean
      # builds. Keep the old app name through a shim and compile UUID only once.
      {:uuid, path: "vendor/uuid_compat", override: true},

      # --- Membrane: WebRTC SFU (live cam/voice conferencing, Phase 1) ---
      {:membrane_core, "~> 1.3"},
      # Raw WebRTC building block. Alternative to evaluate in the Phase 0
      # RTC-layer spike: {:membrane_rtc_engine, "~> 0.25.0"} (Fishjam umbrella).
      {:membrane_webrtc_plugin, "~> 0.26.5"},
      # Phase 0 spike: membrane_webrtc_plugin 0.26.5 pins ex_webrtc ~> 0.15,
      # but current browser DTLS interop appears stuck there. Try the latest
      # ex_webrtc stack explicitly for the raw WebRTC deployability proof.
      {:ex_webrtc, "~> 0.17.0", override: true},
      {:ex_ice, "~> 0.16.0", override: true},

      # --- Membrane: media codecs & audio processing ---
      {:membrane_h264_ffmpeg_plugin, "~> 0.32.6"},
      {:membrane_opus_plugin, "~> 0.20.7"},
      {:membrane_aac_plugin, "~> 0.19.3"},
      {:membrane_aac_fdk_plugin, "~> 0.18.13"},
      {:membrane_ffmpeg_swresample_plugin, "~> 0.20.5"},

      # --- Membrane: server-side recompose -> MP4 export (Phase 3) ---
      # NOTE: the video compositor is intentionally not pinned yet — pick it during
      # the Phase 0/3 recompose spike. The maintained option, {:membrane_smelter_plugin},
      # drives a standalone Smelter binary AND currently pulls websockex 0.4.3, which
      # fails to compile on Elixir 1.20. Revisit once that's resolved or use a fork.
      {:membrane_audio_mix_plugin, "~> 0.16.4"},
      {:membrane_mp4_plugin, "~> 0.36.9"},
      {:membrane_file_plugin, "~> 0.17.3"},
      {:membrane_realtimer_plugin, "~> 0.11.0"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "compile.hologram": [&isolate_test_assets/1, "compile.hologram"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind review_project", "esbuild review_project"],
      "assets.deploy": [
        "tailwind review_project --minify",
        "esbuild review_project --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end

  # Mix normally symlinks the app's priv directory back to the checkout. Hologram
  # removes obsolete bundles on compilation, so tests must compile against their
  # own copy instead of deleting bundles used by a running development server.
  defp isolate_test_assets(_args) do
    if Mix.env() == :test do
      target = Path.join(Mix.Project.app_path(), "priv")

      case File.read_link(target) do
        {:ok, _source} ->
          File.rm!(target)
          File.cp_r!("priv", target)

        {:error, :enoent} ->
          File.cp_r!("priv", target)

        {:error, :einval} ->
          :ok
      end
    end
  end
end
