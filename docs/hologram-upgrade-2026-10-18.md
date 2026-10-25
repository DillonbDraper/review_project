# Hologram upgrade verification

Date: 2026-10-18

## Changes

Hologram was upgraded from 0.9.3 to 0.12.1, the patch selected by Hex within the
0.12 release line. The project now requires Elixir 1.19 or later. The existing
environment satisfies Hologram's OTP 28.1+ and Node.js 20+ requirements:
Elixir 1.20.1, OTP 28.5.0.2, Node.js 24.15.0.

Supporting updates include Hologram's transitive dependencies and compatible
updates for packages Hex flagged with advisories:

| Package | Previous | Updated |
| --- | --- | --- |
| hologram | 0.9.3 | 0.12.1 |
| phoenix | 1.8.8 | 1.8.15 |
| phoenix_live_view | 1.1.32 | 1.1.33 |
| bandit | 1.12.0 | 1.13.1 |
| phoenix_pubsub | 2.2.0 | 2.4.1 |
| phoenix_template | 1.0.4 | 1.1.0 |
| plug | 1.20.1 | 1.20.3 |
| plug_crypto | 2.1.1 | 2.2.0 |
| gproc | 1.2.0 | 1.3.0 |
| hpax | 1.0.3 | 1.1.0 |
| thousand_island | 1.5.0 | 1.6.0 |
| lazy_html | 0.1.11 | 0.1.13 |
| postgrex | 0.22.2 | 0.22.4 |
| db_connection | 2.10.1 | 2.10.2 |
| swoosh | 1.26.2 | 1.29.0 |
| req | 0.6.2 | 0.7.5 |
| finch | 0.23.0 | 0.24.0 |
| mint | 1.9.0 | 1.11.0 |
| elixir_make | 0.9.0 | 0.10.0 |

The existing Membrane/WebRTC versions and constraints were retained.

## Compatibility fix

A fresh production compilation exposed the collision between Hologram's old
`uuid` package and Membrane's `elixir_uuid` package: both define `UUID` and
`UUID.Mixfile`, and the compiler skipped generating `uuid.app`. Cached dev/test
builds concealed this failure.

`vendor/uuid_compat` now supplies an empty `:uuid` compatibility application that
depends on `:elixir_uuid`. This retains Hologram's application dependency and
uses a single implementation of `UUID.uuid4/0`. The old Hex lock entry was
removed, and old UUID build artifacts were cleaned with
`mix deps.clean uuid --build`. The regression test checks that Hologram can
create a valid session UUID through the shared provider and preserve it on
subsequent initialization.

The existing endpoint WebSocket workaround remains. Routes continue to be
served by `Hologram.Router` before the Phoenix router; the two spike pages are
still enabled only in development. No router scopes or LiveView sessions changed.

## Verification

All completed successfully:

- `direnv exec . mix precommit`: **113 tests passed**, including the UUID
  compatibility regression; project compilation treats warnings as errors.
- `direnv exec . mix assets.build`: CSS and Phoenix JavaScript rebuilt.
- `direnv exec . env MIX_ENV=prod mix compile --warnings-as-errors`: production
  compilation and Hologram production bundling passed after the UUID fix.
- `direnv exec . env MIX_ENV=prod mix assets.deploy`: minification and asset
  digest generation passed. Generated fingerprint files were removed afterward.
- `node --check scripts/hologram_smoke_test.mjs` and `git diff --check` passed.
- `node scripts/hologram_smoke_test.mjs`: passed against the restarted app using
  Chrome 155 with simulated camera and microphone. It uses built-in Node APIs.

The final browser run covered:

| Scenario | Evidence |
| --- | --- |
| Canvas drawing, replay, clear | 1,275 drawn pixels; 1,242 replayed pixels; clear returned to zero |
| JS object references | Registry retained all 50 actions; plain object conversion retained the expected copy semantics |
| Rapid callbacks | All 50 synchronously dispatched stroke actions reached Hologram state and could be replayed |
| Direct and registry WebRTC loopbacks | Both datachannels opened, returned ping/pong, emitted message callbacks, and closed |
| Membrane media echo | Both browser peers connected; 137 audio packets and 124 video packets received; 53 video frames decoded |
| Drawing over live video | 617 drawn pixels; 600 replayed pixels; video DOM identity persisted and frame decoding advanced |
| Explicit Stop cleanup | Browser camera/microphone tracks ended and both PeerConnections closed; server log showed normal pipeline termination |
| Independent tab and hard reload | A second tab started with fresh state; initialization worked after reload |
| Realtime reconnection | Closing the real EventSource and injecting an error notification produced a successful new handshake and open stream |
| Browser/server errors | No browser exceptions, console errors, failed HTTP responses, unexpected failed requests, or server error entries |

Browser invocation and requirements are documented in `README.md`.

## Remaining limitations

- Hex still flags **Decimal 2.4.1** for CVE-2026-32686 and CVE-2026-97853.
  The existing `ratio`/`numbers` constraints in the Membrane dependency tree
  exclude the patched Decimal 3.x versions. Compatible updates to these
  packages did not resolve that constraint. This remains follow-up work.
- Third-party dependencies emit existing Elixir 1.20/compiler warnings during
  fresh builds. The project's warnings-as-errors check passes.
- Browser validation used local HTTP and simulated media. Safari/HTTP/2,
  physical devices, TURN/NAT traversal, and multi-participant rooms were not
  exercised. The reconnect check simulates stream failure rather than a real
  network outage.
- Explicit Stop cleanup was verified. The pre-existing raw-tab-close pipeline
  leak recorded in the Phase 0 teardown remains separate application work.
