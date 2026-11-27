defmodule ReviewProjectWeb.Hologram.VideoPanelTest do
  use ExUnit.Case, async: true
  alias Hologram.{Component, Server}
  alias Hologram.Template.Renderer
  alias ReviewProjectWeb.Hologram.{PlaybackState, VideoPanel}

  test "a completed upload selects automatically and closes only after room acceptance" do
    opened = VideoPanel.action(:open_upload, %{}, room_video())
    assert opened.state.upload_open

    params = %{
      generation: opened.state.upload_generation,
      room_id: "room",
      completed: true,
      staged: %{id: "asset", name: "Clip", status: "ready"}
    }

    for stale <- [%{params | room_id: "old"}, %{params | generation: -1}] do
      ignored = VideoPanel.action(:upload_status, stale, opened)
      assert ignored.state.playback.pending == nil
      assert ignored.state.upload_open
    end

    staged = VideoPanel.action(:upload_status, Map.delete(params, :completed), opened)
    assert staged.state.playback.pending == nil
    assert staged.state.upload_open

    pending = VideoPanel.action(:upload_status, params, opened)
    assert pending.state.playback.pending.command.source == %{kind: "upload", id: "asset"}
    assert pending.state.upload_open
    assert pending.state.video_id == opened.state.video_id

    snapshot =
      Map.merge(pending.state.playback.desired, %{
        revision: 2,
        video_id: "upload:asset",
        video_source: %{kind: "upload", id: "asset", name: "Clip", duration: 60.0}
      })

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

    refute accepted.state.upload_open
    assert accepted.state.video_id == "upload:asset"

    reopened = VideoPanel.action(:open_upload, %{}, accepted)
    refreshed = VideoPanel.action(:upload_status, Map.delete(params, :completed), reopened)
    assert refreshed.state.upload_open
    assert refreshed.state.playback.pending == nil

    rejected =
      VideoPanel.action(
        :control_result,
        %{
          generation: pending.state.playback.generation,
          request: pending.state.playback.pending.id,
          status: "error",
          result: %{reason: "stale_revision"}
        },
        pending
      )

    assert rejected.state.upload_open
    assert rejected.state.staged_upload.id == "asset"
    assert rejected.state.upload_message != ""
    assert rejected.state.video_id == opened.state.video_id
  end

  test "upload callbacks require room and generation correlation and discard requires confirmation" do
    component = VideoPanel.action(:open_upload, %{}, room_video())

    params = %{
      generation: component.state.upload_generation,
      room_id: "room",
      staged: %{id: "asset", name: "Clip", status: "ready"}
    }

    assert VideoPanel.action(:upload_status, %{params | room_id: "old"}, component).state.staged_upload ==
             nil

    assert VideoPanel.action(:upload_status, %{params | generation: -1}, component).state.staged_upload ==
             nil

    transferring =
      VideoPanel.action(
        :upload_status,
        Map.merge(params, %{staged: nil, progress: 42}),
        component
      )

    assert Enum.count(LazyHTML.query(document(transferring), "#upload-progress[value='42']")) == 1

    ready = VideoPanel.action(:upload_status, params, transferring)
    assert ready.state.staged_upload.id == "asset"
    assert Enum.empty?(LazyHTML.query(document(ready), "#upload-progress"))
    assert Enum.count(LazyHTML.query(document(ready), ".upload-dialog #upload-file-name")) == 1

    assert Enum.count(
             LazyHTML.query(document(ready), "#use-upload:not([disabled]), #discard-upload")
           ) == 2

    assert document(ready) |> LazyHTML.query("#upload-retention") |> LazyHTML.text() =~
             "even during conferencing"

    validating =
      Component.put_state(ready, :staged_upload, %{params.staged | status: "validating"})

    assert Enum.count(LazyHTML.query(document(validating), "#use-upload[disabled]")) == 1
    opened = VideoPanel.action(:discard_upload, %{}, ready)
    assert opened.state.playback.pending == nil

    assert Enum.count(
             LazyHTML.query(
               document(opened),
               "#discard-upload-confirmation #confirm-discard-upload"
             )
           ) == 1

    kept = VideoPanel.action(:keep_upload, %{}, opened)
    refute kept.state.discard_confirmation
    assert kept.state.staged_upload == ready.state.staged_upload
    discarded = VideoPanel.action(:confirm_discard_upload, %{}, opened)
    assert discarded.state.playback.pending.command.op == "discard_upload"
  end

  test "workspace upload entry explains room staging before and after YouTube selection" do
    workspace = VideoPanel.init(%{}, %Component{}, %Server{})

    for component <- [workspace, select(workspace, "M7lc1UVf-VE")] do
      doc = document(component)

      assert Enum.count(
               LazyHTML.query(
                 doc,
                 "#upload-video:not([disabled])[aria-controls='upload-video-dialog']"
               )
             ) == 1

      assert LazyHTML.text(LazyHTML.query(doc, "#upload-room-required")) =~
               "Create or join a room"

      assert Enum.count(LazyHTML.query(doc, "#upload-create-room")) == 1
      assert Enum.empty?(LazyHTML.query(doc, "#choose-upload, #cancel-upload, #use-upload"))
      opened = VideoPanel.action(:open_upload, %{}, component)
      assert opened.state.upload_generation == 0
      assert opened.next_command == component.next_command
      assert opened.state.playback == component.state.playback
      create = VideoPanel.action(:create_upload_room, %{}, opened)
      assert create.next_action.name == :open_create
      assert create.next_action.target == "room-controls"
    end
  end

  test "only a connected room controller can open the actual upload flow" do
    controller = room_video()

    assert Enum.count(
             LazyHTML.query(document(controller), "#upload-video:not([disabled]), #choose-upload")
           ) == 2

    assert Enum.empty?(
             LazyHTML.query(document(controller), "#upload-room-required, #upload-create-room")
           )

    opened =
      VideoPanel.action(
        :open_upload,
        %{},
        Component.put_state(controller, :discard_confirmation, true)
      )

    refute opened.state.discard_confirmation
    assert VideoPanel.action(:create_upload_room, %{}, controller) == controller

    unjoined = VideoPanel.init(%{room_id: "room"}, %Component{}, %Server{})

    for component <- [unjoined, room_video("guest")] do
      assert Enum.count(LazyHTML.query(document(component), "#upload-video[disabled]")) == 1

      assert Enum.count(LazyHTML.query(document(component), "#upload-availability:not([hidden])")) ==
               1

      assert VideoPanel.action(:open_upload, %{}, component) == component
      assert VideoPanel.action(:create_upload_room, %{}, component) == component
    end

    assert LazyHTML.text(LazyHTML.query(document(unjoined), "#upload-availability")) =~
             "Join or reconnect"

    assert LazyHTML.text(LazyHTML.query(document(room_video("guest")), "#upload-availability")) =~
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
        snapshot: %{
          epoch: "epoch",
          revision: 1,
          authority_revision: 1,
          controller_id: "host",
          video_id: "M7lc1UVf-VE",
          position: 0,
          playing: false,
          server_time_ms: 1000,
          seats: [%{id: "host", display_name: "Host"}],
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
               "#current-video-source + #open-switch-video + #upload-video"
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
