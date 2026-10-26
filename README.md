# ReviewProject

The [first release contract](docs/release-contract-v1.md) is the authoritative
product scope. Read it before planning features or interpreting older research
and architecture notes.

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

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
