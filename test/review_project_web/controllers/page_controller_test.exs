defmodule ReviewProjectWeb.PageControllerTest do
  use ReviewProjectWeb.ConnCase

  alias Hologram.Assets.PathRegistry

  test "GET / serves the Hologram video workspace", %{conn: conn} do
    document = conn |> get("/") |> html_response(200) |> LazyHTML.from_document()

    for selector <- ["#workspace", "#video-source-form", "#chat-form"] do
      assert document |> LazyHTML.query(selector) |> Enum.count() == 1
    end

    assert document |> LazyHTML.query("#youtube-player") |> Enum.empty?()
    assert document |> LazyHTML.query("#whiteboard-panel, #drawing-surface") |> Enum.empty?()

    assert document
           |> LazyHTML.query(".workspace-grid > #conference-panel + #video-panel")
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

  test "test assets are isolated and every referenced Hologram bundle is served", %{conn: conn} do
    assert {:error, :einval} = File.read_link(Application.app_dir(:review_project, "priv"))

    scripts =
      conn
      |> get("/")
      |> html_response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query("script[src^='/hologram/']")
      |> LazyHTML.attribute("src")

    assert length(scripts) >= 3

    for path <- scripts do
      asset = get(build_conn(), path)
      assert asset.status == 200, "missing Hologram bundle: #{path}"
      assert get_resp_header(asset, "content-type") == ["text/javascript"]
    end
  end
end
