defmodule ReviewProject.Repo.Migrations.CreateRoomsInvitationsSeatsAndChatRoomMessages do
  use Ecto.Migration

  def change do
    # The independently maintained authentication migration must create users first.
    create table(:rooms, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :owner_id, references(:users, on_delete: :restrict), null: false
      add :name, :string, size: 120
      add :next_join_sequence, :bigint, null: false, default: 1
      add :next_chat_sequence, :bigint, null: false, default: 1
      add :closed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:rooms, [:owner_id, :inserted_at])

    create constraint(:rooms, :rooms_sequences,
             check: "next_join_sequence >= 1 AND next_chat_sequence >= 1"
           )

    create constraint(:rooms, :rooms_name,
             check: "name IS NULL OR char_length(btrim(name)) BETWEEN 1 AND 120"
           )

    create table(:room_invitations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:room_invitations, [:token_hash])

    create unique_index(:room_invitations, [:room_id],
             name: :room_invitations_one_active_per_room,
             where: "revoked_at IS NULL"
           )

    create constraint(:room_invitations, :room_invitations_digest,
             check: "octet_length(token_hash) = 32"
           )

    create table(:room_seats, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all), null: false
      add :slot, :smallint, null: false
      add :browser_identity_hash, :binary
      add :display_name, :string, size: 60, null: false
      add :join_sequence, :bigint, null: false
      add :disconnected_at, :utc_datetime_usec
      add :reserved_until, :utc_datetime_usec
      add :connection_generation, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:room_seats, [:room_id, :slot])
    create unique_index(:room_seats, [:room_id, :join_sequence])
    create unique_index(:room_seats, [:room_id, :id])

    create unique_index(:room_seats, [:room_id, :browser_identity_hash],
             name: :room_seats_guest_browser_identity,
             where: "slot > 0"
           )

    create constraint(:room_seats, :room_seats_identity,
             check: """
             (slot = 0 AND browser_identity_hash IS NULL AND join_sequence = 0
               AND reserved_until IS NULL)
             OR
             (slot BETWEEN 1 AND 4 AND browser_identity_hash IS NOT NULL
               AND octet_length(browser_identity_hash) = 32 AND join_sequence > 0
               AND ((disconnected_at IS NULL AND reserved_until IS NULL)
                 OR (disconnected_at IS NOT NULL AND reserved_until IS NOT NULL
                   AND reserved_until = disconnected_at + interval '30 seconds')))
             """
           )

    create constraint(:room_seats, :room_seats_generation, check: "connection_generation >= 0")

    create constraint(:room_seats, :room_seats_display_name,
             check:
               "char_length(btrim(display_name)) BETWEEN 1 AND 60 AND display_name !~ '[[:cntrl:]]'"
           )

    create table(:chat_room_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all), null: false

      add :sender_seat_id,
          references(:room_seats,
            type: :binary_id,
            with: [room_id: :room_id],
            on_delete: {:nilify, [:sender_seat_id]}
          )

      add :sender_display_name, :string, size: 60, null: false
      add :sequence, :bigint, null: false
      add :body, :text, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:chat_room_messages, [:room_id, :sequence])
    create index(:chat_room_messages, [:room_id, :inserted_at, :id])
    create index(:chat_room_messages, [:sender_seat_id])

    create constraint(:chat_room_messages, :chat_room_messages_sequence, check: "sequence > 0")

    create constraint(:chat_room_messages, :chat_room_messages_sender_name,
             check: "char_length(btrim(sender_display_name)) BETWEEN 1 AND 60"
           )

    create constraint(:chat_room_messages, :chat_room_messages_body,
             check: "char_length(body) BETWEEN 1 AND 2000 AND body ~ '[^[:space:]]'"
           )
  end
end
