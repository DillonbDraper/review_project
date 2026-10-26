defmodule ReviewProject.OwnershipSpikes.Room do
  @moduledoc "Private room ownership and public playback data for spike 5."
  alias ReviewProject.Accounts.Scope
  alias ReviewProject.SyncSpikes.Timeline

  def new(%Scope{user: %{id: owner_id}}, now) do
    {:ok,
     %{
       id: Ecto.UUID.generate(),
       owner_id: owner_id,
       invitation: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
       timeline: Timeline.new(now),
       seats: %{},
       controller: nil,
       authority_revision: 0,
       join_sequence: 0,
       absent_since: now,
       empty_at: now,
       chat: [],
       chat_seq: 0
     }}
  end

  def new(_scope, _now), do: {:error, :authentication_required}

  def owner?(%Scope{user: %{id: id}}, room), do: id == room.owner_id
  def owner?(_scope, _room), do: false

  def invited?(room, token) when is_binary(token),
    do: Plug.Crypto.secure_compare(room.invitation, token)

  def invited?(_room, _token), do: false

  def display_name(name) when is_binary(name) do
    name = String.trim(name)

    if String.valid?(name) and byte_size(name) in 1..240 and String.length(name) <= 60 and
         not Regex.match?(~r/[\x00-\x1F\x7F]/u, name),
       do: {:ok, name},
       else: {:error, :invalid_display_name}
  end

  def display_name(_name), do: {:error, :invalid_display_name}
end
