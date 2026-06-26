defmodule ReviewProject.Repo do
  use Ecto.Repo,
    otp_app: :review_project,
    adapter: Ecto.Adapters.Postgres
end
