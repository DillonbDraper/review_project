# Conferencing implementation plan

Date: 2026-10-29. Status: steps 1–4 are implemented; public relay deployment,
supported-browser coverage, and the release verification gates remain outstanding. The [first release contract](release-contract-v1.md)
defines accepted scope. Technical choices below do not add product requirements.

## Current implementation

The real room channel now carries versioned, membership-authorized conference
state and SDP/ICE signals. A connected participant initializes receivers without
requesting devices. The workspace offers independent microphone/camera controls,
device-specific errors and cancellation, and a gesture to unlock remote audio.
Native media is held outside Hologram state, and device failures leave the room
and chat usable. Leaving, replacement, transport loss, and page removal dispose
native resources. Same-page outage recovery reacquires previously enabled devices after rejoining;
fresh loads and explicit leave start with devices off.

`ConferencePanel` now sits above the review player in the primary column, beside
chat. It renders one named square tile per connected seat, including self, before
media arrives. `ConferenceTiles` derives camera, microphone, and connection
presentation in Elixir. Off/unavailable video stays black; local preview is
mirrored and permanently muted. All video elements are muted, with remote sound
still played by the separate audio elements. The responsive grid wraps tiles
without expanding a lone tile to the player width.

Elixir binds native video elements in an action chained after the roster render.
Each seat keeps its video element across device changes, chat renders, and other
participants leaving. The binder moves the existing element if Hologram reuses
loop containers at different positions. Empty template containers preserve their
native children; no LiveView hooks or additional JS bridge APIs are needed.
Restored views validate the native element's kind and seat identity and recreate
released handles before binding the current stream.

Peer negotiation supports later device enablement on either side. Initial track
attachment uses `addTrack`, while subsequent changes use `replaceTrack`. Local
Chrome checks found that an implicit offer rollback could leave a live video
track with a detached native source. Rebinding that sender after the answer
commits restores delivery; a real-browser regression checks decoded frames and
RTP progress after simultaneous offers. Roster revisions prevent out-of-order
snapshots from recreating obsolete peers.

Conference orchestration now runs in client-side Elixir/Hologram. `ConferenceState`
handles roster/device policy, `ConferencePeer` serializes each peer's negotiation,
and `ConferenceBrowser` issues browser API calls. Pure state transitions emit
effects; native completions resume them. Neither a permission prompt nor an
outstanding peer operation blocks other device controls or peers.
`RoomPanel` sends admission, roster, signaling, pair replacement, and stop events
directly to `ConferencePanel` with targeted Hologram actions. Conference rendering
preserves the chained chat activation/reset and room polling actions. Start/stop
and device-resume decisions stay in Elixir; `room_browser.mjs` owns only the
transport and browser helpers, with synchronous native invalidation on transport
loss and document exit. The native bridge advances resource epochs beyond both
its document counter and the component's saved epoch when restoring a page.
This is more verbose than JS promises: asynchronous continuations are explicit
peer phases, which can be exercised as pure ExUnit transitions. Browser API calls
are kept in a separate Elixir module so those phases stay free of native objects.

The remaining JS bridge, `assets/js/conference_native.mjs`, manages native object
lifetimes and converts browser events/promise results to plain data and scoped
handle IDs. This boundary is deliberate for Hologram 0.12.1: its native-object
registry does not release entries, and an action awaiting a promise blocks later
actions on the same component. Passing every native event/object through raw
interop or awaiting `getUserMedia` directly would make cleanup and cancellation
fragile. Page exit and membership loss close resources immediately in JS, before
another Hologram action is required. Late capture results are stopped there too.
There is no conference policy or SDP/ICE sequencing in that bridge. The Chrome
rollback workaround remains in Elixir and is covered by the browser regression.

Public relay deployment, multi-hour soak, and the supported-browser matrix
remain outstanding. Recovery and same-page device restoration are now implemented;
see [conference networking](conference-networking.md) for policy, configuration,
and the known Firefox background-dispatch limitation. Existing
shared YouTube playback work is also separate.

## Outcome

Up to five people can talk and see each other while reviewing a YouTube video.
Joining succeeds with any combination of camera and microphone availability,
including neither. Every connected participant has a separate square tile above
the review player, with a black background when their camera is unavailable or
off. Local camera/microphone controls are included; controls for muting or
removing other people are deferred.

