defmodule ReviewProject.OwnershipSpikes.RoomTest do
  use ExUnit.Case, async: true
  alias ReviewProject.Accounts.Scope
  alias ReviewProject.OwnershipSpikes.Room

  test "ownership comes from the server scope and invitations do not confer ownership" do
    owner = %Scope{user: %{id: 10}}
    guest = %Scope{user: %{id: 11}}
    assert {:ok, room} = Room.new(owner, 1000)
    assert room.owner_id == 10
    assert Room.owner?(owner, room)
    refute Room.owner?(guest, room)
    refute Room.owner?(nil, room)
    assert Room.invited?(room, room.invitation)
    refute Room.invited?(room, "forged")
    refute Room.invited?(room, nil)
    assert {:error, :authentication_required} = Room.new(nil, 1000)
    assert {:ok, second} = Room.new(owner, 1000)
    refute second.invitation == room.invitation
  end

  test "guest names are required, bounded, trimmed and reject control characters" do
    assert {:ok, "Guest A"} = Room.display_name(" Guest A ")
    assert {:ok, "Zoë"} = Room.display_name("Zoë")

    for value <- [nil, "", "   ", String.duplicate("x", 61), "A\nB", <<255>>] do
      assert {:error, :invalid_display_name} = Room.display_name(value)
    end
  end
end
