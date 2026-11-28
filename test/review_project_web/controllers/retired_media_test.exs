defmodule ReviewProjectWeb.RetiredMediaTest do
  use ReviewProjectWeb.ConnCase, async: true

  test "legacy media requests reject before any body parser or session requirement" do
    for method <- ["GET", "HEAD", "POST", "DELETE", "PUT"],
        type <- [
          "application/json",
          "multipart/form-data; boundary=missing",
          "application/octet-stream"
        ] do
      conn =
        Plug.Test.conn(method, "/room-media/room/file", "intentionally invalid unread body")
        |> Plug.Conn.put_req_header("content-type", type)
        |> ReviewProjectWeb.Endpoint.call([])

      assert conn.status == 410
      assert conn.halted
      assert conn.body_params == %Plug.Conn.Unfetched{aspect: :body_params}
    end
  end

  test "local media URLs never fall back to server delivery" do
    conn = get(build_conn(), "/__local_media/file/1/capability")
    assert conn.status == 410
  end
end
