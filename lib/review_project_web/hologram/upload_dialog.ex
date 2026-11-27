defmodule ReviewProjectWeb.Hologram.UploadDialog do
  @moduledoc "Presentation for temporary uploads; all actions belong to VideoPanel."
  use Hologram.Component

  prop :solo, :boolean
  prop :can_control, :boolean
  prop :busy, :boolean
  prop :staged_upload, :map
  prop :upload_message, :string
  prop :upload_progress, :integer
  prop :discard_confirmation, :boolean

  @impl Component
  def template do
    ~HOLO"""
    <dialog id="upload-video-dialog" class="room-dialog upload-dialog" aria-labelledby="upload-video-heading" aria-describedby="upload-introduction">
      <div class="room-dialog-heading">
        <span class="eyebrow">WATCH TOGETHER</span>
        <button id="close-upload" type="button" class="dialog-close" $click={:close_upload, target: "video-panel"} aria-label="Close upload video">Close</button>
      </div>
      <h2 id="upload-video-heading">Upload a video</h2>
      <p id="upload-introduction" class="upload-introduction">Bring a file into your shared screening. One temporary video per room.</p>
      <dl class="upload-details">
        <div><dt>File formats</dt><dd>MP4 H.264/AAC or WebM VP8, VP9 or AV1 with Opus (or no audio)</dd></div>
        <div><dt>Maximum size</dt><dd>1 GiB</dd></div>
      </dl>
      <p class="upload-replacement-note">YouTube can continue while uploading; replacing an upload stops and deletes it first.</p>
      <section id="upload-retention" class="upload-retention" aria-label="Temporary file retention">
        <h3>Temporary, by design</h3>
        <p>Files are removed after five continuous minutes empty or one hour without video playback or user interaction, even during conferencing.</p>
        <p>This does not end the call or delete chat. After a restart, upload the file again.</p>
      </section>
      <div class="upload-selection">
        {%if @solo}
          <p id="upload-room-required">Create or join a room to upload a video. Files are temporarily staged for that room, not saved in your personal workspace.</p>
          <div class="upload-actions"><button id="upload-create-room" type="button" class="primary-button" $click={:create_upload_room, target: "video-panel"}>Create a room</button></div>
        {%else}
          {%if (!@staged_upload || @staged_upload.status != "ready") && (@upload_message == "Uploading and validating…" || (@upload_message == "" && @upload_progress > 0))}
            <progress id="upload-progress" class="upload-progress" aria-label="Upload progress" max="100" value={@upload_progress}></progress>
          {/if}
          {%if @upload_message != ""}<p id="upload-status" class="upload-status" role="status">{@upload_message}</p>{/if}
          {%if @staged_upload}
            <div class="upload-file">
              <span class="upload-file-label">Selected file</span>
              <p id="upload-file-name" class="upload-file-name">{@staged_upload.name}</p>
              <span id="upload-file-state" class="upload-file-state">{%if @staged_upload.status == "ready"}Ready to watch{%else}Validating file{/if}</span>
            </div>
            <div class="upload-actions">
              <button id="use-upload" type="button" class="primary-button" $click={:use_upload, target: "video-panel"} disabled={!@can_control || @busy || @staged_upload.status != "ready"}>Use this video</button>
              <button id="discard-upload" type="button" class="secondary-button" $click={:discard_upload, target: "video-panel"} disabled={!@can_control || @busy}>Discard and replace</button>
            </div>
          {%else}
            <div class="upload-actions">
              <button id="choose-upload" type="button" class="primary-button" $click={:choose_upload, target: "video-panel"} disabled={!@can_control}>Choose file / retry</button>
              <button id="cancel-upload" type="button" class="secondary-button" $click={:cancel_upload, target: "video-panel"}>Cancel upload</button>
            </div>
          {/if}
          {%if @discard_confirmation}
            <div id="discard-upload-confirmation" class="upload-discard-confirmation" role="alert">
              <h3>Discard for everyone?</h3>
              <p>Discard this uploaded video? This permanently deletes the file for everyone in the room and cannot be undone. You must upload it again to restore it.</p>
              <div class="upload-actions">
                <button id="confirm-discard-upload" type="button" class="primary-button upload-destructive" $click={:confirm_discard_upload, target: "video-panel"} disabled={!@can_control || @busy}>Discard permanently</button>
                <button id="keep-upload" type="button" class="secondary-button" $click={:keep_upload, target: "video-panel"}>Keep video</button>
              </div>
            </div>
          {/if}
        {/if}
      </div>
    </dialog>
    """
  end
end
