defmodule ReviewProjectWeb.PageController do
  use ReviewProjectWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
