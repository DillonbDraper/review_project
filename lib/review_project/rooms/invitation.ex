defmodule ReviewProject.Rooms.Invitation do
  @moduledoc "A reusable guest invitation. Only a digest of the credential is stored."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "room_invitations" do
    belongs_to :room, ReviewProject.Rooms.Room
    field :token_hash, :binary, redact: true
    field :revoked_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(invitation) do
    invitation
    |> change()
    |> validate_required([:room_id, :token_hash])
    |> unique_constraint(:token_hash)
    |> unique_constraint(:room_id, name: :room_invitations_one_active_per_room)
    |> foreign_key_constraint(:room_id)
  end
end
