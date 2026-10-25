# Local five-person mesh spike (3A)

Date: 2026-10-18. Scope: local functional feasibility under the
[first release contract](release-contract-v1.md), building on the
[YouTube synchronization spike](youtube-sync-spike.md).

## Result and evidence boundary

**The five-person mesh works in the tested local Chrome/Firefox setup.** Each
participant exchanges camera video and microphone audio with four peers while
using shared YouTube playback and chat. This is evidence to proceed to physical
device and network testing, not release readiness or a decision to deploy this
research harness as the room implementation.

The test uses four Chrome tabs and one Firefox tab on one Linux workstation,
synthetic camera/microphone devices, real browser WebRTC encoders/decoders, and
real embedded YouTube players. All conference playback elements are muted to
avoid local feedback. Audio packet delivery is verified; intelligibility, echo,
mixing, microphone quality, and conversation over YouTube audio are unverified.
Desktop Edge and Safari remain deferred because they are unavailable here.

## Implementation and research choices

- Development Hologram routes: `/dev/spikes/youtube-mesh` and
  `/dev/spikes/youtube-mesh/room/:room`. They use `SpikeLayout` and Hologram's
  router before the Phoenix router, with no new Phoenix browser pipeline,
  authentication scope, or LiveView `live_session`. The page modules compile
  only with the existing development `:hologram_spikes` flag.
- The existing development/test-only `/dev/spikes/youtube-sync-socket` carries
  membership, directed SDP/ICE signaling, chat, and authoritative playback.
  Audio/video travels directly between browsers, not through Phoenix. No new
  dependencies, media server, STUN server, or TURN server were added.
- Five connected Channel processes per room, including host. IDs are generated
  by the server, and signaling requires both sender and recipient to be current,
  media-enabled members of the same room. Caller-supplied sender identities are
  ignored. SDP and ICE payload sizes are bounded. The sixth join is rejected.
- A full room has ten peer pairs, represented by twenty native
  `RTCPeerConnection` endpoints: four per participant. A deterministic ordering
  of peer IDs chooses one offerer per pair. Native `addTrack` attaches media;
  candidates wait for a remote description when necessary.
- The initial experiment exposed one-way media despite connected ICE: using
  pre-created `addTransceiver` entries on the answerer left outgoing tracks
  unassociated with the offered sections. Using `addTrack` allowed the answerer
  to reuse the matching transceivers. Passing gates require actual inbound and
  outbound media progress, rather than a connected status alone.
- Experimental video target: 320 × 180 at 15 fps, preferring VP8. Per-sender
  bitrate ceilings are 250 kbps video and 32 kbps audio; these are ceilings,
  not reservations or measured requirements. Browser capture negotiation and
  encoder behavior may vary. These are research settings, not accepted product
  quality or bandwidth targets.
- Camera/microphone toggles set `track.enabled`; they preserve connections and
  keep capture devices open. Stop media ends local tracks, closes peer
  connections and detaches video elements. Restart acquires new tracks.
- A transport interruption closes peer connections but deliberately keeps local
  capture and preview active. Rejoining receives a new server identity and
  rebuilds the mesh. Explicit Leave, page removal, or page exit disposes the
  capture, connections, timers and player. This temporary reconnect behavior is
  a research choice requiring a product decision before production.
- Chat uses the same ordered server transport, server-assigned authors and
  sequence numbers, text-only DOM rendering, a 1,000-byte trimmed message limit,
  and the latest 50 messages held in memory. Rejoining receives that history.
  These limits do not settle release chat retention, persistence or moderation.

