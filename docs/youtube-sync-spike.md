# YouTube playback synchronization spike

Date: 2026-10-18. Scope: viability research point 2 under the
[first release contract](release-contract-v1.md).

This is a development-only experiment with a server-owned playback timeline and
real embedded YouTube players. It builds on the
[single-player spike](youtube-player-spike.md). It does not implement production
account ownership, host handoff, chat, conferencing, billing, or persistence.

## Shared-controls follow-up, 2026-11-20

**The native-control blocker was diagnosed and fixed in the prototype.** It was
an application race compounded by a buffering-state bug and a test-input bug,
not evidence that YouTube native controls cannot synchronize. The prototype
remains development-only. Its validated behavior is now integrated separately
into the production room workspace; see [shared video controls](rooms-backend.md#shared-video-controls)
for the Elixir policy, native adapter, and production verification.

### Confirmed causes and fixes

1. **Reconciliation undid native input before its command was acknowledged.**
   The trace recorded native Pause at 8362.9 ms, followed in the same pass by a
   corrective seek and Play against the old, still-playing revision. The server
   accepted Pause at 8363.9 ms. Subsequent corrective seeks repeatedly extended
   the callback-suppression window. Trusted ArrowRight input then moved the real
   paused video from 5.739608 to 15.739608 seconds, but the detector discarded that
   change during suppression and correction returned it to the old position.
   A pending native command now suspends inference and correction until its
   authoritative reply. A broadcast arriving before the reply cannot release
   that guard. Rejection/timeout requires a fresh snapshot instead of replaying
   the command. Regression tests cover all three orderings, including delayed
   replies across multiple timer ticks.
2. **A playing seek's temporary pause/buffering cleared its position intent.**
   Actual YouTube telemetry reported the position jump in a Paused event, then
   Buffering, then Playing. The detector discarded the jump on entry to Buffering.
   It now retains an observed seek through bounded buffering and commits the
   final stable position and playing state. Ordinary buffering recovery without
   an observed seek does not become a shared command. A regression test replays
   the captured pause/buffer/play sequence.
3. **The harness guessed the native Play button's position.** YouTube served
   compact embed controls with Play/Pause in the centre of this desktop Chrome
   player. The assumed bottom-left click did not activate Play. The harness now
   locates the actual desktop or compact button and records trusted pointer/key
   input and media events. Iframe DOM inspection is confined to the browser test;
   the application continues to use the official player API.

### Verification

A complete real-media run passed all six native-control scenarios: Pause,
paused Seek, Play, playing Seek, repeated scrubbing, and switching between native
and shared controls. The saved application trace contained five native intents
and **zero corrections between native intent and acknowledgement**. A separate
fresh-room native-only run and a second complete run also passed all six
scenarios: three consecutive fresh-room passes in total.

The final complete passing run used Chrome 157.0.8103.78 and Firefox 160.0 on
Linux, five participants, and at least 60 seconds per measurement:

| Scenario | p95 timeline drift | p95 participant spread | Correction seeks during measurement |
| --- | --- | --- | --- |
| Settled playback | 0.135 s | 0.109 s | 0 for every participant |
| Guest message delay configured to 250 ms each way | 0.137 s | 0.111 s | 0 for every participant |

The configured delay uses browser timers; background throttling increased the
actual snapshot round trips to 2,003–2,006 ms throughout the delayed measurement.
The harness requires an observed RTT of at least 450 ms before starting this
window and records per-participant RTT ranges. These are application-message
delays, not a physical network test. The preceding complete run also passed
both windows (p95 drift 0.158/0.160 s; spread 0.119/0.120 s), but its first two
delayed-window samples still held the earlier RTT; the stronger precondition
was added before this final run.

`mix precommit`: 320 tests passed. The deterministic Node suite passed 19 tests,
including the new session-ordering and buffering regressions. These supplement,
rather than substitute for, the real-media results.

### Reproduction and remaining boundaries

Opt in at `/dev/spikes/youtube-sync?native_controls=1&tight_sync=1`.
Without those options the historical behavior and tuning remain unchanged.
The native option is disabled for the ownership/access experiment; its handoff
protocol has not been integrated with this prototype. Sampling runs every 100 ms
and coalesces inferred input after 200 ms of stability. Callback suppression
lasts 1.2 seconds; ambiguous changes, hidden tabs and long scheduling gaps stay
local. Tight synchronization uses 0.2-second playing and 0.15-second paused
correction thresholds with a one-second seek cooldown. This remains heuristic
native-input inference, not proof of user intent for every provider interruption.

With HTTPS and the isolated Chrome/Firefox debugging profiles from the original
instructions running:

```sh
APP_URL=https://localhost:4001 \
  REPORT_PATH=/tmp/youtube-controls-gate.json \
  node scripts/youtube_controls_gate_browser_test.mjs
node --test --test-isolation=none scripts/youtube_native_policy.test.mjs \
  scripts/youtube_sync_session.test.mjs scripts/youtube_sync_policy.test.mjs \
  scripts/youtube_probe.test.mjs
```

Set `NATIVE_ONLY=1` for a fresh-room native-controls repeat without the two timing
windows; the report explicitly identifies that narrower scope. Reports include
application observations, pending intent/suppression state, native command
acknowledgements, correction calls, provider input/media events and raw samples.
Application trace retention is bounded to 2,400 entries and its DOM accessor is
removed on disposal. Finish build/precommit tasks and restart the server before
browser runs: Hologram environments share generated static assets.

Five tabs on one machine do not establish separate-device/network, Edge or Safari
coverage. Ads and broader recovery cases still need release verification.
The main workspace now implements the shared bar, production channel operation,
controller handoff, end/replay, and local audio controls. Production policy lives
in Hologram/Elixir with native resources in the provider adapter; it does not
import this JS prototype. No routes,
Phoenix pipelines, authentication scopes or LiveView sessions were added: the
spike uses existing development-only Hologram pages and its existing socket.

## Running the experiment

Use the HTTPS certificate and `mix holo` setup from the single-player write-up.
Restart the server after changing spike modules.
Also restart it after compiling production: the Hologram builds share generated
static assets, so a running development server can otherwise reference chunks
removed by the production build. Finish formatting/build checks before a browser
measurement run to avoid development live reloads replacing active players.

Open `https://localhost:4001/dev/spikes/youtube-sync`, create a research room, and
open its guest link in another tab or browser. Enable playback on each device.
Use the host's shared Play/Pause/Seek/Change video controls. The original player
controls affect only that device; local changes are reconciled with the room.

Invitation routes are `/dev/spikes/youtube-sync/room/:room`. Both pages are
development-only Hologram routes handled before the Phoenix router; they add no
Phoenix browser pipeline or LiveView `live_session`. The Channel socket at
`/dev/spikes/youtube-sync-socket` is mounted only in development/test builds.
The room worker starts alongside the existing development Hologram probes.

Creating a room grants that browser a random temporary host credential, stored
in its tab's session storage. Guest links contain only the room ID. The Channel
checks host credentials and membership on the server. These are experimental
identities, not authenticated accounts or an accepted guest identity design.
The host keeps its credential over a transport reconnect; no guest takes over
when it leaves. The later ownership/handoff spike must implement that contract.

For automated testing, start isolated Chrome and Firefox profiles with debugging
ports 9222 and 9223 using the single-player instructions. Keep normal autoplay
settings. Then run:

```sh
REPORT_PATH=/tmp/review-youtube-spike/sync-report.json \
  node scripts/youtube_sync_browser_test.mjs
```

Set `ONLY_MEDIA=1` to run a shorter two-Chrome-participant media fault/recovery
check. The full run additionally includes Firefox and the other scenarios.

This uses two Chrome tabs and a late-joining Firefox tab. It exercises real
YouTube media, browser HTTP/CDN latency, explicitly injected room-message delay,
out-of-order snapshots, background tabs, transport reconnection, and media-request
interruption. No SDK mocks or media downloads
are used. `APP_URL`, `CHROME_DEBUG_URL`, and `FIREFOX_DEBUG_URL` can be overridden.
Raw sample reports stay outside the repository; a summary of observed results
belongs below.

The research panel's one-way delay control holds outbound room requests and
inbound replies/broadcasts. At 250 ms each way, snapshot round trips must measure
at least 450 ms before the latency scenario proceeds. This is application-level
fault injection around real Channel traffic, not a physical network test.
Chrome's HTTP throttling alone did not delay its established WebSocket, which
is why those two mechanisms are tested and reported separately.

Other checks:

```sh
node --test --test-isolation=none \
  scripts/youtube_probe.test.mjs scripts/youtube_sync_policy.test.mjs
direnv exec . mix test test/review_project/sync_spikes/rooms_test.exs \
  test/review_project_web/channels/youtube_sync_channel_test.exs
direnv exec . mix precommit
```

## Synchronization strategy being tested

The coordinator serializes commands into a monotonic timeline: video ID,
playing/paused, position, timestamp, and revision. Play and Pause operate on the
server's position; clients cannot supply arbitrary positions with those commands.
Seek is explicit. Changing video resets its timeline to paused at zero.

Host commands carry an expected revision. Stale commands are rejected. Browsers
receive broadcast updates and request a fresh snapshot every two seconds, so
late joins and reconnects catch up from current state. Player callbacks never
publish room mutations; a local guest pause cannot become a global pause.

Each browser estimates server-clock offset from request midpoint timestamps,
preferring the lowest-RTT sample. Positions advance by the estimated elapsed
time since the server snapshot, rather than by time since its arrival. Client
and server calculations use monotonic clocks instead of wall-clock timestamps.
Older revisions and older same-revision samples are ignored.

The client checks its player every 500 ms. Experimental tuning:

- Correct playing drift above 1.0 second and paused drift above 0.35 second.
- Keep at least three seconds between routine drift-correction seeks.
- Suppress routine seeks while the player reports buffering.
- Allow a new explicit host seek to supersede a buffering operation once.
- Rate-limit transport retries and stop autoplay retries after a blocked event
  until a local click enables playback again.
- Pause locally when the room transport disconnects, then reconcile with a fresh
  snapshot after rejoining.
- Request a fresh snapshot on returning to a visible tab.

These are experiment choices, not accepted release policies. In particular, the
room timeline continues while one participant buffers; that participant catches
up after recovery. Whether the product should wait for slow participants remains
a decision to make from the evidence.

The harness uses provisional measurement gates of 1.5 seconds for settled p95
absolute timeline drift and pairwise position spread. It also checks correction
counts to detect repeated seeking. These gates do not establish the release's
numerical synchronization SLA.

Before collecting settled samples, the harness requires two continuous seconds
of playing state within the drift gate. A single playing event during seek
preparation is insufficient. Reports retain per-player state, exact player
position, expected position, revision, RTT, correction count, and raw sample
series. Command convergence timings include browser interaction/protocol
overhead; they are not pure one-way network latency measurements.

The room manager is single-node and in memory. It bounds the harness to 100
rooms/five connected channels per room and expires rooms after 30 minutes empty.
An occupied room has no elapsed-time cap. These resource bounds are not a
decision about production reconnection identities, tab counting, or empty-room
retention. Server restart loses experiment rooms.

## Verification results

**Result: the tested server-authoritative synchronization strategy is viable
for this prototype, with the interruption and environment limits below.**

The mixed-browser run completed 12 end-to-end scenarios with Chrome
155.0.8059.79 and Firefox 158.0 on Linux: shared Play, Pause, Seek and video change;
late join; guest-local pause correction; transport reconnect; delayed messages;
out-of-order updates; established background-tab playback; buffering observation;
and subsequent recovery. A separate, stronger two-Chrome media-fault run then
verified actual blocked requests and sustained buffering, rather than counting
an ordinary seek's buffering event as proof of an interruption.

Settled samples from the mixed-browser run:

| Scenario | Samples | p95 absolute timeline drift | p95 spread between players | Max absolute drift |
| --- | --- | --- | --- | --- |
| Two Chrome participants | 20 | 0.490 s | 0.209 s | 0.491 s |
| Firefox late join, three participants | 20 | 0.628 s | 0.535 s | 0.632 s |
| Guest with 250 ms each-way room delay plus HTTP latency | 20 | 0.096 s | 0.017 s | 0.096 s |
| Established guest tab in background | 12 | 0.112 s | 0.073 s | 0.113 s |
| Second video, three participants | 12 | 0.514 s | 0.086 s | 0.514 s |

Samples are taken nominally every 500 ms, plus protocol overhead. No additional
correction seeks occurred inside these settled sampling windows. This does not
mean no corrections occurred during joins, seeks, or recovery. The lower drift
in the delay scenario is an observation after settling, not evidence that
latency improves synchronization. Do not extrapolate these short runs into a
production SLA or a claim of frame-accurate playback.

Additional observations:

- The delayed guest measured a 505.2 ms snapshot round trip. Timestamp projection
  kept it aligned without replaying stale positions on arrival.
- Recorded command checks first converged in 0.19–2.05 seconds. Playing checks
  subsequently required two seconds of continuous stability; these are sampled
  test timings, including browser/protocol overhead, not production percentiles.
- The transport reconnect scenario took 4.25 seconds end to end, including an
  intentional 1.5-second interruption and the two-second stability confirmation.
  A host seek during the disconnect was recovered from a fresh snapshot.
- An older delayed update arrived after a newer seek and was ignored. It did not
  rewind the guest. Guest-local pause callbacks did not increment room revision.
- The background scenario confirmed `document.hidden == true` for the guest.
- In the focused media-fault run, the harness attached to YouTube's isolated
  iframe target and blocked five actual CDN requests. The guest remained
  connected, stayed at 960.001 seconds during four seconds of buffering, and its
  correction count stayed at two. Its lag therefore grew to 4.15 seconds while
  the room continued. After unblocking and a new host seek, first convergence
  took 1.10 seconds, followed by stability confirmation.
- No uncaught application errors occurred in the successful runs. Firefox
  reported four third-party cross-site cookie rejection diagnostics in the
  mixed-browser run; they did not prevent playback. Intentional blocked media
  requests are part of the focused fault test, not unexpected application errors.

Validation also passed:

- `mix precommit`: 119 tests, including six new room/Channel tests.
- Six Node test groups across the existing player facade and new synchronization
  policy. They cover projection, out-of-order samples, tolerance/cooldown, and
  explicit seeks during buffering; they do not substitute for real-browser tests.
- Production compilation with warnings as errors. Neither synchronization page's
  BEAM module is present in the production build; the spike socket's endpoint
  declaration is guarded by the development/test configuration.
- JavaScript syntax checks and `git diff --check`.

## Remaining viability limits

- Desktop Edge and Safari are unavailable here and remain unverified.
- Tests share one machine and a loopback server. Browser network emulation is
  useful evidence, but does not replace separate physical devices and networks.
- Initial headless Chrome playback could remain buffering when focus moved to
  another tab before its first frame. The successful harness lets the host's
  first frame start before activating the guest. Established background playback
  passed; reliable first playback in an already-hidden tab is not established.
- Ads, regional restrictions, consent/login states, and browser extensions need
  further observation. No supported ad-detection mechanism is assumed, and an
  interruption must not be mistaken for a shared playback command.
- Long-running live streams, playlists, end-of-video behavior, production
  persistence, server failover, and clock behavior across nodes are outside this
  experiment. Host selection/reclaim rules remain open in the release contract.
- Numeric release targets and the product's response to persistent buffering
  still require explicit decisions.

## Primary references

- [YouTube IFrame Player API](https://developers.google.com/youtube/iframe_api_reference):
  independent player state, buffering events, current-time sampling, seeking,
  and autoplay-blocked events.
- [Phoenix Channels](https://phoenix.hexdocs.pm/channels.html):
  join authorization, server-side channel processes, pushes, and reconnects.

This experiment controls only the supported embedded-player interface and keeps
the player unobscured. It does not capture, scrape, or rehost YouTube media.
