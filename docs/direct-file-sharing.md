# Direct local-file sharing

Approved replacement, 2026-11-27. The release contract defines product scope.
Historical upload evidence is retained separately and is not direct-delivery evidence.

## Architecture and resource limits

A browser-owned File supplies dedicated reliable, ordered WebRTC data channels.
Guests read 256 KiB blocks through a root-scoped service worker at
`/local-media-sw.js`; only `/__local_media/` is intercepted. Each fetch contacts
its initiating client over a MessagePort and validates that tab's random capability
against its live source ID/generation. The worker keeps no authoritative room or
file state and never caches responses. All unrelated requests use the browser's
normal network path.

GET/HEAD, inclusive/open/suffix single ranges, 206/416, cancellation and no-store
are supported. The page keeps the peer connections and a 16 MiB LRU cache. Four
blocks may be in flight per receiver. Messages include framing within 16 KiB and
the negotiated SCTP limit; the source send buffer stops at 256 KiB and resumes
below 64 KiB. A shared send scheduler gives receivers turns per fragment. There
are no whole-file guest Blobs, IndexedDB writes, Cache Storage writes or guest
seeding. The supplier's native video uses an object URL for its original File.
Browser decoder/network buffers are separate from these application limits.

`file_offer`, `file_available`, `file_signal`, `file_reset` and `file_ice` are
membership-authorized room channel operations. They validate epoch, seat connection,
source generation and peer generation; offers additionally require current
controller, authority and playback revision. SDP/candidates use the conference
bounds, with independent file rate limits. Only the source offers; receivers answer.
TURN credentials remain in native handles. Same-page restoration also checks a
private document ID retained by the coordinator, not exposed in snapshots.

File availability and controller authority are independent. A source loss pauses
the authoritative position. Delivery restoration never starts playback. Native
resources are invalidated on departure and rebuilt with fresh peer credentials;
only the source's accepted File handle survives a brief same-page interruption.
Reload, replacement, navigation, explicit leave and cleanup require a new selection.
Five minutes empty or one hour idle ends the share, not the room or original file.

Metadata inspection uses pinned, vendored `mediainfo.js` 0.3.9 in a dedicated module
worker, with a 16 MiB read budget and a ten-second deadline (worker termination).
See `assets/vendor/mediainfo/README.md` for package integrity and license. This is
untrusted browser metadata, not a server ffprobe assertion. The server validates
bounded descriptors and format identifiers; recipients check native decoding.

## Hologram orchestration

File sharing follows the conferencing state/effect architecture. Client-side
Elixir owns orchestration, and the server remains authoritative for admission,
selection, source availability and shared playback:

- `FileShareState` owns selection/preparation state, authority/revision guards,
  roster reconciliation, source restoration, peer replacement, credential-refresh
  scheduling, retry policy and displayed status/metrics.
- `FileSharePeer` serializes native operations per peer: channel creation/binding,
  offer/answer construction, local/remote descriptions and candidate flushing.
  Native completions resume explicit phases; asynchronous work never blocks later
  Hologram actions. Queues and candidates are bounded and obsolete scopes are ignored.
- `FileShareMetadata` applies the codec/container allowlist to bounded primitive
  worker output. The worker performs WASM inspection and metadata projection only.
- `FileShareBrowser` executes effects and immediately retains returned TURN
  credentials behind scoped native handles. Credentials are never component state.
- `VideoPanel` hosts the file-sharing model and presentation alongside playback.
  `RoomPanel` forwards admission, roster, file signals, peer resets and stop events.
  Signals received before admission finishes are bounded and checked against the
  admitted room/source/seat generations before negotiation.

`file_share_native.mjs` holds native File/worker/peer/channel objects, opaque
handles, timers, object URLs and transfer resources. Its operational source
configuration validates range requests; it has no room snapshot, roster model,
controller policy, signaling client, retry loop or restoration decision. Elixir
requests individual browser operations and receives plain completion events.
Page exit and transport loss still dispose resources synchronously before another
Hologram action is needed. Only an accepted File handle can survive a same-document
signaling interruption; Elixir decides whether the admitted source may restore it.

Binary blocks, cache management, stream backpressure and MessagePorts remain in
JavaScript. No packet or media buffer enters Hologram state. Only lifecycle events,
inspection metadata, operation results and once-per-second counters cross the bridge.
Moving these decisions to Hologram adds no server round trip to byte delivery.

## Build and deployment

