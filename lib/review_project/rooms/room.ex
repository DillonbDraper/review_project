defmodule ReviewProject.Rooms.Room do
  @moduledoc "Durable room identity. Ownership is independent of live playback authority."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "rooms" do
    # Auth is implemented separately; avoid depending on its schema module.
    field :owner_id, :integer
    field :name, :string
    field :next_join_sequence, :integer, default: 1
    field :next_chat_sequence, :integer, default: 1
    field :closed_at, :utc_datetime_usec
    has_many :seats, ReviewProject.Rooms.Seat
    has_many :invitations, ReviewProject.Rooms.Invitation
    has_many :messages, ReviewProject.Rooms.ChatRoomMessage
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:name])
    |> update_change(:name, &ReviewProject.Rooms.Validation.trim/1)
    |> validate_length(:name, min: 1, max: 120, count: :codepoints)
    |> validate_required([:owner_id])
    |> foreign_key_constraint(:owner_id)
  end
end
