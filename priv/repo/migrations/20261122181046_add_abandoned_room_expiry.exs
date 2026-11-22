defmodule ReviewProject.Repo.Migrations.AddAbandonedRoomExpiry do
  use Ecto.Migration

  def change do
    alter table(:rooms) do
      add :expires_at, :utc_datetime_usec
      add :expired_at, :utc_datetime_usec
    end

    create index(:rooms, [:expires_at], where: "closed_at IS NULL")

    # Give existing empty rooms a full grace period when this is deployed.
    # Occupied rooms stay open; stale connections are reconciled by the worker.
    execute """
            UPDATE rooms SET expires_at = timezone('UTC', now()) + interval '3 hours'
            WHERE closed_at IS NULL AND NOT EXISTS (
              SELECT 1 FROM room_seats WHERE room_id = rooms.id
              AND connection_generation > 0 AND disconnected_at IS NULL
            )
            """,
            "UPDATE rooms SET expires_at = NULL"
  end
end
