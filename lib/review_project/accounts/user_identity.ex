defmodule ReviewProject.Accounts.UserIdentity do
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_identities" do
    field :provider, :string
    field :provider_uid, :string
    belongs_to :user, ReviewProject.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  A changeset linking the user to their account at an external identity provider.

  The provider's `provider_uid` must be its stable account identifier (such as
  Google's `sub`), never an email address, which can change hands.
  """
  def link_changeset(user, provider, provider_uid) do
    %__MODULE__{user_id: user.id, provider: provider, provider_uid: provider_uid}
    |> change()
    |> unique_constraint([:provider, :provider_uid])
  end
end