| Available local devices | Send | Receive | Own tile |
| --- | --- | --- | --- |
| Camera and microphone | Video and audio | Remote video and audio | Camera preview |
| Microphone only | Audio | Remote video and audio | Black |
| Camera only | Video | Remote video and audio | Camera preview |
| Neither, or permissions denied | Nothing | Remote video and audio | Black |

Receiving audio means playing remote audio when an output is available and the
browser permits playback; it never requires a local microphone. Devices are used
only after the participant enables them. Device failures must leave room
membership, chat, and the review player usable.

## Existing foundation and gaps

- `RoomSocket` and `RoomChannel` already authenticate the signed browser session
  and admit named invitation guests through `ReviewProject.Rooms`.
- At the start of this work, `Rooms.Session` supported targeted, size-bounded
  SDP/ICE signaling and a transient `media` flag, but `RoomChannel` did not expose
  these operations or forward `:room_signal`. Steps 1 and 2 replace the flag with
  transient conference readiness and independent device state and connect the
  real room transport to the browser adapter.
- `RoomPanel` handles join, roster, reconnect, replacement, and leave. Its
  browser adapter, `assets/js/room_browser.mjs`, owns the existing Phoenix
  channel. Extend this transport rather than opening a second membership.
- `WatchPage` renders `VideoPanel` beside chat. `VideoPanel` currently embeds
  YouTube with local playback; shared playback integration is separate work.
- The [mesh spikes](local-mesh-spike.md) and [manual device checks](manual-mesh-spike.md)
  establish a useful starting point. `mesh_capture.mjs` requests each device
  separately, but throws if neither works, waits for capture to finish, and
  `mesh_probe.mjs` requires a local stream before connecting. These restrictions
  must be removed in the workspace implementation.
- [Local TURN checks](turn-spike.md) were accepted. Production TURN configuration,
  public-network validation, Edge/Safari coverage, and the combined soak remain
  outstanding. Do not present spike acceptance as workspace release readiness.

## Proposed architecture

Keep the accepted browser-to-browser mesh: at five participants each browser has
four peer connections, making ten peer pairs. Phoenix transports membership and
signaling; camera and microphone media travel directly or through TURN. This work
does not need a new media server or Membrane integration.

Use the Hologram `ConferencePanel` and its Elixir state, peer, and browser modules.
Elixir/Hologram owns rendered state, device policy, roster reconciliation, API
sequencing, SDP/ICE decisions, and room lifecycle. JavaScript holds scoped native
objects, delivers event/promise results, and performs immediate disposal. Reuse
the spikes' useful mechanisms without importing their development-only page,
membership, chat, or playback implementations.

`RoomPanel` supplies admitted identity, snapshot, and lifecycle events to the
conference component, as it already does for chat. Conference signaling uses the
same `RoomChannel`. Keep `MediaStream`, tracks, peer connections, TURN credentials,
and DOM references out of serializable Hologram state. Hologram state contains
display/protocol metadata and opaque handle identifiers; descriptions are cleared
after each negotiation finishes. Native ICE configuration stays
in the browser adapter and is not persisted to storage or page snapshots.

No new HTTP routes or LiveViews are needed. `/rooms/:room_id` remains a Hologram
page with `UserAuth, :mount_current_scope`, so invitation guests can enter without
accounts. Phoenix router scopes, pipelines, and `live_session`s do not apply to
this page. Room membership and signaling remain authorized by `RoomSocket` and
`Rooms.request(current_scope, ...)` on the actual channel process. No user or
scope struct goes into browser component state.

## Delivery sequence

### 1. Connect admitted members to signaling

Extend `RoomChannel` with proposed `conference_state`, `conference_signal`, and
`conference_ice` requests and an outbound `conference_signal` event. Adapt the
existing `{:media, ...}`, `{:signal, ...}`, and `:room_signal` context operations;
keep existing membership, capacity, owner, and guest rules.

Track conference readiness separately from microphone/camera sending state.
Readiness becomes true after admission and native receiver initialization, even
when there are zero local tracks. Keep these fields transient in the coordinator;
this work does not require database migrations. Advertise camera/microphone
state for tile labels and black placeholders, resetting it on disconnect.