`mix assets.build` and `mix assets.deploy` bundle the service worker and metadata
worker, and copy the same-origin WASM runtime. No runtime CDN or npm install is
needed. The stable worker entry is served from the root to control room pages;
the browser registration bypasses the HTTP update cache. Staging asset smoke
checks fetch all three artifacts and verify malformed legacy upload POSTs return
410. `/room-media/*` and network fallbacks to `/__local_media/*` reject before
body parsing. The staging service, upload/probe adapters and upload environment
variables were removed. Runtime codec libraries for Membrane remain installed.
No database migration is required. Do not set UPLOADED_VIDEO_ENABLED/ROOT.

## Reproduce local room verification

Use an isolated development database, local Chrome debugging profile and localhost
(or HTTPS). The fixture creates/reuses only a synthetic `playback-*@example.test`
account and writes a private login token file; it sends no email.

```sh
PGDATABASE=review_direct_file_verify mix ecto.create
PGDATABASE=review_direct_file_verify mix ecto.migrate
HOLOGRAM_START=1 mix assets.build
HOLOGRAM_START=1 PGDATABASE=review_direct_file_verify PORT=4100 mix phx.server
# In another terminal, with Chrome's isolated CDP listener on 9322:
PGDATABASE=review_direct_file_verify PLAYBACK_FIXTURE=/tmp/review-direct-file-fixture.json mix run --no-compile --no-start scripts/playback_fixture.exs
CHROME_DEBUG_URL=http://127.0.0.1:9322 APP_URL=http://localhost:4100 \
  PARTICIPANTS=5 ACTIVE_CONFERENCE=1 MEDIA_FILE=/absolute/path/control.mp4 \
  FILE_SHARE_REPORT=/tmp/direct-file-report.json node scripts/direct_file_browser_test.mjs
```

Use the same dedicated PGDATABASE for the server and fixture. Do not run multiple room coordinators against one development database: another instance’s orphan recovery can invalidate live seats. Generate a fresh fixture token before another run without recompiling browser assets. `MIXED_FIREFOX=1` uses an
already running Firefox BiDi listener (`FIREFOX_DEBUG_URL`) as the first guest.
`FORCE_RELAY=1` forces test peer connections to relay, requiring configured TURN, and checks the selected file candidate pairs. `LATE_JOIN=1` replaces a departing guest with a new receiver while the source continues. The harness backgrounds the source tab during settled measurements and records whether the browser actually reports it hidden.
The harness checks selection UI, native decoded frames, private worker ranges,
cache bounds, uncached seek recovery, settled drift/spread, worker restart, source
signaling reconnection and explicit resume. Synthetic conference media never
accesses real cameras or microphones. Reports identify exact browser/fixture scope.

Run native tests with `for test_file in test/js/*_test.mjs; do node "$test_file" || exit; done`
and run `mix precommit`. Tests cover protocol framing/backpressure/cancellation,
LRU eviction, worker streaming, native handle lifecycle, room authority, source
pause/restoration, peer generations and legacy body rejection.

## Evidence and remaining checks

Local verification is recorded below as runs complete. Linux Chrome/Firefox
checks cannot establish Edge or Safari compatibility. Explicitly validate Safari's
native initial byte ranges and uncached seeks, Edge, real five-device bandwidth,
forced public TURN, a slow receiver, long background-source playback and repeated
cold/warm preparation before treating those paths as verified. Preserve the
0.5-second settled drift/spread and five-second ready-player recovery targets.

### Local runs, 2026-11-27 (America/Chicago)

All runs below passed with **five participants** and synthetic camera/microphone
conferencing enabled. Browser versions: Chrome 158.0.8127.36 and Firefox 160.0.1.
The H.264 control was 19,472,924 bytes; the original AV1 sample was 775,550,155 bytes
(2,424.181 seconds). These are local-device observations, not hosted capacity results.

| Fixture / receivers / transport | Preparation (s) | First decoded frame, all guests (s) | p95 drift (s) | Max spread (s) | Seek recovery (s) | Guest bytes at first frame (MiB) | Observed aggregate send (Mbps) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| H.264/AAC · Chrome · direct | 2.65 | 3.71 | 0.165 | 0.122 | 1.08 | 3.31–3.53 | 64.0 |
| AV1/Opus · Chrome + Firefox · direct | 2.06 | 3.17 | 0.258 | 0.213 | 3.25 | 1.83–3.12 | 46.2 |
| H.264/AAC · Chrome · localhost TURN | 2.62 | 3.76 | 0.204 | 0.154 | 0.84 | 2.95–3.31 | 68.6 |

Preparation is chooser-to-accepted-selection; first frame includes preparation and
local playback enablement. These are not controlled cold/warm cache measurements.
Send rate is the approximate source data-channel rate between first-frame and
post-seek snapshots, including range prefetch and framing, excluding RTP and transport
overhead. Bursts are not a quality setting or a steady bandwidth requirement. All
receivers decoded before full-file transfer. No buffering sample occurred during
the 20 settled observations per participant; preparation and seek recovery are
reported separately. Application caches remained within 16 MiB.

The direct Chrome run also passed worker restart. Both direct runs passed source
reconnect with retained File, paused restoration, explicit controller resume,
replacement at zero and supplier reload without a retained File. The isolated
localhost TURN run verified relay candidates at both ends, source delivery while
its tab was actually hidden, worker restart, source restoration, a late guest
receiving with devices off, replacement and reload. TURN was bound only to loopback
with temporary credentials and stopped after validation.

Bounded MediaInfo inspection read 2,105,999 bytes of the large AV1 recording;
H.264 was accepted and the HEVC control rejected. Protocol tests verify exact byte
delivery, four-block concurrency, negotiated fragment limits, cancellation, LRU
eviction and isolation of a slow receiver. GET/HEAD and small/suffix/invalid ranges
passed in native Chrome and Firefox playback.

Final automated checks: `mix precommit` **431 passed**; native JavaScript tests
**28 passed**; staging asset/shell checks **5 passed**. Worker/WASM build and digest
packaging are checked separately below. Temporary JSON reports remain at
`/tmp/direct-file-h264-five.json`, `/tmp/direct-file-av1-mixed-five.json` and
`/tmp/direct-file-turn-five.json`; the table preserves their measured results.

Earlier harness failures exposed development reload/asset-registry interference,
incorrect boolean-attribute checks, and shared-database coordinator interference.
The final relay run used a dedicated database. Historical upload-browser evidence
does not substitute for these direct-delivery checks.

Remaining: Edge and Safari native playback/seek matrix, public TURN/network paths,
real five-device uplink capacity, prolonged background-source playback, repeated
cold/warm preparation and long-duration repeatability. The local relay and short
background window do not establish those results.

Asset verification: `mix assets.build` and `mix assets.deploy` passed. The service worker, metadata worker and WASM have original and digested artifacts; JavaScript also has gzip variants. The copied WASM matches the pinned source SHA-256. A full container release smoke was prepared but not executed here. Restart the development server after changing the asset watcher configuration.

### Hologram refactor validation, 2026-11-27 (America/Chicago)

The refactored orchestration passed all three five-participant scenarios with
active synthetic conferencing. The source was actually backgrounded during each
settled measurement. All runs also passed late admission with devices off, paused
source restoration, explicit resume, replacement at zero and reload without a File.

| Run | p95 drift (s) | Max spread (s) | Uncached seek recovery (s) | Forced file-peer recovery (s) |
| --- | ---: | ---: | ---: | ---: |
| Chrome H.264 direct | 0.187 | 0.127 | 0.95 | Not forced |
| Chrome + Firefox AV1 direct | 0.272 | 0.232 | 3.14 | 2.32 |
| Chrome H.264 localhost TURN | 0.202 | 0.109 | 0.93 | 2.74 |

The AV1 and TURN cases deliberately closed one receiver's file peer and verified
automatic recovery without pausing the authoritative timeline. The TURN run checked
relay candidates at both endpoints. Chrome worker restart also passed. Transport
resource/cache limits remain unchanged. Temporary reports: `/tmp/hologram-file-h264-five.json`,
`/tmp/hologram-file-av1-mixed-five.json`, `/tmp/hologram-file-turn-five.json`.

Pure Elixir regressions cover selection cancellation/rejection, stale callbacks,
publication during host reclaim, source restoration, pre-admission signaling,
serialized negotiation, candidate bounds, peer/seat generation replacement,
per-peer backoff and cancellation, credential-refresh effects and format acceptance.
Native tests cover opaque handles, cancelled workers, immediate disposal, late
completions, private credential handles and the single-channel resource bound.
Final checks: `mix precommit` **450 passed** and native JavaScript **31 passed**.
Previously recorded Edge/Safari, public-network and full-container checks remain
separate; local browser and loopback-relay passes do not establish those results.
