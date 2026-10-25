defmodule ReviewProject.UUIDCompatibilityTest do
  use ExUnit.Case, async: true

  alias Hologram.Runtime.Session

  test "Hologram sessions use the same UUID provider as the Membrane stack" do
    conn =
      :get
      |> Plug.Test.conn("/")
      |> Plug.Test.init_test_session(%{})
      |> Session.init()

    session_id = Session.get_session_id(conn)

    assert {:ok, info} = UUID.info(session_id)
    assert info[:version] == 4
    assert :application.get_application(UUID) == {:ok, :elixir_uuid}
    assert Application.spec(:uuid, :modules) == []
    assert :elixir_uuid in Application.spec(:uuid, :applications)
    assert Session.get_session_id(Session.init(conn)) == session_id
  end
end
