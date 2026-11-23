defmodule ReviewProjectWeb.TidewaveTest do
  use ReviewProjectWeb.ConnCase

  test "Tidewave is not an application dependency outside development" do
    refute :tidewave in Application.spec(:review_project, :applications)
  end

  test "the MCP endpoint is unavailable outside development", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/tidewave/mcp", ~s({"jsonrpc":"2.0","id":1,"method":"tools/list"}))

    assert conn.status == 404
  end
end
