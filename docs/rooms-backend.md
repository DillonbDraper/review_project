# Rooms backend

The backend implements the accepted room data model with durable messages named
`chat_room_messages`. It adds `rooms`, `room_invitations`, `room_seats`, and
`chat_room_messages`, Ecto schemas, the `ReviewProject.Rooms` context, and a
supervised coordinator for each active room. The original backend change added
no user schema, auth flow, web routes, client UI, or browser media implementation.
The workspace now integrates room admission, chat, direct conferencing, and
shared YouTube playback as described below. Public TURN deployment remains a
separate task.

## Authentication integration

The room migration references the existing bigint `users.id`. Current main's
`20260626214110_create_users_auth_tables.exs` migration creates the users table
before the room migration. There is no placeholder users table or separate
authentication implementation in the room backend.
The ownership FK restricts deletion: an account deletion workflow must explicitly
delete its owned rooms before deleting the account. Room deletion cascades to
invitations, seats, and chat, so retention consequences belong in that workflow.

Pass the verified `%ReviewProject.Accounts.Scope{user: user}` supplied by the
merged authentication implementation. Guests pass nil. The scope is a trusted
server boundary, not an object to construct from request parameters.
Room-specific display names live on seats; no account profile columns are needed.

The transport layer must:

1. Resolve and revalidate the authenticated account from the actual session.
   Derive its logout disconnect ID using the auth branch's existing mechanism.
2. Generate a random browser identity of at least 16 bytes of entropy and store it
   in the signed browser session. Reuse it across tabs. Serialize fresh-session
   bootstrap across tabs, as in the accepted ownership spike; the domain does not
   accept an IP address, display name, or client-selected account ID as identity.
3. Supply that identity and the invitation when joining. Owner recovery requires
   the authenticated owner scope and does not require an invitation.
4. Join/request using the actual channel PID (`self()`), never a PID supplied by
   the client. A new tab takes the browser's existing seat, invalidates the old
   PID, and receives a new connection generation. Never register multiple local
   coordinators for the same room.
5. Terminate the channel on logout/session revocation. Its monitored exit starts
   the normal owner-absence or guest-reservation behavior.
6. Forward coordinator notifications, stop the old channel/capture/peer resources
   on replacement or closure, and render chat bodies as escaped plain text.
   Only issue/renew TURN credentials after a successful membership check, such
   as a successful `Rooms.request(current_scope, room_id, :snapshot)`.

Socket authentication should reuse the merged `ReviewProject.Accounts` and
`ReviewProjectWeb.UserAuth` implementation. A successful `:snapshot` checks room membership;
it does not replace account-session validation in the transport.

## Context API

```elixir
alias ReviewProject.Rooms

{:ok, %{room: room, invitation_token: invitation}} =
  Rooms.create_room(current_scope, %{name: "Friday watch party"})

{:ok, joined} =
  Rooms.join_room(current_scope, room.id, browser_identity, invitation, "Alice")

{:ok, message} = Rooms.send_message(current_scope, room.id, %{body: "Hello"})
{:ok, history} = Rooms.request(current_scope, room.id, {:history, [limit: 50]})
{:ok, older} = Rooms.request(current_scope, room.id,
  {:history, [limit: 50, before_sequence: hd(history).sequence]})

snapshot = joined.snapshot
{:ok, updated} = Rooms.request(current_scope, room.id, {:control, %{
  "op" => "video",
  "video_id" => "M7lc1UVf-VE",
  "epoch" => snapshot.epoch,
  "revision" => snapshot.revision,
  "authority_revision" => snapshot.authority_revision
}})
```

Only request an older page when the current page is nonempty. Playback commands
are `video`, `play`, `pause`, `seek` (with `position` in seconds), and
`set_playback` (an atomic `position` and boolean `playing`). Every command
uses the latest snapshot's epoch, playback revision, and authority revision. The
server checks controller identity before changing shared state. Raw native player
callbacks are observations; only stabilized, controller-authorized intent may
become a shared command.

Other requests are `:snapshot`, `:leave`, `{:media, state}`, and
`{:signal, envelope}`. The workspace channel exposes the latter two as
`conference_state` and `conference_signal`. Conference state includes the room
`epoch`, the seat's `connection_generation`, and boolean `ready`, `microphone`,
and `camera` fields. Ready means the receiver is initialized, even without local
devices. Changing readiness advances a transient conference generation; device
toggles do not. Join replies and public seats include the connection generation,
and each seat exposes its conference state. A monotonic `roster_revision` prevents
older request acknowledgements from rolling back newer conference rosters.

