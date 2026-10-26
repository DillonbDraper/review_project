defmodule ReviewProject.Repo.Migrations.RenameUsersTokensUsersIdToUserId do
  use Ecto.Migration

  # The spike's authentication was generated with a `Users` schema, which
  # named this foreign key `users_id`. The `User` schema expects `user_id`.
  def change do
    rename table(:users_tokens), :users_id, to: :user_id
    rename index(:users_tokens, [:users_id]), to: "users_tokens_user_id_index"

    execute(
      "ALTER TABLE users_tokens RENAME CONSTRAINT users_tokens_users_id_fkey TO users_tokens_user_id_fkey",
      "ALTER TABLE users_tokens RENAME CONSTRAINT users_tokens_user_id_fkey TO users_tokens_users_id_fkey"
    )
  end
end
