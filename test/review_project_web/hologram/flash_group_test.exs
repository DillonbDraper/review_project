defmodule ReviewProjectWeb.Hologram.FlashGroupTest do
  use ReviewProjectWeb.ConnCase, async: true

  import ReviewProject.AccountsFixtures

  alias Hologram.{Component, Server}
  alias Hologram.Template.Renderer
  alias ReviewProjectWeb.Hologram.FlashGroup

  test "shows the session's info and error messages once" do
    flash = %{"info" => "Welcome back!", "error" => "Something failed", "email" => "a@b.c"}
    server = %Server{session: %{"phoenix_flash" => flash}}

    {component, server} = FlashGroup.init(%{}, %Component{}, server)
    document = document(component)

    assert document |> LazyHTML.query("#flash-info[role=status]") |> LazyHTML.text() =~
             "Welcome back!"

    assert document |> LazyHTML.query("#flash-error[role=alert]") |> LazyHTML.text() =~
             "Something failed"

    assert document |> LazyHTML.query(".workspace-flash") |> Enum.count() == 2
    assert Server.get_session_ops(server) == %{"phoenix_flash" => :delete}
  end

  test "dismissing a message removes it" do
    server = %Server{session: %{"phoenix_flash" => %{"info" => "Logged out successfully."}}}
    {component, _server} = FlashGroup.init(%{}, %Component{}, server)

    component = FlashGroup.action(:dismiss, %{kind: "info"}, component)

    assert document(component) |> LazyHTML.query(".workspace-flash") |> Enum.empty?()
  end

  test "the watch page shows the log in message instead of a later Phoenix page", %{conn: conn} do
    user = user_fixture() |> set_password()

    conn =
      post(conn, ~p"/users/log-in", %{
        "user" => %{"email" => user.email, "password" => valid_user_password()}
      })

    assert redirected_to(conn) == "/"

    conn = get(conn, "/")
    document = conn |> html_response(200) |> LazyHTML.from_document()
    assert document |> LazyHTML.query("#flash-info") |> LazyHTML.text() =~ "Welcome back!"

    conn = get(conn, ~p"/users/settings")
    refute html_response(conn, 200) =~ "Welcome back!"
  end

  defp document(component) do
    {html, _registry, _server} =
      Renderer.render_dom(FlashGroup.template().(component.state), %Renderer.Env{}, %Server{})

    LazyHTML.from_fragment(html)
  end
end
