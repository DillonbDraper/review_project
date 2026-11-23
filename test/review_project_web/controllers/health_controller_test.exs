defmodule ReviewProjectWeb.HealthControllerTest do
  use ReviewProjectWeb.ConnCase, async: true

  test "public liveness does not establish a browser session", %{conn: conn} do
    conn = get(conn, ~p"/healthz")
    assert json_response(conn, 200) == %{"status" => "ok"}
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "set-cookie") == []
    refute Map.has_key?(conn.assigns, :current_scope)
  end
end
