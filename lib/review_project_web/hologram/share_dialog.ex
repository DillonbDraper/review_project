defmodule ReviewProjectWeb.Hologram.ShareDialog do
  @moduledoc "Direct file selection; native handles stay in the browser."
  use Hologram.Component

  prop :solo, :boolean
  prop :can_control, :boolean
  prop :share_message, :string

  @impl Component
  def template do
    ~HOLO"""
    <dialog id="share-video-dialog" class="room-dialog upload-dialog" aria-labelledby="share-video-heading" aria-describedby="share-introduction">
      <div class="room-dialog-heading">
        <span class="eyebrow">WATCH TOGETHER</span>
        <button id="close-share" type="button" class="dialog-close" $click={:close_share, target: "video-panel"} aria-label="Close share video">Close</button>
      </div>
      <h2 id="share-video-heading">Share a video</h2>
      <p id="share-introduction" class="upload-introduction">Review a file directly from your device, at its original quality. Keep this tab open while sharing.</p>
      <dl class="upload-details">
        <div><dt>File formats</dt><dd>MP4 H.264/AAC-LC or WebM VP8, VP9 or AV1 Main with Opus (or no audio), 8-bit</dd></div>
        <div><dt>Maximum size</dt><dd>1 GiB · One selected file per room</dd></div>
      </dl>
      <p class="upload-replacement-note">Your device sends a copy of the original stream to each guest. More guests need more upstream bandwidth; this is not a quality setting.</p>
      <section id="share-retention" class="upload-retention" aria-label="Share session lifetime">
        <h3>Your file stays on your device</h3>
        <p>Sharing ends after five continuous minutes empty or one hour without playback or user interaction. Your original file is never deleted.</p>
        <p>If the source leaves, shared playback pauses. After it reconnects, the controller presses Play. Reloading or closing the source tab requires selecting the file again, starting at zero.</p>
      </section>
      <div class="upload-selection">
        {%if @solo}
          <p id="share-room-required">Create or join a room to share a video with other people.</p>
          <div class="upload-actions"><button id="share-create-room" type="button" class="primary-button" $click={:create_share_room, target: "video-panel"}>Create a room</button></div>
        {%else}
          <p id="share-status" class="upload-status" role="status">{@share_message}</p>
          <div class="upload-actions">
            <button id="choose-share" type="button" class="primary-button" $click={:choose_share, target: "video-panel"} disabled={!@can_control}>Choose file / retry</button>
            <button id="cancel-share" type="button" class="secondary-button" $click={:cancel_share, target: "video-panel"}>Cancel preparation</button>
          </div>
        {/if}
      </div>
    </dialog>
    """
  end
end
