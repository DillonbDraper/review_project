defmodule ReviewProjectWeb.YouTubeSyncChannelTest do
  use ExUnit.Case, async: true
  import Phoenix.ChannelTest
  alias ReviewProject.SyncSpikes.Rooms
  alias ReviewProjectWeb.{YouTubeSyncChannel, YouTubeSyncSocket}
  @endpoint ReviewProjectWeb.Endpoint

  setup do
    rooms = start_supervised!({Rooms, name: nil})
    {:ok, credentials} = Rooms.create(rooms)
    %{rooms: rooms, credentials: credentials}
  end

  test "broadcasts host commands, rejects guest writes, and returns fresh snapshots", ctx do
    topic = "youtube_sync:#{ctx.credentials.room_id}"
    base = socket(YouTubeSyncSocket, nil, %{rooms: ctx.rooms})

    assert {:ok, %{role: "host"}, host} =
             subscribe_and_join(base, YouTubeSyncChannel, topic, %{
               host_token: ctx.credentials.host_token
             })

    assert {:ok, %{role: "guest"}, guest} =
             subscribe_and_join(base, YouTubeSyncChannel, topic, %{})

    ref = push(guest, "control", %{"op" => "play", "revision" => 0})
    assert_reply ref, :error, %{reason: :forbidden}
    ref = push(host, "control", %{"op" => "seek", "position" => 25, "revision" => 0})
    assert_reply ref, :ok, %{position: 25.0, revision: 1}
    assert_push "playback", %{position: 25.0, revision: 1}
    ref = push(guest, "snapshot", %{})
    assert_reply ref, :ok, %{position: 25.0, revision: 1}
    ref = push(host, "control", %{"op" => "play", "revision" => 0})
    assert_reply ref, :error, %{reason: :stale_revision}
  end

  test "a forged host credential cannot join", ctx do
    base = socket(YouTubeSyncSocket, nil, %{rooms: ctx.rooms})

    assert {:error, %{reason: :invalid_host_token}} =
             subscribe_and_join(
               base,
               YouTubeSyncChannel,
               "youtube_sync:#{ctx.credentials.room_id}",
               %{host_token: "forged"}
             )
  end

  test "joined members can refresh their network configuration", ctx do
    base = socket(YouTubeSyncSocket, nil, %{rooms: ctx.rooms})

    {:ok, %{mesh: %{ice: %{mode: "direct", servers: []}}}, channel} =
      subscribe_and_join(base, YouTubeSyncChannel, "youtube_sync:#{ctx.credentials.room_id}", %{})

    ref = push(channel, "mesh_ice", %{})
    assert_reply ref, :ok, %{mode: "direct", servers: [], policy: "all"}
  end

  test "mesh presence, targeted signaling and chat travel over the channel", ctx do
    base = socket(YouTubeSyncSocket, nil, %{rooms: ctx.rooms})
    topic = "youtube_sync:#{ctx.credentials.room_id}"

    {:ok, %{mesh: %{self_id: host_id}}, host} =
      subscribe_and_join(base, YouTubeSyncChannel, topic, %{
        host_token: ctx.credentials.host_token
      })

    {:ok, %{mesh: %{self_id: guest_id}}, guest} =
      subscribe_and_join(base, YouTubeSyncChannel, topic, %{})

    for channel <- [host, guest] do
      ref = push(channel, "mesh_media", %{"enabled" => true})
      assert_reply ref, :ok, %{peers: _}
    end

    data = %{"type" => "description", "description" => %{"type" => "offer", "sdp" => "research"}}
    ref = push(host, "mesh_signal", %{"to" => guest_id, "from" => "forged", "data" => data})
    assert_reply ref, :ok, %{}
    assert_push "mesh_signal", %{from: ^host_id, data: ^data}
    ref = push(guest, "mesh_chat", %{"body" => "hello"})
    assert_reply ref, :ok, %{author: ^guest_id, body: "hello", id: 1}
    assert_push "mesh_chat", %{author: ^guest_id, body: "hello", id: 1}
  end
end
