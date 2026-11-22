defmodule ReviewProject.Rooms.Store do
  @moduledoc false
  import Ecto.Query
  alias ReviewProject.Repo
  alias ReviewProject.Rooms.{ChatRoomMessage, Invitation, Room, Seat}

  # The scope must come from verified authentication, never request parameters.
  def owner_id(%{user: %{id: id}}) when is_integer(id) and id > 0, do: id
  def owner_id(_), do: nil

  def create_room(scope, attrs) do
    case owner_id(scope) do
      nil ->
        {:error, :authentication_required}

      owner_id ->
        Repo.transaction(fn ->
          now = DateTime.utc_now()

          room =
            insert!(
              Room.changeset(
                %Room{owner_id: owner_id, expires_at: abandonment_deadline(now)},
                attrs
              )
            )

          insert!(
            Seat.changeset(
              %Seat{room_id: room.id, slot: 0, join_sequence: 0, disconnected_at: now},
              %{
                display_name: "Host"
              }
            )
          )

          token = new_invitation!(room.id)
          %{room: room, invitation_token: token}
        end)
    end
  end

  def list_rooms(scope) do
    case owner_id(scope) do
      nil ->
        {:error, :authentication_required}

      id ->
        now = DateTime.utc_now()

        {:ok,
         Repo.all(
           from r in Room,
             where: r.owner_id == ^id,
             where: is_nil(r.expired_at) and (is_nil(r.expires_at) or r.expires_at > ^now),
             order_by: [desc: r.inserted_at, desc: r.id]
         )}
    end
  end

  def get_room(scope, id) do
    Repo.transaction(fn ->
      room = lock_room!(id)
      authorize_owner!(scope, room)
      room
    end)
  end

  def rotate_invitation(scope, id, now) do
    Repo.transaction(fn ->
      room = lock_room!(id)
      authorize_owner!(scope, room)
      require_open!(room)

      Repo.update_all(
        from(i in Invitation, where: i.room_id == ^room.id and is_nil(i.revoked_at)),
        set: [revoked_at: now, updated_at: now]
      )

      new_invitation!(room.id)
    end)
  end

  def close_room(scope, id, now) do
    Repo.transaction(fn ->
      room = lock_room!(id)
      authorize_owner!(scope, room)
      close_room!(room, now)
    end)
  end

  def open?(id, now \\ DateTime.utc_now()) do
    Repo.exists?(
      from r in Room,
        where: r.id == ^id and is_nil(r.closed_at),
        where: is_nil(r.expires_at) or r.expires_at > ^now
    )
  end

  def open_room(id) do
    Repo.transaction(fn ->
      room = lock_room!(id)
      require_open!(room)
      room
    end)
  end

  # On process recovery, persisted rows are identities/reservations, not live peers.
  def recover(id, now) do
    Repo.transaction(fn ->
      room = lock_room!(id)
      require_open!(room, now)

      Repo.update_all(from(s in Seat, where: s.room_id == ^id and s.slot == 0),
        set: [disconnected_at: now, updated_at: now]
      )

      Repo.update_all(
        from(s in Seat,
          where: s.room_id == ^id and s.slot > 0 and is_nil(s.disconnected_at)
        ),
        set: [
          disconnected_at: now,
          reserved_until: DateTime.add(now, 30, :second),
          updated_at: now
        ]
      )

      Repo.delete_all(
        from s in Seat,
          where: s.room_id == ^id and s.slot > 0 and s.reserved_until <= ^now
      )

      room = mark_abandoned!(room, now)
      %{room: room, seats: Repo.all(from s in Seat, where: s.room_id == ^id)}
    end)
  end

  def admit(scope, id, browser_identity, invitation, display_name, now) do
    Repo.transaction(fn ->
      room = lock_room!(id)
      require_open!(room, now)
      seats = Repo.all(from s in Seat, where: s.room_id == ^id)

      seat =
        if owner_id(scope) == room.owner_id do
          Enum.find(seats, &(&1.slot == 0)) || Repo.rollback(:owner_seat_missing)
        else
          require_invitation!(id, invitation)
          digest = browser_digest!(id, browser_identity)

          Enum.find(seats, &(&1.browser_identity_hash == digest)) ||
            new_guest!(room, seats, digest)
        end

      changeset =
        seat
        |> Seat.changeset(%{display_name: display_name})
        |> Ecto.Changeset.change(
          connection_generation: seat.connection_generation + 1,
          disconnected_at: nil,
          reserved_until: nil,
          updated_at: now
        )

      seat =
        if Ecto.get_meta(seat, :state) == :built, do: insert!(changeset), else: update!(changeset)

      room = update!(Ecto.Changeset.change(room, expires_at: nil))
      %{room: room, seat: seat}
    end)
  end

  def disconnect(id, seat_id, generation, now) do
    Repo.transaction(fn ->
      room = lock_room!(id)
      seat = current_seat!(id, seat_id, generation)
      reservation = if seat.slot > 0, do: DateTime.add(now, 30, :second)

      seat =
        update!(
          Ecto.Changeset.change(seat,
            disconnected_at: now,
            reserved_until: reservation,
            updated_at: now
          )
        )

      mark_abandoned!(room, now)
      seat
    end)
  end

  def release(id, seat_id, generation, now) do
    Repo.transaction(fn ->
      room = lock_room!(id)
      seat = current_seat!(id, seat_id, generation)

      seat =
        if seat.slot == 0 do
          update!(Ecto.Changeset.change(seat, disconnected_at: now, updated_at: now))
        else
          Repo.delete!(seat)
        end

      mark_abandoned!(room, now)
      seat
    end)
  end

  def expire(id, seat_ids) do
    Repo.transaction(fn ->
      lock_room!(id)

      Repo.delete_all(
        from s in Seat,
          where: s.room_id == ^id and s.slot > 0 and s.id in ^seat_ids
      )
    end)
  end

  def append_message(id, seat_id, generation, attrs) do
    Repo.transaction(fn ->
      room = lock_room!(id)
      require_open!(room)
      seat = current_seat!(id, seat_id, generation)
      if seat.disconnected_at, do: Repo.rollback(:not_joined)

      message =
        insert!(
          ChatRoomMessage.changeset(
            %ChatRoomMessage{
              room_id: id,
              sender_seat_id: seat.id,
              sender_display_name: seat.display_name,
              sequence: room.next_chat_sequence
            },
            attrs
          )
        )

      update!(Ecto.Changeset.change(room, next_chat_sequence: room.next_chat_sequence + 1))
      message
    end)
  end

  def history(id) do
    messages =
      Repo.all(
        from m in ChatRoomMessage,
          where: m.room_id == ^id,
          order_by: [asc: m.sequence]
      )

    {:ok, messages}
  end

  defp new_guest!(room, seats, digest) do
    occupied_slots = Enum.map(seats, & &1.slot)
    slot = Enum.find(1..4, &(&1 not in occupied_slots)) || Repo.rollback(:room_full)
    update!(Ecto.Changeset.change(room, next_join_sequence: room.next_join_sequence + 1))

    %Seat{
      room_id: room.id,
      slot: slot,
      browser_identity_hash: digest,
      join_sequence: room.next_join_sequence
    }
  end

  defp browser_digest!(id, identity) when is_binary(identity) and byte_size(identity) in 16..256,
    do: :crypto.hash(:sha256, [id, ":", identity])

  defp browser_digest!(_id, _identity), do: Repo.rollback(:invalid_browser_identity)

  defp new_invitation!(id) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    insert!(
      Invitation.changeset(%Invitation{room_id: id, token_hash: :crypto.hash(:sha256, token)})
    )

    token
  end

  defp require_invitation!(id, token) when is_binary(token) and byte_size(token) in 1..256 do
    digest = :crypto.hash(:sha256, token)

    unless Repo.exists?(
             from(i in Invitation,
               where: i.room_id == ^id and i.token_hash == ^digest and is_nil(i.revoked_at)
             ),
             log: false
           ),
           do: Repo.rollback(:invalid_invitation)
  end

  defp require_invitation!(_id, _token), do: Repo.rollback(:invalid_invitation)

  defp current_seat!(id, seat_id, generation) do
    Repo.one(
      from s in Seat,
        where: s.room_id == ^id and s.id == ^seat_id and s.connection_generation == ^generation
    ) ||
      Repo.rollback(:stale_connection)
  end

  defp lock_room!(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        Repo.one(from r in Room, where: r.id == ^id, lock: "FOR UPDATE") ||
          Repo.rollback(:not_found)

      _ ->
        Repo.rollback(:not_found)
    end
  end

  defp authorize_owner!(scope, room) do
    case owner_id(scope) do
      nil -> Repo.rollback(:authentication_required)
      id when id == room.owner_id -> :ok
      _ -> Repo.rollback(:forbidden)
    end
  end

  defp require_open!(room, now \\ DateTime.utc_now()) do
    cond do
      room.expired_at != nil -> Repo.rollback(:room_expired)
      room.closed_at != nil -> Repo.rollback(:room_closed)
      due?(room, now) -> Repo.rollback(:room_expired)
      true -> :ok
    end
  end

  defp due?(%Room{expires_at: nil}, _now), do: false
  defp due?(room, now), do: DateTime.compare(room.expires_at, now) != :gt

  defp abandonment_deadline(now),
    do:
      DateTime.add(
        now,
        Application.get_env(:review_project, :room_abandonment_seconds, 3 * 60 * 60),
        :second
      )

  defp mark_abandoned!(room, now) do
    connected? =
      Repo.exists?(from s in Seat, where: s.room_id == ^room.id and is_nil(s.disconnected_at))

    if is_nil(room.closed_at) and is_nil(room.expires_at) and not connected?,
      do: update!(Ecto.Changeset.change(room, expires_at: abandonment_deadline(now))),
      else: room
  end

  defp close_room!(room, now) do
    room = update!(Ecto.Changeset.change(room, closed_at: room.closed_at || now))

    Repo.update_all(from(i in Invitation, where: i.room_id == ^room.id and is_nil(i.revoked_at)),
      set: [revoked_at: now, updated_at: now]
    )

    Repo.delete_all(from s in Seat, where: s.room_id == ^room.id and s.slot > 0)

    Repo.update_all(from(s in Seat, where: s.room_id == ^room.id and s.slot == 0),
      set: [disconnected_at: now, updated_at: now]
    )

    room
  end

  def expired_room_ids(now) do
    Repo.all(
      from r in Room,
        where: is_nil(r.closed_at) and r.expires_at <= ^now,
        order_by: [asc: r.expires_at],
        limit: 100,
        select: r.id
    )
  end

  def expire_abandoned_room(id, now) do
    Repo.transaction(fn ->
      room = lock_room!(id)

      if is_nil(room.closed_at) and due?(room, now) do
        room |> Ecto.Changeset.change(expired_at: now) |> update!() |> close_room!(now)
      end
    end)
  end

  # After application/coordinator failure, persisted connections have no live
  # transport. Recheck the registry under the room lock to avoid racing a join.
  def recover_orphaned_rooms(now) do
    ids =
      Repo.all(from r in Room, where: is_nil(r.closed_at) and is_nil(r.expires_at), select: r.id)

    Enum.each(ids, fn id ->
      Repo.transaction(fn ->
        room = lock_room!(id)

        if is_nil(room.closed_at) and is_nil(room.expires_at) and
             Registry.lookup(ReviewProject.Rooms.Registry, id) == [] do
          {:ok, _} = recover(id, now)
        end
      end)
    end)
  end

  defp insert!(changeset) do
    case Repo.insert(changeset) do
      {:ok, record} -> record
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp update!(changeset) do
    case Repo.update(changeset) do
      {:ok, record} -> record
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end
end
