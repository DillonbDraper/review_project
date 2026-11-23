defmodule ReviewProject.Release do
  @moduledoc """
  Release-only operations. Migrations load the application without starting its
  supervision tree or HTTP server; failures propagate to the deploy command.
  """

  @app :review_project

  def migrate do
    {:ok, _} = Application.ensure_all_started(:ssl)

    case Application.load(@app) do
      :ok -> :ok
      {:error, {:already_loaded, @app}} -> :ok
      {:error, reason} -> raise "Unable to load release application: #{inspect(reason)}"
    end

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      if Process.whereis(repo), do: raise("Migrations require a stopped repository")
      original = Application.fetch_env!(@app, repo)
      options = migration_options(repo.config(), System.get_env("MIGRATION_DATABASE_URL"))

      try do
        Application.put_env(@app, repo, Keyword.merge(original, options))
        {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
      after
        Application.put_env(@app, repo, original)
      end
    end

    :ok
  end

  @doc false
  def migration_options(_config, nil), do: []

  def migration_options(config, url) do
    host = URI.parse(url).host || raise "MIGRATION_DATABASE_URL must include a host"

    ssl =
      case Keyword.get(config, :ssl, false) do
        options when is_list(options) ->
          Keyword.put(options, :server_name_indication, String.to_charlist(host))

        other ->
          other
      end

    [url: url, ssl: ssl, pool_size: 2]
  end
end