Rooms and messages disappear on server restart. The prior research limits of
100 rooms and expiry after 30 minutes empty remain; occupied rooms have no
elapsed-time cap. Temporary host tokens, per-connection identities and channel
counting do not implement authenticated ownership, guest display names,
reconnection identity, multiple-tab rules or host-absence control handoff.
The [release contract's open decisions](release-contract-v1.md#decisions-still-open)
remain open.

## Reproduction

Use the PostgreSQL, temporary localhost HTTPS certificate and `mix holo` setup
in the [single-player instructions](youtube-player-spike.md#run-locally).
Restart `mix holo` after spike changes. Complete formatting/build checks before
browser measurements to avoid live reload. Production compilation shares the
Hologram static output, so restart the development server after a production
build before running browser probes again.

Launch isolated browsers with synthetic capture and normal autoplay settings:

```sh
mkdir -p /tmp/review-mesh-spike/firefox-profile
cat > /tmp/review-mesh-spike/firefox-profile/user.js <<'PREFS'
user_pref("media.navigator.streams.fake", true);
user_pref("media.navigator.permission.disabled", true);
PREFS

google-chrome-stable --headless=new \
  --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222 \
  --user-data-dir=/tmp/review-mesh-spike/chrome-profile \
  --no-first-run --no-default-browser-check \
  --use-fake-device-for-media-stream --use-fake-ui-for-media-stream about:blank
```

In another terminal:

```sh
firefox --headless --no-remote \
  --profile /tmp/review-mesh-spike/firefox-profile \
  --remote-debugging-port 9223 about:blank
```

Then run with Node.js 24; no npm installation is needed:

```sh
REPORT_PATH=/tmp/review-mesh-spike/report.json \
  node scripts/youtube_mesh_browser_test.mjs
```

`APP_URL`, `CHROME_DEBUG_URL`, and `FIREFOX_DEBUG_URL` can be overridden. The
browser adapter accepts the self-signed localhost certificate. Synthetic devices
and automatic capture permission are test settings; real permission prompts,
permission denial, missing/busy devices and hardware changes remain unverified.
The script waits for each player's first frames before moving browser focus,
retaining the initial hidden-tab caveat found in the earlier YouTube spike.

To inspect manually, create a room at the mesh route, open the guest links,
enable YouTube playback on each participant, and click Start camera and
microphone. The research measurements include native peer state, track state,
decoded frames, packet counters, selected candidate types and available
`getStats()` fields. Muted conference elements are intentional in this probe.

## Browser checks and observed measurements

Chrome 155.0.8059.79 and Firefox 158.0 completed the following checks:

1. Five participants form ten bidirectional peer pairs. Each endpoint receives
   both live audio/video tracks, audio packets, decoded video, and advancing
   native video playback; inbound/outbound counters advance across measurements.
2. Shared YouTube playback runs alongside conferencing. Shared pause, seek and
   resume are checked with all five participants exchanging media.
3. Host and guest messages reach all five in the same order. Markup in a chat
   message remains text and creates no image element.
4. A sixth participant is rejected without expanding the mesh.
5. Microphone/camera toggles preserve existing peer connections.
6. Stop media ends native capture tracks and closes connections; restart
   restores the complete mesh.
7. Disconnect/reconnect removes the old peer identity, restores media and
   returns chat history without leaving stale peers.
8. Explicit leave releases native resources. Abrupt guest-tab closure removes
   its peers and frees a slot. New guests restore five-person operation.
9. Final Leave on every participant closes all independently observed native
   peer connections, ends all acquired tracks and detaches media elements.

Native browser instrumentation independently retains references to created peer
connections and acquired tracks for the resource checks. The app's own peer count
alone is insufficient to pass cleanup. There were no uncaught application errors
in the successful full run. This is a short functional test, not a leak soak.

Measurement windows use RTP byte/frame counter differences, nominally ten
seconds before churn and six seconds after it. Statistics are collected roughly
once per second; derived rates are approximate. RTP rates exclude packet headers,
transport overhead, signaling, YouTube traffic and future TURN overhead. They
are not internet connection-speed requirements or billing estimates.

Observed in the final successful full run (all ten scenarios passed):

| Measurement | Before churn | After churn |
| --- | --- | --- |
| Connected peer endpoints | 20 | 20 |
| Decoded fps per incoming video | 14.4–15.0 | 14.7–15.0 |
| Aggregate outbound RTP per participant | 356–618 kbps | 352–621 kbps |
| Aggregate inbound RTP per participant | 540–610 kbps | 540–600 kbps |
| Reported additional lost packets | 0 | 0 |
| Selected candidate RTT | 0 ms | 0–1 ms |
| Absolute YouTube timeline drift at end sample | 0.10–0.56 s | 0.10–0.46 s |

The drift values are endpoint observations, not p95 synchronization measurements.
All observed selected candidates were host candidates, consistent with the
same-machine topology. Near-zero RTT and no observed loss provide no evidence
about NAT traversal or ordinary network conditions. Synthetic video complexity,
muted audio and desktop scheduling make these numbers unsuitable for ordinary
laptop CPU, thermal or battery predictions.

Raw machine reports remain outside the repository under the chosen `REPORT_PATH`;
this write-up preserves the scope and summary. Reports include local capture
settings, so review them before sharing externally.

## Other checks

- `mix precommit`: 123 tests pass, including new room and Channel mesh coverage.
- Six JavaScript test groups across player handling and synchronization policy
  pass, plus syntax checks for the mesh, sync facade and browser harness.
- Production compilation with warnings as errors passes. Neither mesh page nor
  the mesh panel is present in the production BEAM output; the existing socket
  declaration remains guarded by the development/test setting. This check ran
  after browser testing because of the shared static-output behavior above.

## Remaining spikes and practical next step

**3B: physical-device conferencing — accepted as successful, 2026-10-24.**
The project owner reported successful manual home-network testing, including
guest camera operation, and explicitly closed the viability spike. See the
[manual 3B report](manual-mesh-spike.md) for the acceptance and evidence limits.
Full device/browser coverage and sustained quality/performance still belong in
release validation; do not infer an unrecorded five-device matrix or numeric SLA.
The local TURN stage of spike 4 was subsequently tested and accepted by the
owner; see the [TURN report](turn-spike.md). The next distinct local research
spike was 5, now complete and accepted in the
[ownership/handoff harness](ownership-spike.md).
Public-network and cost validation from spike 4 remains open.

**4: network/TURN viability and cost.** Test separate LANs, restrictive networks,
UDP failure and forced relay. Verify ICE recovery, loss/latency behavior, actual
relay traffic and a budget for free rooms. No external reachability or TURN claim
is established by this local test.
Local coturn setup and manual transport-mode checks are now accepted; this
remaining work concerns external reachability, restrictive networks and cost.

**5: access, ownership and host-absence playback control — complete and accepted,
2026-10-24.** The owner selected the handoff and seat policies in the release
contract. The new
`/dev/spikes/room-access` harness verifies authenticated ownership, named guests,
reservation/admission, handoff and reclaim. The owner explicitly accepted the
manual test and closed this spike. See its separate report for browser evidence
and remaining limits. Earlier pages keep their token-host fixtures.

**6: combined multi-hour soak.** Exercise real devices/networks, playback, media,
chat and repeated reconnects together. Track memory, leaked media resources,
background behavior and recovery over sessions without an application time cap.
This is the next distinct local research spike. External-network and cost work
from spike 4 remains open alongside it.

## Primary references

- [W3C WebRTC specification](https://www.w3.org/TR/webrtc/): peer connections,
  transceiver association, track attachment and closure.
- [W3C WebRTC statistics](https://www.w3.org/TR/webrtc-stats/): RTP counters,
  decoded frames, encode timing and candidate-pair observations.
- [MDN negotiation guidance](https://developer.mozilla.org/en-US/docs/Web/API/WebRTC_API/Perfect_negotiation):
  negotiation roles and handling offer races.
