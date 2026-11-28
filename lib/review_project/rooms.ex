defmodule ReviewProject.Rooms do
  @moduledoc """
  Rooms, invitation access, live playback authority and durable chat.

  `current_scope` is supplied by verified authentication as `%Accounts.Scope{user: user}`;
  guests pass nil. Browser identity must be a server-generated
  random value in the signed browser session. Never build either from client roles
  or IDs. Transport adapters must revalidate account sessions and terminate on logout.

  Joining binds a seat to a transport PID. Subsequent requests must use that same
  PID; a replaced/left transport immediately loses membership. The optional PID
  arguments are for trusted transport adapters, not request parameters.
  """
  alias ReviewProject.Rooms.{Session, Store}

  def create_room(current_scope, attrs \\ %{}), do: Store.create_room(current_scope, attrs)
  def list_rooms(current_scope), do: Store.list_rooms(current_scope)
  def get_room(current_scope, room_id), do: Store.get_room(current_scope, room_id)

  @doc "Replaces the shared invitation. Existing joined guests retain their seats."
  def rotate_invitation(current_scope, room_id),
    do: Store.rotate_invitation(current_scope, room_id, DateTime.utc_now())

  @doc "Closes admission and live transports while preserving durable chat."
  def close_room(current_scope, room_id) do
    with {:ok, room} <- Store.close_room(current_scope, room_id, DateTime.utc_now()) do
      case Registry.lookup(ReviewProject.Rooms.Registry, room.id) do
        [{pid, _}] -> GenServer.cast(pid, :closed)
        [] -> :ok
      end

      {:ok, room}
    end
  end

  @doc false
  def expire_abandoned_rooms(now \\ DateTime.utc_now()) do
    Store.recover_orphaned_rooms(now)

    for id <- Store.expired_room_ids(now),
        {:ok, %ReviewProject.Rooms.Room{}} <- [Store.expire_abandoned_room(id, now)] do
      case Registry.lookup(ReviewProject.Rooms.Registry, id) do
        [{pid, _}] -> GenServer.cast(pid, {:closed, :room_expired})
        [] -> :ok
      end

      id
    end
  end

  def join_room(
        current_scope,
        room_id,
        browser_identity,
        invitation,
        display_name,
        member \\ self()
      ) do
    with {:ok, session} <- ensure_session(room_id) do
      session_call(fn ->
        Session.join(session, current_scope, browser_identity, invitation, display_name, member)
      end)
    end
  end

  def request(current_scope, room_id, operation, member \\ self()) do
    case Registry.lookup(ReviewProject.Rooms.Registry, room_id) do
      [{pid, _}] -> session_call(fn -> Session.request(pid, current_scope, member, operation) end)
      [] -> {:error, :not_joined}
    end
  end

  def send_message(current_scope, room_id, attrs, member \\ self()),
    do: request(current_scope, room_id, {:chat, attrs}, member)

  @doc false
  def replay_request(current_scope, room_id, browser_identity, operation) do
    case Registry.lookup(ReviewProject.Rooms.Registry, room_id) do
      [{pid, _}] ->
        session_call(fn ->
          Session.replay_request(pid, current_scope, browser_identity, operation)
        end)

      [] ->
        {:error, :not_joined}
    end
  end

  @doc "History for an authenticated owner, including closed rooms. Guests use joined requests."
  def list_messages(current_scope, room_id) do
    with {:ok, room} <- get_room(current_scope, room_id), do: Store.history(room.id)
  end

  defp ensure_session(room_id) do
    with {:ok, room_id} <- Ecto.UUID.cast(room_id),
         {:ok, _room} <- Store.open_room(room_id) do
      case Registry.lookup(ReviewProject.Rooms.Registry, room_id) do
        [{pid, _}] ->
          {:ok, pid}

        [] ->
          case DynamicSupervisor.start_child(
                 ReviewProject.Rooms.SessionSupervisor,
                 {Session, room_id: room_id}
               ) do
            {:ok, pid} -> {:ok, pid}
            {:error, {:already_started, pid}} -> {:ok, pid}
            {:error, {:shutdown, reason}} -> {:error, reason}
            {:error, reason} -> {:error, reason}
          end
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  defp session_call(fun) do
    fun.()
  catch
    :exit, {reason, {GenServer, :call, _args}} when reason in [:noproc, :normal, :shutdown] ->
      {:error, :not_joined}
  end
end
