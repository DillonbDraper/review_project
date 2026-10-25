if Application.compile_env(:review_project, :hologram_spikes, false) do
  defmodule ReviewProjectWeb.Hologram.Spikes.MeshPanel do
    use Hologram.Component
    prop :text, :string, default: ""
    prop :manual, :boolean, default: false

    def template do
      ~HOLO"""
      <section id="mesh-panel" class="rounded-2xl border border-white/10 bg-slate-900 p-5">
        <h2 class="text-xl font-semibold">Local mesh conferencing</h2>
        {%if @manual}
          <p class="mt-2 text-sm leading-6 text-slate-300">Experimental 320 × 180 at 15 fps. Start your camera and microphone, then enable room audio above. Your own preview always stays silent. Stop media releases capture; toggling a stream keeps its device open.</p>
        {%else}
          <p class="mt-2 text-sm leading-6 text-slate-300">Experimental 320 × 180 at 15 fps, with four direct peers per participant. Playback elements are muted for this automated local test; encoded audio still travels between peers.</p>
        {/if}
        <div class="mt-4 flex flex-wrap gap-3">
          <button id="mesh-start" $click="start_media" class="rounded-xl bg-cyan-300 px-4 py-3 font-semibold text-slate-950 transition hover:bg-cyan-200">Start camera and microphone</button>
          <button id="mesh-start-microphone" $click="start_microphone" class="rounded-xl border border-cyan-300/40 px-4 py-3 text-cyan-100 transition hover:bg-cyan-300/10">Start microphone only</button>
          <button id="mesh-stop" $click="stop_media" class="rounded-xl border border-rose-300/30 px-4 py-3 text-rose-200 transition hover:bg-rose-300/10">Stop media</button>
          <button id="mesh-audio" $click="toggle_audio" class="rounded-xl border border-slate-600 px-4 py-3 transition hover:border-cyan-300">Toggle microphone stream</button>
          <button id="mesh-video" $click="toggle_video" class="rounded-xl border border-slate-600 px-4 py-3 transition hover:border-cyan-300">Toggle camera stream</button>
        </div>
        <p class="mt-3 text-xs leading-6 text-slate-400">Camera and microphone are opened separately. If one fails, the other can still join. Stop media before changing capture mode. Room audio controls only what you hear from others.</p>
        <div id="mesh-videos" class="mt-5 grid gap-3 sm:grid-cols-2 lg:grid-cols-3"></div>
        <h3 class="mt-6 font-semibold">Room chat</h3>
        <p class="mt-1 text-xs text-slate-400">This experiment retains the latest 50 messages in memory. Release retention policy is still open.</p>
        <div id="mesh-chat-log" aria-live="polite" class="mt-3 max-h-64 space-y-2 overflow-y-auto"></div>
        <label for="mesh-chat-input" class="mt-4 block text-sm text-slate-300">Message</label>
        <div class="mt-2 flex gap-3">
          <input id="mesh-chat-input" value={@text} $input="chat_changed" maxlength="1000" class="min-w-0 flex-1 rounded-xl border border-slate-600 bg-slate-950 px-4 py-3 text-white focus:border-cyan-300" />
          <button id="mesh-chat-send" $click="send_chat" class="rounded-xl bg-cyan-300 px-4 py-3 font-semibold text-slate-950 transition hover:bg-cyan-200">Send</button>
        </div>
      </section>
      """
    end
  end
end
