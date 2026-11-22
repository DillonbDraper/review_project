defmodule ReviewProject.Rooms.ChatRoomMessage do
  @moduledoc "Immutable durable chat with a server-captured sender name."
  use Ecto.Schema
  import Ecto.Changeset
  alias ReviewProject.Rooms.Validation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "chat_room_messages" do
    belongs_to :room, ReviewProject.Rooms.Room
    belongs_to :sender_seat, ReviewProject.Rooms.Seat
    field :sender_display_name, :string
    field :sequence, :integer
    field :body, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:body])
    |> update_change(:body, &Validation.trim/1)
    |> validate_required([:room_id, :sequence, :body])
    |> validate_length(:body, max: 1_000, count: :codepoints)
    |> validate_format(:body, ~r/\A[^\x00]*\z/u, message: "must not contain null characters")
    |> Validation.display_name(:sender_display_name)
    |> unique_constraint([:room_id, :sequence])
    |> foreign_key_constraint(:room_id)
    |> foreign_key_constraint(:sender_seat_id)
    |> check_constraint(:body, name: :chat_room_messages_body)
    |> check_constraint(:body, name: :chat_room_messages_body_length)
  end
end
