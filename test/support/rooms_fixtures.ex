defmodule ReviewProject.RoomsFixtures do
  @moduledoc false
  alias ReviewProject.{AccountsFixtures, Rooms}

  def owner_scope, do: AccountsFixtures.user_scope_fixture()

  def room_fixture(scope \\ owner_scope()) do
    {:ok, result} = Rooms.create_room(scope, %{name: "Watch party"})
    Map.put(result, :scope, scope)
  end

  def browser_identity, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
