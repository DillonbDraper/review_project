defmodule ReviewProjectWeb.Hologram.VideoPanel do
  @moduledoc "Owns video selection; keeps the embed independent of chat and future drawing state."
  use Hologram.Component

  alias ReviewProject.VideoSource

  @impl Component
  def init(_props, component, _server) do
    put_state(component, source: "", video_id: nil, embed_url: nil, error: nil, loading?: false)
  end

  @impl Component
  def template do
    ~HOLO"""
    <section id="video-panel" class="workspace-card" aria-labelledby="video-heading">
      <div class="panel-heading">
        <div class="flex items-center gap-3">
          <span class="section-number">01</span>
          <h2 id="video-heading">The video</h2>
        </div>
        {%if @video_id}
          <a id="open-youtube" class="youtube-link" href="https://www.youtube.com/watch?v={@video_id}" target="_blank" rel="noopener noreferrer">Open on YouTube</a>
        {%else}
          <span class="panel-meta">YOUTUBE</span>
        {/if}
      </div>

      <div id="video-stage" class="video-stage">
        {%if @video_id}
          <iframe
            id="youtube-player"
            src={@embed_url}
            title="YouTube video player"
            class="youtube-player"
            allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
            referrerpolicy="strict-origin-when-cross-origin"
            allowfullscreen
          ></iframe>
        {%else}
          <div id="video-empty" class="video-empty">
            <span class="video-orbit" aria-hidden="true"><span class="play-shape"></span></span>
            <span class="video-empty-kicker">GOOD IDEAS START WITH A CLOSER LOOK</span>
            <h3>Something worth watching.</h3>
            <p>Paste a YouTube link below to bring it into your workspace.</p>
          </div>
        {/if}
      </div>

      <div class="video-source-area">
        <form id="video-source-form" $submit="load_video">
          <label for="video-source" class="field-label">YouTube link</label>
          <div class="video-source-controls">
            <input id="video-source" name="source" type="text" value={@source} $change="update_source" placeholder="Paste a YouTube URL or video ID" maxlength="2048" required aria-describedby="video-source-help video-error" aria-invalid={if(@error, do: "true", else: "false")} class="workspace-input" />
            <button id="load-video" type="submit" class="primary-button" disabled={@loading?}>
              {%if @loading?}Loading…{%else}Load video{/if}
            </button>
          </div>
          <p id="video-error" role="status" class="field-error">{@error}</p>
          <p id="video-source-help" class="field-hint">Watch links, Shorts, and video IDs all work. Playback stays in YouTube.</p>
        </form>
      </div>
    </section>
    """
  end

  @impl Component
  def action(:update_source, %{event: %{value: value}}, component) do
    put_state(component, source: value, error: nil)
  end

  def action(:load_video, %{event: %{"source" => source}}, component) do
    component
    |> put_state(source: source, loading?: true, error: nil)
    |> put_command(:resolve_video, source: source)
  end

  def action(:video_loaded, %{video_id: id, embed_url: url}, component) do
    put_state(component, video_id: id, embed_url: url, error: nil, loading?: false)
  end

  def action(:video_invalid, _params, component) do
    put_state(component,
      error: "Enter a valid YouTube link or an 11-character video ID.",
      loading?: false
    )
  end

  @impl Component
  def command(:resolve_video, %{source: source}, server) do
    case VideoSource.youtube_id(source) do
      {:ok, id} ->
        put_action(server, :video_loaded, video_id: id, embed_url: VideoSource.embed_url(id))

      :error ->
        put_action(server, :video_invalid)
    end
  end
end
