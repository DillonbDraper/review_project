defmodule ReviewProjectWeb.Hologram.WhiteboardPanel do
  @moduledoc "A separate surface reserved for future client-side drawing; never overlays YouTube."
  use Hologram.Component

  @impl Component
  def template do
    ~HOLO"""
    <section id="whiteboard-panel" class="workspace-card whiteboard-panel" aria-labelledby="whiteboard-heading">
      <div class="panel-heading">
        <div class="flex items-center gap-3"><span class="section-number">03</span><h2 id="whiteboard-heading">The drawing board</h2></div>
        <span class="coming-later-badge">COMING LATER</span>
      </div>
      <div id="drawing-surface" class="drawing-surface" aria-describedby="drawing-description">
        <span class="drawing-corner drawing-corner-top" aria-hidden="true"></span>
        <span class="drawing-corner drawing-corner-bottom" aria-hidden="true"></span>
        <div>
          <p class="drawing-title">A little room to think outside the frame.</p>
          <p id="drawing-description">A dedicated whiteboard for future sketches and annotations.<br />Your video stays clear, your ideas get their own space.</p>
        </div>
      </div>
    </section>
    """
  end
end
