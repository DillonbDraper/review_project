defmodule ReviewProjectWeb.Hologram.UploadDialogTest do
  use ExUnit.Case, async: true

  alias Hologram.{Server, Template.Renderer}
  alias ReviewProjectWeb.Hologram.UploadDialog

  test "idle and error states have no empty progress block" do
    for props <- [
          %{},
          %{upload_message: "Upload failed"},
          %{upload_message: "Upload failed", upload_progress: 42}
        ] do
      doc = document(props)
      assert Enum.empty?(LazyHTML.query(doc, "progress"))
      assert Enum.count(LazyHTML.query(doc, "#choose-upload, #cancel-upload")) == 2

      assert Enum.count(
               LazyHTML.query(doc, "#upload-video-dialog[aria-labelledby='upload-video-heading']")
             ) == 1
    end
  end

  test "transfer progress is thin and labelled, but never shown for a ready file" do
    for props <- [%{upload_message: "Uploading and validating…"}, %{upload_progress: 42}] do
      assert Enum.count(
               LazyHTML.query(
                 document(props),
                 "#upload-progress.upload-progress[aria-label='Upload progress']"
               )
             ) == 1
    end

    doc =
      document(%{
        upload_progress: 100,
        staged_upload: %{name: String.duplicate("long", 80) <> ".mp4", status: "ready"}
      })

    assert Enum.empty?(LazyHTML.query(doc, "progress"))

    assert Enum.count(
             LazyHTML.query(
               doc,
               "#upload-file-name.upload-file-name, #use-upload:not([disabled])"
             )
           ) == 2

    assert LazyHTML.text(LazyHTML.query(doc, "#upload-file-state")) == "Ready to watch"
  end

  test "validation, permissions, and destructive confirmation retain their guards" do
    doc =
      document(%{
        staged_upload: %{name: "clip.webm", status: "validating"},
        can_control: false,
        discard_confirmation: true
      })

    assert Enum.count(
             LazyHTML.query(
               doc,
               "#use-upload[disabled], #discard-upload[disabled], #confirm-discard-upload[disabled]"
             )
           ) == 3

    assert Enum.count(
             LazyHTML.query(doc, "#discard-upload-confirmation[role='alert'] .upload-destructive")
           ) == 1

    assert LazyHTML.text(LazyHTML.query(doc, "#upload-file-state")) == "Validating file"
  end

  test "solo flow offers room creation without file controls and preserves policy" do
    doc = document(%{solo: true})
    assert Enum.count(LazyHTML.query(doc, "#upload-create-room, #close-upload")) == 2
    assert Enum.empty?(LazyHTML.query(doc, "#choose-upload, #cancel-upload, progress"))
    assert LazyHTML.text(LazyHTML.query(doc, ".upload-details")) =~ "1 GiB"
    assert LazyHTML.text(LazyHTML.query(doc, ".upload-details")) =~ "AV1"
    assert LazyHTML.text(LazyHTML.query(doc, "#upload-retention")) =~ "even during conferencing"

    assert LazyHTML.text(LazyHTML.query(doc, "#upload-retention")) =~
             "does not end the call or delete chat"
  end

  defp document(overrides) do
    props =
      Map.merge(
        %{
          solo: false,
          can_control: true,
          busy: false,
          staged_upload: nil,
          upload_message: "",
          upload_progress: 0,
          discard_confirmation: false
        },
        overrides
      )

    {html, _, _} =
      Renderer.render_dom(UploadDialog.template().(props), %Renderer.Env{}, %Server{})

    LazyHTML.from_fragment(html)
  end
end
