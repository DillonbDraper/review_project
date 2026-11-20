defmodule ReviewProjectWeb.PageControllerTest do
  use ReviewProjectWeb.ConnCase

  alias Hologram.Assets.PathRegistry

  test "GET / serves the Hologram video workspace", %{conn: conn} do
    document = conn |> get("/") |> html_response(200) |> LazyHTML.from_document()

    for selector <- ["#workspace", "#video-source-form", "#chat-form", "#drawing-surface"] do
      assert document |> LazyHTML.query(selector) |> Enum.count() == 1
    end

    assert document |> LazyHTML.query("#youtube-player") |> Enum.empty?()
    assert document |> LazyHTML.query("#drawing-surface iframe") |> Enum.empty?()

    assert document
           |> LazyHTML.query(".review-column #conference-panel + #video-panel")
           |> Enum.count() == 1

    assert document |> LazyHTML.query(".workspace-grid > #chat-panel") |> Enum.count() == 1
    assert document |> LazyHTML.query("script[src^='/hologram/runtime-']") |> Enum.count() == 1
    assert document |> LazyHTML.query("script[src^='/hologram/page-']") |> Enum.count() == 1

    assert document |> LazyHTML.query("link[rel='stylesheet']") |> LazyHTML.attribute("href") ==
             ["/assets/css/app.css"]
  end

  test "GET / ignores stale CSS fingerprints in Hologram's asset registry", %{conn: conn} do
    key = "assets/css/app.css"
    {:ok, original_path} = PathRegistry.lookup(key)

    on_exit(fn -> PathRegistry.register(key, original_path) end)
    PathRegistry.register(key, "/assets/css/app-00000000000000000000000000000000.css")

    document = conn |> get("/") |> html_response(200) |> LazyHTML.from_document()

    assert document |> LazyHTML.query("link[rel='stylesheet']") |> LazyHTML.attribute("href") ==
             ["/assets/css/app.css"]
  end
end