Signal envelopes include `epoch`, `connection_generation`,
`conference_generation`, `to`, `to_connection_generation`,
`to_conference_generation`, `peer_generation`, and `data`. Data is a size-bounded description or ICE
candidate with a `negotiation_id`; descriptions are only offers/answers. The
server derives `from`, checks both endpoints' generations and readiness, and
allows at most 256 valid signals per member per 10 seconds. Signals only reach
current connected conference-ready seats in the same room; local device access
is not required. Notifications are
`{:room_state, snapshot}`, `{:room_chat_message, message}`, `{:room_signal, signal}`,
`{:room_seat_replaced, reason}`, `{:room_left, reason}`, and `{:room_closed, reason}`.
Public snapshots expose random seat IDs, not account IDs or browser identity hashes.

`RoomChannel` forwards `:room_signal` as `conference_signal`. `ConferencePanel`
uses client-side Elixir: `ConferenceState` owns devices and roster reconciliation,
`ConferencePeer` serializes SDP/ICE negotiation, and `ConferenceBrowser` sequences
browser API calls. `assets/js/conference_native.mjs` holds scoped native handles,
projects browser events, reports promise completions, and disposes resources
synchronously when membership or the page ends. `ConferenceTiles` derives the
named square tiles from connected membership; Elixir binds scoped video elements
after rendering, independently of persistent remote audio. Runtime ICE credentials
and bounded recovery are implemented; public relay deployment and verification
remain release gates in the [conferencing plan](conferencing-plan.md).

Owner-only APIs are `list_rooms/1`, `get_room/2`, `rotate_invitation/2`,
`close_room/2`, and `list_messages/3`. Existing guests retain their seats after
invitation rotation; future guest admissions/reconnects require the new token.
Invitation raw tokens are returned at issuance only. An owner who loses a token
can rotate it. Closure disconnects the live session and disables new admission,
but preserves chat for the owner.

## Persistence and live lifecycle

The owner's slot is always reserved; four guest slots remain available.
Disconnected guests keep identity and join order for 30 seconds. Explicit guest
Leave releases immediately. After 10 seconds of owner absence, the earliest
connected guest takes playback control. Later guest succession is immediate;
an earlier guest reconnecting does not displace the existing guest controller.
The owner automatically reclaims on return from any authenticated browser.

Room-row locks serialize seat allocation and durable message ordering. Fixed
slots and unique indexes enforce capacity and browser-seat uniqueness. Messages
capture sender identity/name on the server; clients can submit only their body.
Cross-room sender references are rejected by a composite FK. Deleting an expired
seat nulls the message's seat reference and preserves its name snapshot.

Messages are immutable, nonblank text up to 2,000 characters. Joined guests can
read prior messages; nonmembers cannot read guest history. Owners can read history
without joining, including after closing a room. The latest 50 are included on
join, with backward pagination of at most 100 per request. There is no automatic
age-based deletion, empty-room expiry, or session-duration limit.

The coordinator is single-node. Registry provides one coordinator per room on
that node; this is not a distributed lock/failover implementation. Monotonic time
controls live deadlines and playback projection. UTC reservation metadata permits
recovery without restoring old monotonic anchors or PIDs. Following a coordinator
restart, previously connected guests receive a 30-second reconnect reservation;
existing reservations keep their deadlines. Room identity, seat identity within
its reservation, and chat survive; playback starts unselected/paused, authority
resets, all transports rejoin, and a fresh epoch invalidates old commands. The
owner's absence grace begins again for the new coordinator incarnation.

## Shared video controls

The production `VideoPanel` provides source selection, Play/Pause/Replay,
elapsed/duration, seek preview with a 200 ms debounced commit, and local volume
and mute below the unobscured official YouTube player. It also works locally
before room admission. Individual prerecorded videos and Shorts are supported;
video links with playlist context select that video only. Playlist-only input
and explicit live links are rejected without replacing the current player.
Live metadata reported by the SDK disables playback with an explanation.
Uploads and other providers remain deferred by the release contract.

