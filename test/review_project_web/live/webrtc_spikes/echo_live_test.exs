defmodule ReviewProjectWeb.WebRTCSpikes.EchoLiveTest do
  use ReviewProjectWeb.ConnCase, async: true

  test "renders the WebRTC echo spike harness", %{conn: conn} do
    conn = get(conn, ~p"/spikes/webrtc-echo")
    html = html_response(conn, 200)

    assert html =~ "webrtc-spike-page"
    assert html =~ "Raw Membrane WebRTC echo spike"
    assert html =~ "Server ICE UDP ranges"
  end
end
