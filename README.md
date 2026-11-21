# ReviewProject

The [first release contract](docs/release-contract-v1.md) is the authoritative
product scope. Read it before planning features or interpreting older research
and architecture notes.

The [rooms/UI integration plan](docs/rooms-ui-integration-plan.md) records the
current wiring gaps, local setup prerequisites, and staged delivery of real rooms,
shared chat, synchronized playback, and conferencing in the workspace.

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## Create a room and invite people

Use the tracked Nix environment to supply the native libraries and asset tools:

```sh
nix develop
dbstart
mix setup
mix holo
```

At `/`, choose **Create a room**. Sign in first (or register and open the
confirmation email at `/dev/mailbox`), then enter a room name and your display
name. The room opens with an invitation link you can copy and share anywhere.
Guests open the link, choose a display name, and join without an account. Use a
different browser/profile to try a separate guest: tabs in one browser share a
seat. **Leave room** releases a guest seat immediately.

The home page lists your recent open rooms. Reopening one uses your signed-in
ownership; if this tab no longer has its invitation, **Invite people** offers an
explicit replacement link. Replacement affects future joins; connected guests
stay admitted. Links are kept in tab session storage, and their credential is in
the URL fragment rather than the HTTP request path.

Room chat is shared with everyone currently joined. Messages use server-assigned
names and ordering, and the full conversation returns on reload/rejoin. Sending
is disabled while disconnected, and an unsent draft is kept.
Messages appear in one continuous scrollable conversation, without paging or a
display limit. New arrivals preserve your position when you are reading above.
Video playback remains local.

Rooms initialize conference receivers as soon as you join, without requesting
camera or microphone permission. **Turn on microphone** and **Turn on camera**
work independently; either can fail or remain unanswered while you receive the
other participants' media. **Enable room audio** appears if playback needs a
browser gesture. Turning a device off releases its capture; leaving or moving
the seat to another tab closes the call's native resources.

Connected participants appear in separate square tiles above the review video,
including a muted local preview marked **You**. Camera-off or unavailable video
stays black with the participant's name. Tiles wrap on narrower windows, and
remote audio continues independently of the camera display.

Conferencing supports direct connections and configurable STUN/TURN with temporary
credentials. Failed peer connections get a bounded ICE restart and coordinated
replacement, with **Retry call connection** if recovery is exhausted. Signaling
loss releases capture immediately; the same page restores previously enabled
devices after rejoining. Fresh loads start with devices off.

See [conference networking](docs/conference-networking.md) for runtime relay
configuration and local checks. Public relay deployment and cross-network/browser
validation remain outstanding. Firefox background-tab work was closed after the
owner could not reproduce the issue during manual verification on 2026-11-19.
Use localhost or trusted HTTPS for device access.

For a second computer on your home network, follow the
[home-network chat guide](docs/home-network-chat.md). Use the same trusted HTTPS
LAN address on the host and guest so invitation links work on both computers.

Run the room browser check with a development server and an isolated Chrome
debugging instance as described below:

```sh
node scripts/rooms_browser_test.mjs
```

It creates a synthetic local account and room using `/dev/mailbox`, so use a
disposable development database. `APP_URL` and `CHROME_DEBUG_URL` override the
default `http://localhost:4000` and `http://127.0.0.1:9222`. The check exercises
the creation modal, invitation admission, shared chat, full history, socket
reconnection, draft recovery, live roster, tab replacement, explicit leave, and
invalid-link feedback. It also checks receive-only conferencing, independent
device failures and pending permissions, later device enablement, advancing RTP
in both directions, frames displayed in participant tiles, five-person layout
and mesh, audio playback, offer collisions, and capture cleanup using
Chrome's synthetic camera/microphone flags below. Conference state and negotiation
checks run in ExUnit; native handle/cleanup checks run with
`node test/js/conference_native_test.mjs`.
Use normal autoplay restrictions for the room check: omit the autoplay override
from the legacy spike smoke-test command below.
Room lifecycle and client delivery/history behavior are written in Elixir/Hologram
and covered by `mix precommit`; JavaScript only adapts browser APIs and the Phoenix
channel transport. Run checks before starting
the development server: Hologram dev/test builds share generated asset paths;
restart `mix holo` after running `mix precommit` to refresh development bundles.

## Hologram development and checks

The [YouTube player spike](docs/youtube-player-spike.md) is available at
`/dev/spikes/youtube`, with HTTPS setup and Chrome/Firefox verification commands
in its write-up.

The [synchronized YouTube playback spike](docs/youtube-sync-spike.md) is at
`/dev/spikes/youtube-sync`. Its multi-browser harness measures drift, late joins,
reconnection, network latency, and media-interruption recovery.

The [local five-person mesh spike (3A)](docs/local-mesh-spike.md) is at
`/dev/spikes/youtube-mesh`. It combines real WebRTC, shared YouTube and chat,
with mixed-browser automation and native media-resource cleanup checks.

The [manual five-device test (3B)](docs/manual-mesh-spike.md) is at
`/dev/spikes/youtube-mesh-manual`, with room audio, a test checklist and downloadable
device reports. Start LAN HTTPS and the certificate setup page with
`node scripts/start_mesh_lan.mjs`; see its write-up for certificate trust and
the temporary home-subnet firewall helper.
The project owner accepted 3B and the local TURN connectivity checks as successful
on 2026-10-24. The [ownership/handoff spike (5)](docs/ownership-spike.md) is now at
`/dev/spikes/room-access`: signed-in owners, named invitation guests, shared
browser seats, reconnect reservations and automatic playback handoff/reclaim.
The owner also accepted spike 5 as complete on 2026-10-24 after manual testing.
Public-network TURN/cost validation and the combined multi-hour soak remain open.
The [local coturn VM setup](docs/turn-spike.md)
adds reproducible KVM infrastructure, temporary credentials, forced relay modes,
and UDP/TCP/TLS verification. Start it with `node scripts/turn_vm.mjs start` after
the initial build; see the guide for app configuration and LAN firewall rules.

Hologram 0.12 requires Elixir 1.19+, OTP 28.1+, and Node.js 20+.
The project's Nix environment supplies Elixir 1.20, OTP 28, and Node.js 24.

Start the database and enable Hologram's compiler/runtime:

```sh
direnv exec . dbstart
direnv exec . mix holo
```

The development probes are `/dev/spikes/hologram-interop` and
`/dev/spikes/hologram-webrtc`. Plain `mix phx.server` leaves Hologram disabled
in development unless `HOLOGRAM_START=1` is set.

Run the server-side checks with `direnv exec . mix precommit`.
For browser checks, keep `mix holo` running and launch a separate Chrome
instance with a temporary profile and simulated camera/microphone:

```sh
google-chrome --headless=new \
  --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222 \
  --user-data-dir="$(mktemp -d)" \
  --no-first-run --no-default-browser-check \
  --use-fake-device-for-media-stream --use-fake-ui-for-media-stream \
  --autoplay-policy=no-user-gesture-required about:blank
```

In another terminal, run:

```sh
node scripts/hologram_smoke_test.mjs
```

The smoke test uses Node.js 24's built-in APIs and needs no npm dependencies.
It checks canvas rendering/replay/clear, burst actions, JS object references,
WebRTC datachannel loopbacks, Membrane audio/video echo with a drawing overlay,
media cleanup, independent tabs, reload, and realtime reconnection. It creates
and closes its own tabs. Override `APP_URL` or `CHROME_DEBUG_URL` if needed.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix

