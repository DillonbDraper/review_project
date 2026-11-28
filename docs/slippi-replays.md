# Slippi replay operations and validation

The [release contract](release-contract-v1.md) records the approved behavior.
The [spike report](slippi-integration-spike.md) is historical evidence.

## Runtime and storage

Replay support is part of the application in every environment. On 2026-11-28,
the owner marked replay support ready for production, accepting the outstanding
verification gaps below as nonblocking follow-ups, and removed its feature gate.
The recorded measurements remain unchanged. Production deployment requires no
replay opt-in and remains a separate operation. Membership, controller authority,
HTTP grants and storage safeguards still apply.

Operational environment settings:

| Setting | Default |
| --- | --- |
| `REPLAY_UPLOADS_PER_ROOM` | 1 |
| `REPLAY_UPLOADS_PER_NODE` | 2 |
| `REPLAY_DISK_HEADROOM_BYTES` | 1073741824 |
| `REPLAY_STORAGE_DIRECTORY` | Private application-owned directory under the system temporary directory, isolated by environment/port |

Only point the storage directory at a dedicated ephemeral directory. Startup
removes its contents. Files and directory use modes 0600 and 0700. This is
single-node storage; do not mount persistent/shared storage. Reservations count
advertised bytes against actual free disk space before any body is read. Pending
reservations are conservative while a body is being written. There is no fixed
replay byte cap. Busy service (503), insufficient disk (507), storage failures
(503), malformed replays (422), stale selection (409), and admission failure (403)
are distinct responses.

The room supervisor uses `rest_for_one`: storage precedes validation tasks and
coordinators, so storage failure invalidates affected room epochs before startup
cleanup. Monitors reclaim files when requests or coordinators die. A periodic
sweep retries orphan cleanup. Accepted replay ownership transfers to the room,
not the uploader. Existing room maintenance enforces replay retention using only
playback and deliberate activity, separately from room abandonment expiry.

The browser pipeline provides session and CSRF protection for replay controller
routes. There is no LiveView `live_session`. Existing Hologram authentication
middleware is unchanged. A joined channel issues a five-minute HTTP grant bound
to room ID/epoch and seat ID/connection generation. Browser grants stay native.
Every HTTP request and publication revalidates membership; upload operations also
check controller, authority and playback revisions. Selection cancellation is
ordered through the coordinator; validation runs in cancellable supervised tasks.
Cancellation after publication leaves the accepted source in place.

Telemetry events contain bounded counts/codes, never bytes, HTTP grants or file
paths:

- `[:review_project, :replay, :upload_failure]`: `count`, finite reason code.
- `[:review_project, :replay, :preparation_failure]`: `count`; admitted channel
  reports are rate limited and do not extend retention.
- `[:review_project, :replay, :storage]`: active transfers, reserved bytes, stored
  bytes. Stored bytes includes staged bytes already written.
- `[:review_project, :replay, :cleanup_failure]`: `count`. Orphan sweeps retry.

## Parser and assets

The browser and server inspect the bounded raw Slippi element using the
[official format](https://github.com/project-slippi/slippi-wiki/blob/master/SPEC.md).
Optional UBJSON metadata is ignored rather than decoded into arbitrary declared
allocations. Events cannot cross their declared bounds. Required player settings,
pre/post pairs, indices, finite positional data and contiguous frames are checked.
Defeated doubles players may disappear after zero stocks. Rollbacks truncate
obsolete frames, including items/platform updates. Optional animation fields may
be absent even when a newer format version is advertised.

The worker is terminated on cancellation or after 30 seconds. Preparation includes
animation readiness under the same deadline. Parsed objects, fetches, renderers,
File objects and workers remain outside Hologram state. Local descriptors contain
opaque browser handles. Animation promises are deduplicated per preparation and
released with the replay. Renderer stores and teardown belong to each instance.

Asset provenance, pinned revision and license notices are recorded in
[the vendor README](../assets/vendor/slippi-player/README.md). In that directory:

```sh
npm ci --ignore-scripts --cache /tmp/slippi-npm-cache
npm run build
node build.mjs --check
```

Commit sources, lockfile, bundles and manifest together. Content hashes version
the same-origin worker/character URLs. Phoenix builds copy those manifest entries;
release smoke checks fetch all 27 assets, the manifest, notices and provenance record. Nested `node_modules`
are excluded from Docker context.

## Release checks and actual evidence

Run the native JS suite, focused Elixir tests and `mix precommit`. Run the
production Docker build and `scripts/staging_smoke.sh IMAGE`; it checks release
assets without deployment.

For local browser verification, create an isolated development database and use
`scripts/playback_fixture.exs` to create a synthetic login (no email). Build assets,
start Phoenix with that database, then run:

```sh
CHROME_DEBUG_URL=http://127.0.0.1:9447 APP_URL=http://localhost:4127 \
  PLAYBACK_FIXTURE=/tmp/review-replays-fixture.json \
  node scripts/replay_release_browser_test.mjs
```

The scenario covers anonymous local review with no replay HTTP, five participants,
active synthetic camera/microphone RTP, automatic following, preparation time,
absolute drift/spread, pause/seek, reload, invalid selection, replacement, handoff,
and end/replay. Reports go to `/tmp/replays-browser-report.json`; these are local
test artifacts, not replay libraries. The earlier two-person harness remains in
`scripts/slippi_browser_test.mjs` as a historical reference; use the new scenario for current integration checks.

Additional verification should identify versions of desktop Chrome, Edge,
Firefox and Safari, five participants with active conferencing, late joins,
reloads, background/foreground and transport recovery, replacement/failure/retry,
long replay/repeated replacement preparation and memory measurements. Preparation
is separate from the five-second recovery interval after transport/player
readiness. Sequential browser samples are reported-position measurements, not
frame-accurate presented-frame timing. Missing matrix entries remain unverified
follow-ups under the owner's 2026-11-28 production-readiness decision.

For mixed Chrome/Firefox verification, add MIXED_FIREFOX=1 and
FIREFOX_DEBUG_URL=ws://127.0.0.1:9448/session. Edge uses its own CDP endpoint
through CHROME_DEBUG_URL; the report records its actual Edg version.
ACTIVE_CONFERENCE=0 is available only for isolating replay compatibility; results
with that setting do not establish conferencing acceptance.

The standalone scripts/replay_solo_browser_test.mjs accepts REPLAY_BROWSER=chrome,
edge or firefox. LONG_REPLAY=1 exercises repeated ten-minute synthetic replacements
after running LONG_REPLAY_FRAMES=36000 node scripts/generate_replay_fixtures.mjs.
The generator writes the long replay only under /tmp; it is not a saved library.
Run node --expose-gc scripts/replay_preparation_benchmark.mjs for separate worker
measurements. Browser heap measurements use explicit CDP collection; Firefox does
not expose that measurement through this harness.

### Recorded results, 2026-11-27 (America/Chicago)

[Machine-readable evidence](validation/slippi-2026-11-27.json) records actual scope
and outstanding checks. On 2026-11-28, the owner accepted these gaps and marked
replay support ready for production. Safari, representative WAN/TURN,
physical-device and broader browser-role checks remain unperformed follow-ups.
Longer continuous playback is an additional confidence check with no agreed
minimum soak duration. This approval does not turn unperformed checks into
passing results or change other features' release requirements.

- `mix precommit`: 481 tests passed. Native JavaScript and asset checks: 54 passed.
  Clean pinned dependency installation plus bundle verification passed. All 26
  character archives matched the pinned upstream Git blobs. Production container
  build and disposable smoke passed, including notices/provenance delivery and
  the configuration checks present in that original build. No deployment occurred.
- Five-person rooms used real browser workers/renderers and active synthetic
  camera/microphone RTP. Each timing row contains 20 settled samples of all five
  participants; no application errors were recorded in the successful runs.

| Room composition | p95 absolute drift | p95 spread | Reload alignment after ready | Signaling alignment after ready |
| --- | ---: | ---: | ---: | ---: |
| Chrome 158.0.8127.36 × 5 | 0.046 s | 0.018 s | Not separately measured in this earlier run | Not exercised in this earlier run |
| Edge 158.0.4370.45 × 5 | 0.213 s | 0.189 s | 2.800 s | 2.877 s |
| Chrome × 4 + Firefox 160.0.1 × 1 | 0.190 s | 0.165 s | 1.531 s | 0.187 s |

The later harness confirms a player-generation change during signaling recovery;
it does not mistake an old ready player for completed recovery. Reload totals,
including transport and preparation, were 18.7 s, 28.7 s and 17.6 s respectively.
Those totals are distinct from the five-second interval after readiness. Successful
scenarios also covered anonymous solo/no replay HTTP, silent controls, automatic
following, pause/seek, actual background/foreground, late join, invalid selection,
replacement, uploader departure/handoff and end/replay. An earlier concurrent
Edge run timed out during preparation; it is not used as a passing result.

Solo source switching and invalid-file recovery passed in Chrome, Edge and Firefox.
For a 10,368,362-byte synthetic ten-minute replay with Ice Climbers and a character
transformation, four Node worker preparations took 1.09–1.25 s. RSS at result
delivery was 471–498 MB; post-GC heap was 4.57–4.65 MB while process RSS remained
438–453 MB. The allocator retaining RSS is not evidence of a browser memory ceiling.

Real-browser repeated long/short replacements took 3.8–11.3 s for the long replay
in Chrome and about 4.5 s in Edge, including test interaction and collection work.
After explicit collection, long-replay heap was about 93 MB in Chrome and 91 MB
in Edge; returning to the shorter replay returned heap to about 78 MB and 76 MB.
The JSON includes all measured preparations, including the larger Fountain fixture;
these are per-source observations, not a guaranteed replay size or memory limit.
Firefox passed the three-source solo corpus; this harness exposes no Firefox heap
measurement. Full ten-minute playback was not used for the settled timing rows.

Navigation cleanup has a regression test that releases parsed data and renderer
handles on pagehide even when the browser retains a document in its back-forward
cache. Storage tests cover reservations, simulated disk headroom exhaustion,
request/coordinator death, startup orphans, manager restart ordering, cancellation,
stale publication, revoked connections and temporary retention. Simulated headroom
exhaustion does not claim an actual filesystem-full stress test.

Restart the development server after rebuilding assets before browser verification.
A running Hologram manifest can otherwise reference a removed development chunk;
one post-build mount attempt hit this condition. Restarting against the matching
final assets resolved it, and the final solo/replacement smoke passed.