`PlaybackState` owns the client timeline, authority checks, correction policy,
pending commands, local preferences, and recovery in Elixir. `PlaybackIntent`
conservatively infers controller input from normalized observations: foreground
iframe focus, position discontinuities, stable transport state, and seek buffering.
Only SDK calls create an expected response (position and/or transport mode).
Matching responses clear that expectation immediately; a different position can
supersede it as new input. Expectations expire after five seconds so failed SDK
calls cannot block recovery indefinitely. Accepting a native action or receiving
its room acknowledgement does not start an input-suppression timer.
Ambiguous events and follower actions reconcile locally. End-of-video commits a
paused timeline at duration;
Replay atomically starts from zero. The final frame can precede the SDK duration,
so ended players are not repeatedly corrected for that small difference.

`assets/js/playback_native.mjs` owns the SDK, iframe, timers, DOM lifecycle, and
normalized primitive samples. `assets/js/youtube_api.mjs` shares on-demand SDK
loading with the research facade; production does not import spike policy.
The iframe remains stable through ordinary controls and source validation.
Readiness requires the selected source to finish cueing, rather than just the
SDK's `onReady`. Errors, autoplay blocks, and buffering stay local, with enable
and retry controls. Navigation, room replacement, logout, and connection loss
suspend playback immediately; generations discard late callbacks. Brief room
recovery preserves local audio and enable preferences. Explicit leave requires
enabling playback again after joining.

The existing room channel accepts `control` with the authenticated scope,
membership, controller identity, epoch, playback revision, and authority revision
checks already enforced by the coordinator. Source resolution does not mutate a
room. RoomPanel forwards join/roster/stop events to playback while preserving the
conference and chat action chain, including explicit continuation targets.
No new routes, Phoenix pipelines, scopes, or `live_session` blocks are needed.
The existing Hologram pages retain `UserAuth, :mount_current_scope`; protected
room operations continue through `RoomChannel` session/membership validation.

Timed snapshots poll every two seconds. Midpoint clock calibration uses the
lowest observed round trip; browser monotonic time projects the shared timeline.
Fresh snapshots never correct against an old player observation. Position
display is anchored no earlier than the snapshot timestamp. Samples queued for
more than 500 ms are discarded. Correction tolerances are 0.2 seconds playing
and 0.15 seconds paused, with a one-second seek cooldown and buffering guards.
Hidden muted tabs defer corrections, then request a fresh snapshot and catch up
when visible. Inferred commands suspend correction until their acknowledgement;
newer native input continues to be observed and coalesces to the latest intent
while that command is in flight. It submits against the acknowledged revision,
before correction can roll it back. Source/authority changes and lifecycle resets
discard this queued input. Rejection requires a new snapshot, with no blind
command replay. Delayed seek
commits carry the displayed generation and revisions so they cannot cross a
source or authority change.

Native seeks retain the intended playing state from before the seek, including
through temporary Paused/Buffering states and buffering longer than five seconds.
Once a seek settles at a paused frame, a previously playing timeline resumes it
locally; a previously paused timeline stays paused. Application seek requests
also bypass the next routine correction interval so their first SDK seek is
issued on the next fresh sample.

### Browser verification

`scripts/playback_native_interaction_browser_test.mjs` covers immediate native
Pause/Play, a second seek immediately after the first is accepted, a seek burst,
and seeking while paused on the standalone page. It deliberately exercises the
old 1.2-second suppression window. Its Chrome path also performs real native
progress-bar seeks with delayed media delivery, requiring actual position jumps
and buffering, then playing-state recovery without an application-issued Pause.
It records SDK samples and application commands in its JSON report without
changing application playback policy. Firefox covers the rapid keyboard cases.

```sh
APP_URL=https://localhost:4461 REPORT_PATH=/tmp/playback-native-chrome.json \
  node scripts/playback_native_interaction_browser_test.mjs
BROWSER=firefox APP_URL=https://localhost:4461 REPORT_PATH=/tmp/playback-native-firefox.json \
  node scripts/playback_native_interaction_browser_test.mjs
```

The helper uses the same browser debug ports as below; override them with
`CHROME_DEBUG_URL` and `FIREFOX_DEBUG_URL` when using other local ports.

`scripts/production_playback_browser_test.mjs` exercises the actual workspace,
login/admission, room transport, real YouTube media, native trusted input,
local audio, stable iframe, end/replay, ten-second handoff, returning-host reclaim,
chat, and conference roster. Its full run adds three independent browser
identities for five participants across Chrome and Firefox, checks visibility
recovery, and collects at least 120 settled samples over 60 seconds. One
participant delays both WebSocket directions by 250 ms; the harness verifies
the resulting snapshot round trip and asserts p95 timeline drift and spread
at most 0.5 seconds, with bounded corrections. Buffering/recovery is recorded
separately rather than counted as settled playback.

