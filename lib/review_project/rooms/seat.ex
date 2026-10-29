defmodule ReviewProject.Rooms.Seat do
  @moduledoc "Current occupancy, not a permanent membership or attendance record."
  use Ecto.Schema
  import Ecto.Changeset
  alias ReviewProject.Rooms.Validation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "room_seats" do
    belongs_to :room, ReviewProject.Rooms.Room
    field :slot, :integer
    field :browser_identity_hash, :binary, redact: true
    field :display_name, :string
    field :join_sequence, :integer
    field :disconnected_at, :utc_datetime_usec
    field :reserved_until, :utc_datetime_usec
    field :connection_generation, :integer, default: 0
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(seat, attrs) do
    seat
    |> cast(attrs, [:display_name])
    |> Validation.display_name()
    |> validate_required([:room_id, :slot, :join_sequence])
    |> unique_constraint([:room_id, :slot])
    |> unique_constraint([:room_id, :join_sequence])
    |> unique_constraint([:room_id, :browser_identity_hash],
      name: :room_seats_guest_browser_identity
    )
    |> check_constraint(:slot, name: :room_seats_identity)
    |> foreign_key_constraint(:room_id)
  end
end
