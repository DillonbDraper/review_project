if Application.compile_env(:review_project, :hologram_spikes, false) do
  defmodule ReviewProjectWeb.Hologram.Spikes.MeshManualPanel do
    use Hologram.Component

    def template do
      ~HOLO"""
      <section id="mesh-manual-panel" class="rounded-2xl border border-cyan-300/30 bg-slate-900 p-5 sm:p-7">
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div>
            <h2 class="text-xl font-semibold">Your device test</h2>
            <p class="mt-2 max-w-2xl text-sm leading-6 text-slate-300">Use one computer per person, real cameras and microphones, and normal browser permissions. Begin with headphones in separate rooms. Create or join a room below, then enable playback and start media.</p>
          </div>
          <span class="rounded-full border border-amber-200/30 px-3 py-1 text-xs text-amber-100">Manual observations required</span>
        </div>
        <p id="manual-environment" class="mt-4 text-sm text-slate-300">Camera access needs trusted HTTPS. This page checks the connection when you join.</p>
        <label for="manual-ice-mode" class="mt-4 block text-sm text-slate-300">Network research mode (choose before creating/joining; an invitation's ?ice= mode takes priority)
          <select id="manual-ice-mode" class="ml-2 rounded-lg border border-slate-600 bg-slate-950 p-2">
            <option value="direct">Direct · no STUN/TURN</option><option value="auto">Automatic · STUN + TURN</option>
            <option value="stun">STUN only</option><option value="relay-udp">Force TURN over UDP</option>
            <option value="relay-tcp">Force TURN over TCP</option><option value="relay-tls">Force TURN over TLS</option>
          </select>
        </label>
        <p id="manual-ice-status" role="status" class="mt-3 text-sm text-cyan-200">TURN requires the local VM and an app started with TURN_SPIKE_CONFIG. TLS also requires trusting the test CA.</p>
        <div class="mt-5 grid gap-4 sm:grid-cols-2">
          <div><label for="manual-label" class="block text-sm text-slate-300">Participant label</label><input id="manual-label" maxlength="80" placeholder="Seat A · Dillon" class="mt-2 w-full rounded-xl border border-slate-600 bg-slate-950 px-3 py-2 text-white focus:border-cyan-300" /></div>
          <div><label for="manual-hardware" class="block text-sm text-slate-300">Computer / OS / power</label><input id="manual-hardware" maxlength="300" placeholder="Laptop model, OS, plugged in or battery" class="mt-2 w-full rounded-xl border border-slate-600 bg-slate-950 px-3 py-2 text-white focus:border-cyan-300" /></div>
          <div><label for="manual-audio-setup" class="block text-sm text-slate-300">Audio and connection</label><input id="manual-audio-setup" maxlength="300" placeholder="Headphones + built-in mic, home Wi-Fi" class="mt-2 w-full rounded-xl border border-slate-600 bg-slate-950 px-3 py-2 text-white focus:border-cyan-300" /></div>
          <div><label for="manual-volume" class="block text-sm text-slate-300">Room voice volume (YouTube has its own volume)</label><input id="manual-volume" type="range" min="0" max="1" step="0.05" value="0.6" class="mt-4 w-full accent-cyan-300" /></div>
        </div>
        <div class="mt-5 flex flex-wrap gap-3">
          <button id="manual-audio-enable" $click="room_audio" class="rounded-xl bg-cyan-300 px-4 py-3 font-semibold text-slate-950 transition hover:bg-cyan-200">Enable room audio</button>
          <button id="manual-audio-mute" $click="room_silent" class="rounded-xl border border-slate-600 px-4 py-3 transition hover:border-cyan-300">Mute room audio</button>
        </div>
        <p id="manual-audio-status" role="status" class="mt-3 text-sm text-amber-100">Room audio is off. Enabling it lets you hear remote participants; your own preview stays silent.</p>
        <p id="manual-media-status" role="status" class="mt-2 text-sm text-slate-300">Join a room to see camera, microphone and peer status.</p>
        <p id="manual-media-error" role="alert" class="mt-2 text-sm text-rose-200"></p>
        <details class="mt-6 rounded-xl border border-white/10 p-4" open>
          <summary class="cursor-pointer font-semibold">45–60 minute test sequence</summary>
          <ol class="mt-3 list-decimal space-y-2 pl-5 text-sm leading-6 text-slate-300">
            <li>With two people, verify both directions of voice and video. Add the other three and check every person can hear all four others.</li>
            <li>Watch YouTube together for about 30 minutes with all cameras on. Take turns speaking, interrupt naturally, move on camera, and use chat.</li>
            <li>Have the host pause, seek and resume. Background a tab, then return. Note freezes, drift, audio delay and volume balance.</li>
            <li>One guest stops/restarts media, reconnects the transport, and leaves/rejoins. Try denying permission and recovering. Export before reloading a page.</li>
            <li>Try laptop speakers one person at a time. Note echo. Observe CPU, memory, fan noise and changes as devices warm up.</li>
            <li>Press Leave, check camera/microphone indicators turn off, complete your observations and download your report.</li>
          </ol>
        </details>
        <div class="mt-5 grid gap-3 sm:grid-cols-2">
          <label class="text-sm text-slate-300">All four people audible<select id="manual-check-audio" data-manual-check="audio" class="ml-2 rounded-lg border border-slate-600 bg-slate-950 p-2"><option value="untested">Untested</option><option value="pass">Pass</option><option value="fail">Fail</option></select></label>
          <label class="text-sm text-slate-300">All four videos usable<select id="manual-check-video" data-manual-check="video" class="ml-2 rounded-lg border border-slate-600 bg-slate-950 p-2"><option value="untested">Untested</option><option value="pass">Pass</option><option value="fail">Fail</option></select></label>
          <label class="text-sm text-slate-300">Conversation over YouTube<select id="manual-check-balance" data-manual-check="balance" class="ml-2 rounded-lg border border-slate-600 bg-slate-950 p-2"><option value="untested">Untested</option><option value="pass">Pass</option><option value="fail">Fail</option></select></label>
          <label class="text-sm text-slate-300">Speaker echo acceptable<select id="manual-check-echo" data-manual-check="echo" class="ml-2 rounded-lg border border-slate-600 bg-slate-950 p-2"><option value="untested">Untested</option><option value="pass">Pass</option><option value="fail">Fail</option></select></label>
          <label class="text-sm text-slate-300">Playback / reconnect recovery<select id="manual-check-recovery" data-manual-check="recovery" class="ml-2 rounded-lg border border-slate-600 bg-slate-950 p-2"><option value="untested">Untested</option><option value="pass">Pass</option><option value="fail">Fail</option></select></label>
          <label class="text-sm text-slate-300">Devices released on Leave<select id="manual-check-cleanup" data-manual-check="cleanup" class="ml-2 rounded-lg border border-slate-600 bg-slate-950 p-2"><option value="untested">Untested</option><option value="pass">Pass</option><option value="fail">Fail</option></select></label>
        </div>
        <label for="manual-notes" class="mt-5 block text-sm text-slate-300">Observations (include CPU/memory readings, timings and who heard which problem)</label>
        <textarea id="manual-notes" maxlength="6000" rows="3" class="mt-2 w-full rounded-xl border border-slate-600 bg-slate-950 px-3 py-2 text-white focus:border-cyan-300"></textarea>
        <div class="mt-4 flex flex-wrap gap-3">
          <button id="manual-marker" $click="manual_marker" class="rounded-xl border border-slate-600 px-4 py-3 transition hover:border-cyan-300">Mark this moment</button>
          <button id="manual-export" $click="manual_export" class="rounded-xl bg-cyan-300 px-4 py-3 font-semibold text-slate-950 transition hover:bg-cyan-200">Download device report</button>
        </div>
        <p id="manual-report-status" role="status" class="mt-3 text-xs leading-6 text-slate-400">Reports contain statistics and your observations only. Samples are collected every five seconds; the latest hour is retained in this tab. Download before reloading or starting a new room. The session itself has no duration cap.</p>
      </section>
      """
    end
  end
end