Expose each seat's existing `connection_generation` in the public roster and join
reply; the current channel strips it from the reply. Bind signaling to the room
epoch and current sender/recipient generations, and distinguish replacement peer
sessions within one membership. Derive sender identity on the server, reject
cross-room, departed, replaced, self-directed, malformed, and oversized signals,
and discard delayed SDP/ICE from obsolete peer sessions. Preserve current payload
bounds and add bounded signaling rates and candidate queues.

Deliverable: admitted members can exchange valid signals without acquiring any
devices, and a replaced tab cannot affect its replacement's conference.

### 2. Make capture optional and mesh negotiation reliable

Join the room and initialize receiving before asking for devices. Recommended
first interaction: show **Turn on microphone** and **Turn on camera** after joining;
these are independent controls and neither delays reception. This keeps restored
room entry from silently starting capture. An optional combined enable action
must still handle the two capture results independently.

Acquire microphone and camera separately, attach each successful track as soon
as it is ready, and report a device-specific warning and retry action for the
failed device. Do not await all device requests before connecting. A permission
prompt can remain unresolved indefinitely, so even an ignored prompt must leave
joining and reception usable. See [the browser capture API documentation](https://developer.mozilla.org/en-US/docs/Web/API/MediaDevices/getUserMedia).

Create peer connections for conference-ready members even with zero tracks.
The initial offer must contain receiving sections for both audio and video when
the offerer lacks those tracks. Test each asymmetric device combination in both
offer/answer orders. The spike already found that incorrectly pre-created
answerer transceivers could silently produce one-way media; preserve/revalidate
its `addTrack` association fix as negotiation is extended.

Use deterministic polite/impolite roles and serialized operations following the
[WebRTC perfect negotiation pattern](https://www.w3.org/TR/webrtc/#perfect-negotiation-example).
Handle offer collisions, queue ICE until the matching remote description, and
ignore candidates belonging to ignored or stale offers. Device enablement after
joining, track replacement, and ICE restart must work from either peer, including
updating transceiver direction when adding sending to a receiving-only session.

Local controls affect only the participant's own devices. Recommended camera-off
behavior stops its track, releases the camera, and publishes camera-off state;
microphone mute may use `track.enabled`. Retry or re-enable reacquires only the
needed kind and updates every peer, using `replaceTrack` where compatible and
renegotiating when necessary. Handle device removal and track `ended`/`mute`/
`unmute` events without dropping membership. Cancelled or stale capture results
must immediately stop any returned tracks.

Start with the spikes' conservative capture/bitrate settings as tunable defaults,
not promised quality targets. Verify real bidirectional media, not just ICE
connection state.

### 3. Put participant tiles above the review player

Place `ConferencePanel` directly above `VideoPanel` in the primary review column;
adjust the workspace grid so chat can remain alongside it. Use equal-size square
tiles (`aspect-ratio: 1 / 1`) with visible gaps and a black background. Show all
five in a row where space permits and wrap into rows on narrower desktop windows.
Do not make a lone participant tile expand to the full player width.

Render tiles from connected room membership, including self, before any `track`
event arrives. Label each with the display name and mark self as **You**. Use
stable seat-based IDs and ordering; do not reorder on speaking or media arrival.
Disconnected reserved seats can remain in the existing away roster, but do not
count as connected video tiles. No-video and camera-off tiles remain black with
the name/status visible; connecting and reconnecting get distinct status text.

Use stable media nodes so chat, roster, or status renders do not reset streams or
the YouTube iframe. Follow the existing Hologram native-DOM ownership mechanism;
do not introduce LiveView hooks into the Hologram page. Crop camera video within
the square using `object-fit: cover`, mute local preview permanently, and use
inline playback. Remote audio must continue playing when its visual video node
is hidden for a black tile; attach it to a persistent audio element and avoid
playing the same audio twice.

Attempt remote audio playback and show **Enable room audio** if the browser
blocks it. Retry from that direct user gesture, including after restoration or
when new peers arrive. Do not depend on a microphone permission grant to unlock
audio; see [browser autoplay handling](https://developer.mozilla.org/en-US/docs/Web/Media/Guides/Autoplay#handling_play_failures).
Include accessible device buttons, focus states, and concise connection/device
feedback. Manual checks must cover conversation while YouTube audio plays.

### 4. Complete recovery and TURN integration

Close obsolete peers on signaling loss and rebuild from the new epoch/generations
after admission is restored. Use a bounded recovery attempt with ICE restart
for failed network paths, then replace the affected peer session if necessary;
avoid retry loops for briefly disconnected peers. Rebuild only affected peers
where possible, without reloading the review player or resetting chat.

Accepted 2026-10-30: release capture on signaling loss, preserve the
participant's desired device settings in memory, and reacquire after the same
page rejoins successfully. Do not restore capture automatically after navigation
or a fresh page load. Surface any permission failure and remain receive-only.
This policy is recorded in the release contract.

Dispose tracks, peer connections, candidate queues, timers, listeners, and media
element attachments on explicit leave, room closure, tab replacement, logout,
page removal, and `pagehide`; recover cleanly on `pageshow` restoration. Stop local
capture immediately when Leave is clicked, even if its server acknowledgement
is delayed. Reject late capture and signaling callbacks after disposal.

Promote the spike's temporary TURN credential mechanism into a production module
and runtime configuration, independent of development flags and private-IP-only
validation. Issue/renew credentials only after validating the account session
and live membership. The `conference_ice` channel request uses the same
`Rooms.request` membership boundary as snapshots, with epoch/connection checks. Keep the shared secret
server-side. Credential failures must not refuse room admission; show conference
network status and allow retry. Use STUN plus authenticated TURN over UDP/TCP/TLS
with appropriate public DNS, certificates, and relay-port reachability.

Renew before expiry, apply the new ICE configuration, and exercise allocation
replacement/recovery over multiple credential lifetimes. Credential lifetime
must not become a room duration limit. Forced relay modes belong in test tools,
not the normal join flow. Public relay hosting and cost remain operational work;
local direct success is not sufficient for internet readiness.

## Verification and completion gates

Implement and verify in the sequence above, using small focused test files:

| Layer | Required evidence |
| --- | --- |
| Context/channel | Receive-only signaling; media-state updates; current generations; same-room targeting; bad/stale/rate-limited payloads; session revocation; no credentials for nonmembers. |
| Hologram | Named square tile for each connected seat; black placeholder without camera; independent device controls; device errors preserve joined state; stale callbacks ignored; player and chat survive updates. Use rendered DOM selectors. |
| Client Elixir | Independent successful/failed/pending capture; roster/generation guards; serialized negotiation; candidate bounds; offer collisions and post-answer rebind ordering. Pure ExUnit transitions exercise these without browser fakes. |
| Native bridge | Scoped handles, late capture disposal, borrowed-track ownership, event projection, promise failures, and immediate cleanup. Use browser API fakes for these lifetime boundaries. |
| Two real browsers | All four device combinations, denied/missing/busy devices and ignored permission prompts; microphone-only versus camera-only in both offer orders; later enabling either kind; intelligible remote audio and advancing video. |
| Five participants | Ten peer pairs; four remote tiles plus self per browser; actual inbound/outbound media where expected; capacity rejection for a sixth; no local echo or duplicate audio. |
| Recovery | Reload, disconnect/rejoin, device removal, another tab taking the seat, host departure/return, logout, and navigation. No ghost peers, duplicate tiles, active leftover capture, or broken chat/review player. |
| Networks and duration | Separate networks; forced TURN UDP/TCP/TLS; blocked UDP; network change; multiple credential renewals; repeated churn and a multi-hour soak. Record relay traffic/cost observations. |

Extend `scripts/rooms_browser_test.mjs` or add a focused conferencing harness for
the real workspace rather than reporting only spike-page results. Run with
normal autoplay restrictions as well as fake-device automation. Independently
inspect native tracks/connections after cleanup, and check frame/packet progress
in the directions expected from each device combination. Synthetic packet counts
do not establish audio intelligibility; use real devices and people too.

Run `mix precommit` after implementation and appropriate Node/browser checks for
the adapter and harness. Restart the development server after checks when needed
because Hologram dev/test asset paths overlap. Demonstrate the workspace in current
desktop Chrome, Edge, Firefox, and Safari; record untested combinations explicitly.

The initial workspace milestone is complete when two admitted participants can
see/hear the available media and receive-only joining works. Conferencing is
release-ready only after the five-person, supported-browser, public TURN,
recovery, and soak gates pass. Shared YouTube synchronization remains a separate
release requirement; its incomplete workspace integration must not be reported
as solved by conferencing.
