if Application.compile_env(:review_project, :hologram_spikes, false) do
  defmodule ReviewProjectWeb.Hologram.Spikes.YouTubeSyncPage do
    @moduledoc "Development-only, server-authoritative YouTube playback experiment."
    use Hologram.Page
    use Hologram.JS

    alias ReviewProject.SyncSpikes.Rooms
    alias ReviewProjectWeb.Hologram.Spikes.SpikeLayout
    alias ReviewProjectWeb.Hologram.Spikes.MeshPanel
    alias ReviewProjectWeb.Hologram.Spikes.MeshManualPanel

    js_import from: "./youtube_sync_probe.mjs", as: :SyncProbe

    route "/dev/spikes/youtube-sync"
    layout SpikeLayout

    def init(params, component, _server) do
      component =
        put_state(component,
          session_id: "",
          room: Map.get(params, :room, ""),
          role: "not joined",
          status: "Create a research room or join an invitation.",
          source: "M7lc1UVf-VE",
          seconds: "15",
          invite: "",
          ready: false,
          connected: false,
          enabled: false,
          error: "",
          sample: "{}",
          lag: "0",
          mesh: Map.get(params, :mesh, false),
          manual: Map.get(params, :manual, false),
          access: Map.get(params, :access, false),
          access_invitation: Map.get(params, :invitation, ""),
          access_summary: "",
          access_busy: false,
          access_signed_in: false,
          access_auth_status: "Checking sign-in…",
          access_login_url: "/dev/spikes/room-access/sign-in",
          can_control: false,
          chat_text: ""
        )

      if Map.get(params, :access, false),
        do: put_action(component, :watch_access_auth),
        else: component
    end

    def template do
      ~HOLO"""
      {%if @access}
        <window $focus="watch_access_auth" />
      {/if}
      <main id="youtube-sync-spike" class="mx-auto flex min-h-screen w-full max-w-5xl flex-col gap-6 px-6 py-10">
        <header>
          {%if @access}
            <p class="text-xs font-semibold uppercase tracking-[0.25em] text-cyan-300">Release viability · spike 5</p>
            <h1 class="mt-3 text-4xl font-semibold tracking-tight">A room with an owner. A session that continues.</h1>
            <p class="mt-4 text-sm leading-6 text-slate-300">Create a room while signed in. Share its invitation with up to four named guests. After 10 seconds of host absence, the earliest-joined connected guest controls playback; the returning host automatically reclaims it.</p>
            <p id="access-auth-status" role="status" class="mt-3 text-sm text-cyan-100">{@access_auth_status}</p>
            {%if !@access_signed_in}
              <a id="access-login" href={@access_login_url} class="mt-3 inline-block text-cyan-200 underline underline-offset-4">Sign in or register as the room owner</a>
            {/if}
          {%else}
          {%if @manual}
            <p class="text-xs font-semibold uppercase tracking-[0.25em] text-cyan-300">Release viability · manual spike 3B</p>
            <h1 class="mt-3 text-4xl font-semibold tracking-tight">Five people. Real devices.</h1>
          {%else}
          {%if @mesh}
            <p class="text-xs font-semibold uppercase tracking-[0.25em] text-cyan-300">Release viability · spike 3A</p>
            <h1 class="mt-3 text-4xl font-semibold tracking-tight">Five participants, one watch party</h1>
          {%else}
            <p class="text-xs font-semibold uppercase tracking-[0.25em] text-cyan-300">Release viability · spike 2</p>
            <h1 class="mt-3 text-4xl font-semibold tracking-tight">One room, one playback timeline</h1>
          {/if}
          {/if}
          <p class="mt-4 max-w-3xl leading-7 text-slate-300">Create a room, open its guest link in another browser, and enable playback on each device. Shared controls update the server timeline. Local player interactions are corrected back to that timeline.</p>
          <p class="mt-2 text-sm text-amber-200">Development experiment. Host credentials are temporary research fixtures; accounts and control handoff are separate work.</p>
          {/if}
        </header>
        {%if @manual}
          <MeshManualPanel />
        {/if}
        <section class="rounded-2xl border border-white/10 bg-slate-900 p-5">
          {%if @access}
            <label for="access-name" class="mb-2 block text-sm text-slate-300">Your display name</label>
            <input id="access-name" maxlength="60" autocomplete="nickname" placeholder="Choose a name" class="mb-5 w-full rounded-xl border border-slate-600 bg-slate-950 px-4 py-3 text-white focus:border-cyan-300" />
            <p id="access-status" role="status" class="mb-4 text-sm leading-6 text-cyan-100">{@access_summary}</p>
            <p class="mb-4 text-xs leading-6 text-slate-400">One browser occupies one seat. Joining in another tab moves the seat and stops media here. Disconnected guest seats are held for 30 seconds. Ownership remains with the signed-in account. Rooms and chat in this spike are held in memory.</p>
          {/if}
          <label for="sync-room" class="block text-sm text-slate-300">Room ID (or open a guest link)</label>
          <input id="sync-room" value={@room} $input="room_changed" class="mt-2 w-full rounded-xl border border-slate-600 bg-slate-950 px-4 py-3 text-white focus:border-cyan-300" />
          <div class="mt-4 flex flex-wrap gap-3">
            <button id="sync-create" $click="create" disabled={@access_busy} class="rounded-xl bg-cyan-300 px-4 py-3 font-semibold text-slate-950 transition hover:bg-cyan-200 disabled:opacity-40">Create research room</button>
            <button id="sync-join" $click="join" disabled={@access_busy} class="rounded-xl border border-slate-600 px-4 py-3 transition hover:border-cyan-300 disabled:opacity-40">Join room</button>
            <button id="sync-leave" $click="leave" class="rounded-xl border border-rose-300/30 px-4 py-3 text-rose-200 transition hover:bg-rose-300/10">Leave</button>
          </div>
          <p class="mt-4 text-sm text-slate-300">Role: <strong id="sync-role">{@role}</strong></p>
          <a id="sync-invite" href={@invite} target="_blank" rel="noopener" class="mt-2 inline-block break-all text-sm text-cyan-200 underline underline-offset-4">{@invite}</a>
        </section>
        <section aria-label="Video player" class="rounded-2xl border border-white/10 bg-black p-3">
          <p id="sync-status" role="status" class="mb-3 px-2 text-slate-200">{@status}</p>
          <p id="sync-error" role="alert" class="mb-3 px-2 text-rose-200">{@error}</p>
          <div id="sync-player" class="aspect-video min-h-[200px] w-full"></div>
        </section>
        <section class="rounded-2xl border border-white/10 bg-slate-900 p-5">
          <div class="flex flex-wrap gap-3">
            <button id="sync-enable" $click="enable" disabled={!@ready} class="rounded-xl bg-cyan-300 px-4 py-3 font-semibold text-slate-950 transition hover:bg-cyan-200 disabled:opacity-40">1. Enable playback on this device</button>
            <button id="sync-play" $click="play" disabled={!@can_control || !@connected} class="rounded-xl border border-cyan-300/40 px-4 py-3 text-cyan-100 transition hover:bg-cyan-300/10 disabled:opacity-40">2. Play for everyone</button>
          </div>
          <p class="mt-3 text-sm leading-6 text-slate-300">Enabling this device does not start a paused room. The current playback controller presses Play for everyone; other participants enable playback and follow the room timeline.</p>
          <h2 class="mt-6 font-semibold">Shared controls (current playback controller)</h2>
          <label for="sync-source" class="mt-3 block text-sm text-slate-300">YouTube link or ID</label>
          <input id="sync-source" value={@source} $input="source_changed" class="mt-2 w-full rounded-xl border border-slate-600 bg-slate-950 px-4 py-3 text-white focus:border-cyan-300" />
          <div class="mt-4 flex flex-wrap items-end gap-3">
            <button id="sync-video" $click="video" disabled={!@can_control || !@connected} class="rounded-xl border border-slate-600 px-4 py-3 transition hover:border-cyan-300 disabled:opacity-40">Change shared video</button>
            <button id="sync-pause" $click="pause" disabled={!@can_control || !@connected} class="rounded-xl border border-slate-600 px-4 py-3 transition hover:border-cyan-300 disabled:opacity-40">Pause for everyone</button>
            <div><label for="sync-seconds" class="block text-xs text-slate-300">Seek seconds</label><input id="sync-seconds" type="number" min="0" value={@seconds} $input="seconds_changed" class="mt-1 w-28 rounded-xl border border-slate-600 bg-slate-950 px-3 py-3 text-white" /></div>
            <button id="sync-seek" $click="seek" disabled={!@can_control || !@connected} class="rounded-xl border border-slate-600 px-4 py-3 transition hover:border-cyan-300 disabled:opacity-40">Seek for everyone</button>
          </div>
        </section>
        {%if @mesh}
          <MeshPanel text={@chat_text} manual={@manual} />
        {/if}
        <details class="rounded-2xl border border-white/10 p-5" open={!@manual}>
          <summary class="cursor-pointer text-sm font-semibold text-slate-300">Research controls and measurements</summary>
          <label for="sync-lag" class="mt-4 block text-sm text-slate-300">Inject one-way room-message delay (0–2000 ms)</label>
          <input id="sync-lag" type="number" min="0" max="2000" value={@lag} $input="lag_changed" class="mt-2 w-36 rounded-xl border border-slate-600 bg-slate-950 px-3 py-2 text-white" />
          <div class="mt-4 flex flex-wrap gap-3">
            <button id="sync-local-pause" $click="local_pause" class="rounded-xl border border-slate-600 px-4 py-2">Pause only here</button>
            <button id="sync-disconnect" $click="disconnect" class="rounded-xl border border-slate-600 px-4 py-2">Disconnect transport</button>
            <button id="sync-reconnect" $click="reconnect" class="rounded-xl border border-slate-600 px-4 py-2">Reconnect transport</button>
          </div>
          <pre id="sync-sample" class="mt-4 overflow-x-auto whitespace-pre-wrap break-all text-xs leading-6 text-slate-300">{@sample}</pre>
          <a href="/dev/spikes/youtube" class="mt-4 inline-block text-sm text-cyan-200 underline">Single-player experiment</a>
        </details>
      </main>
      """
    end

    def action(:watch_access_auth, _params, component) do
      JS.call(:SyncProbe, :watchAccessAuth, [])
      component
    end

    def action(:access_auth, params, component) do
      put_state(component,
        access_signed_in: params.signed_in,
        access_auth_status: params.status,
        access_login_url: params.login_url
      )
    end

    def action(:create, _params, %{state: %{access: true}} = component) do
      id = JS.call(:SyncProbe, :createAccess, [])
      put_state(component, session_id: id, access_busy: true, error: "")
    end

    def action(:create, _params, component), do: put_command(component, :create_room)

    def action(:connect, params, component) do
      id = JS.call(:SyncProbe, :connect, [params.room_id, params.host_token])
      put_state(component, session_id: id)
    end

    def action(:join, _params, %{state: %{access: true}} = component) do
      id =
        JS.call(:SyncProbe, :joinAccess, [component.state.room, component.state.access_invitation])

      put_state(component, session_id: id, access_busy: true, error: "")
    end

    def action(:join, _params, component) do
      id = JS.call(:SyncProbe, :join, [])
      put_state(component, session_id: id)
    end

    def action(:room_changed, %{event: %{value: value}}, component),
      do: put_state(component, room: value)

    def action(:source_changed, %{event: %{value: value}}, component),
      do: put_state(component, source: value)

    def action(:seconds_changed, %{event: %{value: value}}, component),
      do: put_state(component, seconds: value)

    def action(:chat_changed, %{event: %{value: value}}, component),
      do: put_state(component, chat_text: value)

    def action(op, _params, component)
        when op in [:room_audio, :room_silent, :manual_export, :manual_marker] do
      JS.call(:SyncProbe, :manualControl, [component.state.session_id, to_string(op)])
      component
    end

    def action(name, _params, component)
        when name in [
               :start_media,
               :start_microphone,
               :stop_media,
               :toggle_audio,
               :toggle_video,
               :send_chat
             ] do
      JS.call(:SyncProbe, :meshControl, [component.state.session_id, to_string(name)])
      if name == :send_chat, do: put_state(component, chat_text: ""), else: component
    end

    def action(:sync_event, params, component) do
      put_state(component,
        room: params.room,
        role: params.role,
        status: params.status,
        error: params.error,
        ready: params.ready,
        connected: params.connected,
        enabled: params.enabled,
        sample: params.sample,
        invite: params.invite,
        can_control: params.can_control,
        access_summary: params.access_summary,
        access_busy: false
      )
    end

    def action(:access_failed, params, component),
      do: put_state(component, error: params.error, access_busy: false)

    def action(:enable, _params, component) do
      JS.call(:SyncProbe, :enable, [component.state.session_id])
      component
    end

    def action(:lag_changed, %{event: %{value: value}}, component) do
      JS.call(:SyncProbe, :setLag, [component.state.session_id, value])
      put_state(component, lag: value)
    end

    def action(:leave, _params, component) do
      JS.call(:SyncProbe, :leave, [component.state.session_id])

      put_state(component,
        connected: false,
        ready: false,
        role: "not joined",
        status: "Left the research room."
      )
    end

    def action(:local_pause, _params, component) do
      JS.call(:SyncProbe, :localPause, [component.state.session_id])
      component
    end

    def action(:disconnect, _params, component) do
      JS.call(:SyncProbe, :disconnect, [component.state.session_id])
      component
    end

    def action(:reconnect, _params, component) do
      JS.call(:SyncProbe, :reconnect, [component.state.session_id])
      component
    end

    def action(name, _params, component) when name in [:play, :pause, :seek, :video] do
      JS.call(:SyncProbe, :command, [component.state.session_id, to_string(name)])
      component
    end

    def action(:create_failed, params, component), do: put_state(component, error: params.error)

    def command(:create_room, _params, server) do
      case Rooms.create() do
        {:ok, credentials} ->
          put_action(server, :connect, credentials)

        {:error, reason} ->
          put_action(server, :create_failed, %{error: "Create failed: #{reason}"})
      end
    end
  end
end