Use an isolated development database and a local HTTPS server with Hologram
enabled. Refresh the one-use local login fixture before each full run; it sends
no email and only reuses its own `playback-…@example.test` account:

```sh
PGDATABASE=review_video_controls_dev mix run --no-start --no-compile scripts/playback_fixture.exs
APP_URL=https://localhost:4441 REPORT_PATH=/tmp/production-playback-room.json \
  node scripts/production_playback_browser_test.mjs
```

The browser helper expects Chrome CDP on port 9222 and Firefox BiDi on port 9223.
`SOLO_ONLY=1` or `CORE_ONLY=1` restricts the run and does not establish the
five-participant target. Finish build checks before browser checks: Hologram
environments share generated assets, so compiling another environment during a
run invalidates its loaded chunks. Restart the app after switching builds.
Same-machine Chrome/Firefox checks do not establish Edge/Safari coverage,
separate-device network behavior, ad/live metadata edge cases, public TURN, or
the complete multi-hour release soak.

The full production-page run on 2026-11-20 passed all 14 checks with five
participants (three Chrome, two Firefox), 120 settled samples over 60.845 seconds,
**0.176 s p95 timeline drift**, **0.148 s p95 participant spread**, and **zero
corrective seeks for every participant**. The delayed participant's measured
snapshot round trip was 501.1–501.2 ms. No buffering interruptions occurred during
that measurement. A previously hidden muted guest aligned in 209 ms after
visibility return. These results meet the scoped local timing gate; they are
not separate-device or full release certification. An earlier development run
reported local YouTube error 5; its cause was not established, and the successful
run does not imply that provider failures cannot occur.

## Checks

Use the normal project database setup and `mix precommit`. Room tests use the
real account fixtures and `%Accounts.Scope{user: user}`. To use an isolated test
database, set the optional database override before running checks:

```sh
export ROOMS_TEST_DATABASE=review_project_rooms_rebase_test
# Set PGPORT if using a separate PostgreSQL test instance.
mix precommit
```

The test alias creates the database and runs both account and room migrations.
The temporary users-table bootstrap used before auth was merged has been removed;
use a fresh database if you previously used that standalone fixture.

Tests cover atomic room creation/ownership, invitation replacement, SQL constraints,
five-seat races, shared-browser replacement, guest reconnect/expiry, owner handoff
and reclaim, stale commands, targeted signaling, durable/paginated chat, concurrent
message order, coordinator recovery, closure, and the public context boundary.
They use supervised processes and an injected clock rather than sleeping through
the 10/30-second deadlines. Playback tests also cover clock projection, stale
snapshots and generations, pending native commands, buffering, end/replay,
seek previews, local preferences, background recovery, and unauthorized/stale
channel commands. The browser checks above cover a local Chrome/Firefox path;
full desktop-browser coverage, public TURN networks, and the combined multi-hour
soak still need release verification.


## Conference recovery and ICE

`conference_ice` (`{:ice, params}`) checks the live channel membership, account
session, room epoch, and connection generation before issuing temporary TURN
credentials. It works before device readiness; neither a missing relay nor a
failed credential request blocks admission/chat. Six requests per ten seconds
are allowed per seat. Shared secrets stay server-side and temporary credentials
are held behind scoped native handles rather than saved Hologram state.

`conference_reset` (`{:reset_peer, envelope}`) checks both live, ready members and
all connection/conference generations. Each pair has a server-coordinated
`peer_generation` starting at zero. A successful reset increments it and sends
`conference_peer` to both endpoints. The expected old pair generation makes
simultaneous reset requests converge on one replacement. Every signal must carry
the current pair generation, so delayed SDP/ICE from the previous connection is
rejected. Reset requests are limited to four per ten seconds per seat. Pair
versions are discarded when either endpoint's membership/readiness changes;
there are at most ten pair entries in a five-person room.

These messages use the existing `/room-socket` channel and its authenticated
session/membership checks. No new Phoenix routes, scopes, pipelines, or
`live_session` blocks are introduced. The Hologram watch page continues to use
its existing `UserAuth` middleware.

See [conference networking](conference-networking.md) for configuration.
