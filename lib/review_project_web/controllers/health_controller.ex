defmodule ReviewProjectWeb.HealthController do
  use ReviewProjectWeb, :controller

  def show(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(%{status: "ok"})
  end
end
