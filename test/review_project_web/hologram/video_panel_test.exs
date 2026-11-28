defmodule ReviewProjectWeb.Hologram.VideoPanelTest do
  use ExUnit.Case, async: true
  alias Hologram.{Component, Server}
  alias Hologram.Template.Renderer
  alias ReviewProjectWeb.Hologram.{PlaybackState, VideoPanel}

  test "share callbacks use the native scope generation and selection request" do
    opened = VideoPanel.action(:open_share, %{}, room_video())
    chosen = VideoPanel.action(:choose_share, %{}, opened)

    params = %{
      event: "chosen",
      generation: chosen.state.sharing.generation,
      request: chosen.state.sharing.selection_serial,
      handle: "file:new",
      name: "clip.mp4",
      size: 100
    }

    assert VideoPanel.action(:share_native, %{params | generation: -1}, chosen) == chosen
    inspecting = VideoPanel.action(:share_native, params, chosen)
    assert inspecting.state.sharing.selection.phase == :inspecting

    failed =
      VideoPanel.action(
        :share_native,
        %{
          event: "inspected",
          generation: params.generation,
          request: params.request,
          status: "error",
          reason: "inspection_timeout"
        },
        inspecting
      )

    assert failed.state.share_open
    assert failed.state.sharing.selection == nil
    assert failed.state.playback == opened.state.playback
    assert Enum.count(LazyHTML.query(document(failed), "#choose-share")) == 1
  end

  test "workspace share entry explains room staging before and after YouTube selection" do
    workspace = VideoPanel.init(%{}, %Component{}, %Server{})

    for component <- [workspace, select(workspace, "M7lc1UVf-VE")] do
      doc = document(component)

      assert Enum.count(
               LazyHTML.query(
                 doc,
                 "#share-video:not([disabled])[aria-controls='share-video-dialog']"
               )
             ) == 1

      assert LazyHTML.text(LazyHTML.query(doc, "#share-room-required")) =~
               "Create or join a room"

      assert Enum.count(LazyHTML.query(doc, "#share-create-room")) == 1
      assert Enum.empty?(LazyHTML.query(doc, "#choose-share, #cancel-share, #use-share"))
      opened = VideoPanel.action(:open_share, %{}, component)
      assert opened.state.share_generation == 0
      assert opened.next_command == component.next_command
      assert opened.state.playback == component.state.playback
      create = VideoPanel.action(:create_share_room, %{}, opened)
      assert create.next_action.name == :open_create
      assert create.next_action.target == "room-controls"
    end
  end

  test "only a connected room controller can open the actual share flow" do
    controller = room_video()

    assert Enum.count(
             LazyHTML.query(document(controller), "#share-video:not([disabled]), #choose-share")
           ) == 2

    assert Enum.empty?(
             LazyHTML.query(document(controller), "#share-room-required, #share-create-room")
           )

    opened = VideoPanel.action(:open_share, %{}, controller)
    assert opened.state.share_open
    assert VideoPanel.action(:create_share_room, %{}, controller) == controller

    unjoined = VideoPanel.init(%{room_id: "room"}, %Component{}, %Server{})

    for component <- [unjoined, room_video("guest")] do
      assert Enum.count(LazyHTML.query(document(component), "#share-video[disabled]")) == 1

      assert Enum.count(LazyHTML.query(document(component), "#share-availability:not([hidden])")) ==
               1

      assert VideoPanel.action(:open_share, %{}, component) == component
      assert VideoPanel.action(:create_share_room, %{}, component) == component
    end

    assert LazyHTML.text(LazyHTML.query(document(unjoined), "#share-availability")) =~
             "Join or reconnect"

    assert LazyHTML.text(LazyHTML.query(document(room_video("guest")), "#share-availability")) =~
             "playback controller"
  end

  test "popover positioning waits for native opening and preserves playback state" do
    component = VideoPanel.init(%{}, %Component{}, %Server{})
    positioned = VideoPanel.action(:playback_info_clicked, %{}, component)
    assert positioned.state == component.state
    assert positioned.next_action.name == :position_playback_info
    assert positioned.next_action.delay > 0
  end

  defp select(component, source) do
    component = VideoPanel.action(:load_video, %{event: %{"source" => source}}, component)
    command = component.next_command
    server = VideoPanel.command(command.name, command.params, %Server{})
    action = server.next_action
    VideoPanel.action(action.name, action.params, component)
  end

  defp room_video(self_id \\ "host") do
    component = VideoPanel.init(%{room_id: "room"}, %Component{}, %Server{})

    VideoPanel.action(
      :room_event,
      %{
        kind: :joined,
        room_generation: 1,
        self_id: self_id,
        connection_generation: 1,
        snapshot: %{
          room_id: "room",
          epoch: "epoch",
          revision: 1,
          authority_revision: 1,
          controller_id: "host",
          video_id: "M7lc1UVf-VE",
          position: 0,
          playing: false,
          server_time_ms: 1000,
          seats: [%{id: "host", display_name: "Host", connected: true, connection_generation: 1}],
          roster_revision: 1
        }
      },
      component
    )
  end

  test "initial selection lives in the header without a numbered heading or source footer" do
    component = VideoPanel.init(%{}, %Component{}, %Server{})
    document = document(component)

    assert Enum.count(LazyHTML.query(document, ".video-header #video-source-form")) == 1

    assert Enum.count(
             LazyHTML.query(
               document,
               "#video-source ~ #load-video"
             )
           ) == 1

    assert Enum.empty?(
             LazyHTML.query(
               document,
               "#video-heading, .video-source-area, #video-source-help, #open-switch-video"
             )
           )
  end

  test "source edits survive player and room updates before submission" do
    for component <- [VideoPanel.init(%{}, %Component{}, %Server{}), room_video()] do
      source = "https://youtu.be/dQw4w9WgXcQ"
      edited = VideoPanel.action(:update_source, %{event: %{value: source}}, component)
      sample = Map.put(edited.state.playback.sample, :generation, edited.state.player_generation)
      {state, _effects} = PlaybackState.event(edited.state.playback, :sample, sample)
      updated = Component.put_state(edited, Map.put(PlaybackState.view(state), :playback, state))
      assert updated.state.source == source

      submitted =
        VideoPanel.action(:load_video, %{event: %{"source" => source}}, updated)

      assert submitted.next_command.name == :resolve_video
      assert submitted.next_command.params.source == source
    end
  end

  test "solo selection retains a stable native-owned host and accessible controls" do
    component =
      VideoPanel.init(%{}, %Component{}, %Server{}) |> select("https://youtu.be/M7lc1UVf-VE")

    document = document(component)
    assert component.state.video_id == "M7lc1UVf-VE"
    assert Enum.count(LazyHTML.query(document, "#video-player-host")) == 1
    assert Enum.empty?(LazyHTML.query(document, "#video-empty"))

    assert LazyHTML.attribute(
             LazyHTML.query(document, "#current-video-source[readonly]"),
             "value"
           ) == [
             "https://www.youtube.com/watch?v=M7lc1UVf-VE"
           ]

    assert Enum.empty?(LazyHTML.query(document, ".video-header a"))

    assert Enum.count(LazyHTML.query(document, "#video-play-pause")) == 1
    assert Enum.count(LazyHTML.query(document, "#video-seek[aria-valuetext]")) == 1
    assert Enum.count(LazyHTML.query(document, ".video-header #open-switch-video")) == 1

    assert Enum.count(
             LazyHTML.query(
               document,
               "#current-video-source + #open-switch-video + #share-video"
             )
           ) == 1

    assert Enum.empty?(LazyHTML.query(document, "#video-source-form"))
    refute component.state.loading?
  end

  test "switching can be canceled and only closes after a valid replacement" do
    selected = VideoPanel.init(%{}, %Component{}, %Server{}) |> select("M7lc1UVf-VE")
    opened = VideoPanel.action(:open_switch, %{}, selected)
    assert opened.state.switch_open
    assert opened.state.source == ""

    canceled = VideoPanel.action(:close_switch, %{}, opened)
    refute canceled.state.switch_open
    assert canceled.state.video_id == selected.state.video_id

    invalid = opened |> select("https://evil.example")
    assert invalid.state.switch_open
    assert invalid.state.video_id == selected.state.video_id

    assert Enum.count(
             LazyHTML.query(document(invalid), "#switch-video-source[aria-invalid='true']")
           ) == 1

    replaced = invalid |> select("dQw4w9WgXcQ")
    refute replaced.state.switch_open
    assert replaced.state.video_id == "dQw4w9WgXcQ"
    assert replaced.state.playback_error == ""

    reopened = VideoPanel.action(:open_switch, %{}, replaced)
    same_video = reopened |> select("dQw4w9WgXcQ")
    refute same_video.state.switch_open
  end

  test "invalid replacements preserve selection and live/playlist-only input is explained" do
    component = VideoPanel.init(%{}, %Component{}, %Server{}) |> select("M7lc1UVf-VE")

    for source <- [
          "https://evil.example",
          "https://youtube.com/live/M7lc1UVf-VE",
          "https://youtube.com/playlist?list=123"
        ] do
      invalid = select(component, source)
      assert invalid.state.video_id == component.state.video_id
      document = document(invalid)
      assert Enum.count(LazyHTML.query(document, "#video-player-host")) == 1

      assert Enum.count(LazyHTML.query(document, "#switch-video-source[aria-invalid='true']")) ==
               1

      assert LazyHTML.text(LazyHTML.query(document, "#switch-video-error")) != ""
    end
  end

  test "room playback is unavailable before admission and forged selection events do not resolve" do
    component = VideoPanel.init(%{room_id: "room"}, %Component{}, %Server{})
    assert Enum.count(LazyHTML.query(document(component), "#load-video[disabled]")) == 1
    assert Enum.count(LazyHTML.query(document(component), "#video-play-pause[disabled]")) == 1
    attempted = VideoPanel.action(:load_video, %{event: %{"source" => "M7lc1UVf-VE"}}, component)
    assert attempted.next_command == nil
    assert attempted.state.video_id == nil
    refute VideoPanel.action(:open_switch, %{}, component).state.switch_open
  end

  test "losing playback control closes the switch modal and prevents reopening it" do
    component =
      room_video()
      |> then(&VideoPanel.action(:open_switch, %{}, &1))

    stopped =
      VideoPanel.action(
        :room_event,
        %{kind: :stopped, room_generation: 1, generation: 1, mode: "stop"},
        component
      )

    refute stopped.state.switch_open
    refute stopped.state.can_control
    refute VideoPanel.action(:open_switch, %{}, stopped).state.switch_open
  end

  test "room replacement keeps the modal open until the room accepts the selection" do
    opened = room_video() |> then(&VideoPanel.action(:open_switch, %{}, &1))
    pending = opened |> select("dQw4w9WgXcQ")
    assert pending.state.switch_open
    assert pending.state.busy
    assert pending.state.video_id == "M7lc1UVf-VE"

    snapshot = %{pending.state.playback.desired | revision: 2, video_id: "dQw4w9WgXcQ"}

    accepted =
      VideoPanel.action(
        :control_result,
        %{
          generation: pending.state.playback.generation,
          request: pending.state.playback.pending.id,
          status: "ok",
          result: snapshot
        },
        pending
      )

    refute accepted.state.switch_open
    assert accepted.state.video_id == "dQw4w9WgXcQ"
  end

  test "followers can view the selected link but cannot open the switch modal" do
    follower = room_video("guest")
    assert Enum.count(LazyHTML.query(document(follower), "#open-switch-video[disabled]")) == 1
    refute VideoPanel.action(:open_switch, %{}, follower).state.switch_open
  end

  test "stale source resolution cannot replace a newer player generation" do
    component = VideoPanel.init(%{}, %Component{}, %Server{})
    component = VideoPanel.action(:load_video, %{event: %{"source" => "M7lc1UVf-VE"}}, component)

    stale =
      VideoPanel.action(
        :source_resolved,
        %{request: 1, generation: -1, video_id: "M7lc1UVf-VE"},
        component
      )

    assert stale.state.video_id == nil
  end

  defp document(component) do
    {html, _, _} =
      Renderer.render_dom(VideoPanel.template().(component.state), %Renderer.Env{}, %Server{})

    LazyHTML.from_fragment(html)
  end
end
