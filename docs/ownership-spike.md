# Spike 5: access, ownership and host-absence playback control

Scope: the [first release contract](release-contract-v1.md). This development
spike combines real account authentication with accountless named guests,
server-authoritative playback control, the existing YouTube player, mesh media,
chat and optional TURN. It does not introduce paid features or recording.

Status: complete and accepted by the project owner on 2026-10-24, following
automated real-browser verification and manual home-network testing.

The owner explicitly closed this viability spike after testing the ownership and
handoff flow and reporting that everything was in order. Earlier reports of
login, room creation and guest playback problems are no longer open blockers
for this spike. This acceptance does not establish an unrecorded device/browser
matrix, public-network coverage or a multi-hour endurance result.

## Accepted behavior

The project owner explicitly selected these rules on 2026-10-24:

- Anyone with the invitation can join without an account and choose a name.
- One browser identity occupies one seat across tabs.
- A disconnected guest seat is reserved for 30 seconds, retaining its identity
  and original join order during that interval.
- After 10 seconds of host absence, the earliest-joined connected guest
  receives playback control.
- The returning host automatically reclaims playback control.

Ownership always belongs to the authenticated account that created the room.
Up to four guest seats are available, leaving the owner's place available for
return even after a long absence. A subsequent join in the same browser moves
its seat to the new tab, closes the old channel, and stops the old tab's capture
and peer connections. It does not create a sixth conferencing endpoint.
For guests, browser identity means the signed session shared by tabs using the
same browser profile and site origin. Private profiles and other browsers or
devices have distinct identities. Owner identity comes from the account, so
the owner can also return from another signed-in browser.

During the host's grace period no guest can issue playback commands. The shared
playing timeline continues; host loss does not pause every other participant.
Only connected guests are eligible. If the guest controller disconnects after
the host's grace has elapsed, the next eligible guest takes over immediately.
An earlier guest reconnecting during its seat reservation does not displace an
already connected guest controller. The host still automatically reclaims.

## Try it on the home network

Use the existing LAN launcher and test certificate trust. With coturn available:

```sh
node scripts/turn_vm.mjs start
TURN_SPIKE_CONFIG="$PWD/.spike-turn/app.json" node scripts/start_mesh_lan.mjs
```

If either launcher is already running, leave it running or stop it with its
`stop` / `--stop` command before starting again. The updated app must have been
restarted after installing spike 5. Existing LAN HTTPS/TURN firewall rules and
certificate trust are reused; guests do not run scripts.

Open <https://192.168.1.58:4001/dev/spikes/room-access> on the owner's computer:

1. Use **Sign in or register as the room owner**, which opens the existing
   authentication flow in the same tab and remembers the spike URL, including
   an invitation and any ICE mode in its query. Development email links are visible
   in the local mailbox at `/dev/mailbox`; no extra authentication bypass is
   provided by this spike.
2. After login or email confirmation, you return to the spike. The header shows
   **Signed in as your-email**. Choose a display name and network mode, create
   the room, and copy the generated invitation. Refreshing or reopening the URL
   checks the same account session; an open tab also rechecks when you return
   to it. Use the same hostname/IP and browser profile for login and testing.
3. Guests open that full invitation, enter their names and join. Use another
   computer, browser, or private profile when testing a distinct participant.
   Another ordinary tab in the owner's profile shares the owner's login and
   moves the owner's seat.
4. Enable YouTube playback on each device, start media, and enable room audio.
   The current playback controller presses **Play for everyone**.
5. Check the room status for connected participants, occupied/reserved seats,
   owner presence and the name of the current playback controller.

The owner can recover the room by reopening the invitation while signed into
the owning account. A guest invitation never grants ownership. Names are display
labels, so matching the owner's name does not grant the owner's permissions.

To test handoff, disconnect the owner's transport using the research controls.
After 10 seconds, the earliest connected guest should be able to play, pause,
seek and select a video. Reconnect the owner and verify that the guest's shared
controls become disabled while the owner's become enabled. Try the next guest
controller disconnect, a guest rejoin within 30 seconds, and admission before
and after a disconnected guest seat expires. Logging out also revokes the
owner's active room socket and follows the same absence/handoff policy.

Download the device reports before leaving/reloading. Reports contain public
room state and statistics, not invitations, auth cookies, TURN credentials,
chat bodies or media recordings. The original 3B and TURN pages remain available
as earlier research fixtures; use the new spike-5 page for real ownership tests.

## Implementation boundaries

- `OwnershipSpikes.Rooms` is the single serialized authority for admission,
  seats, reconnects, playback authority, signaling and chat in these rooms.
  Ownership is a private account ID; public ownership references use a random
  seat ID rather than exposing an account ID or email.
- The new Hologram pages use the existing native player/mesh facade. Room
  creation goes through a Phoenix controller in a scope using
  `[:browser, :require_authenticated_users]`. Browser bootstrap uses `:browser`
  without mandatory authentication so accountless guests work. The sign-in
  entry controller also uses `:browser` to remember a validated local spike
  destination before entering the existing login/registration flow. These are
  controller routes; no additional `live_session` is introduced.
- The socket receives the signed cookie session through Phoenix's
  `connect_info`, with normal CSRF validation. Client-supplied user IDs,
  roles or old research host tokens cannot authenticate an owner.
- The owning account is derived from `current_scope`, which is passed first
  to the room context. Signed-in sessions are checked again for channel
  operations, and the socket uses the generated authentication disconnect ID
  so logout revokes it. Session-token database operations suppress SQL bind
  logging; request/channel parameter filters cover invitation and credential
  fields.
- Guest identity is generated by the server into the signed browser session.
  First-session bootstrap is serialized with Web Locks when available to
  avoid simultaneous tabs overwriting a fresh cookie with separate identities.
- Commands must match both the playback revision and an authority revision.
  The controller is checked on every command. Returning owners revoke former
  guest authority immediately, including commands sent while UI state is stale.
- Process monitors remove disconnected transports. The monotonic room clock
  controls grace and reservation deadlines; periodic maintenance also handles
  expiration when nobody sends another message.
- YouTube playback math is shared with earlier spikes through
  `SyncSpikes.Timeline`. Media signaling is targeted only between currently
  joined, media-enabled seats in the same room; chat authors and names are set
  by the server. TURN credentials use the existing joined-member path.

The room manager, its 100-room research bound, empty-room pruning after 30
minutes, and latest-50 in-memory chat buffer are experimental infrastructure.
They do not settle persistence, retention, cleanup or operational release
policies. Occupied sessions have no duration cap. Restarting the development
server loses spike rooms. Guest removal, invitation rotation/revocation,
production abuse controls and cross-node failover are not implemented here.

## Validation

Backend tests use supervised processes and an injected monotonic clock to check
grace periods and reservations without sleeps. They cover owner authentication,
forged invitations/roles, stale authority, controller succession, owner reclaim,
reserved capacity, stable identity, tab replacement, targeted signaling, named
chat and revoked sessions.

`scripts/room_access_browser_test.mjs` uses isolated Chrome browser contexts and
Firefox as separate participants. It signs into a dedicated test account through
the actual login controller, verifies CSRF rejection, runs YouTube and forced
TURN media with five seats, and exercises the real 10/30-second deadlines.
It bypasses disabled controls to verify that the server rejects forged commands.

Generate/refresh the one-use login fixture without sending email:

```sh
direnv exec . mix run scripts/room_access_fixture.exs
```

The fixture and browser profiles belong in ignored `.spike-access/`, with private
directory/file permissions. This creates or reuses only a dedicated
`room-spike-…@example.test` account; it does not modify personal accounts.
Use isolated synthetic-capture browsers as in the existing browser harness.
The run used Chrome's debug port 9225 and Firefox's 9226:

```sh
CHROME_DEBUG_URL=http://127.0.0.1:9225 \
FIREFOX_DEBUG_URL=ws://127.0.0.1:9226/session \
  node scripts/room_access_browser_test.mjs
```

Remove only that dedicated fixture account and its tokens after testing:

```sh
direnv exec . mix run scripts/room_access_fixture.exs --cleanup
```

The focused login regression uses the actual sign-in link and email-confirmation
form, then checks the return URL/ICE mode, account status after a refresh or new
tab, room creation, owner recovery through an invitation, and status after logout
in another tab. Generate a fresh fixture token before **each** browser run:

```sh
direnv exec . mix run scripts/room_access_fixture.exs
CHROME_DEBUG_URL=http://127.0.0.1:9225 node scripts/room_access_auth_browser_test.mjs
direnv exec . mix run scripts/room_access_fixture.exs
BROWSER=firefox FIREFOX_DEBUG_URL=ws://127.0.0.1:9226/session \
  node scripts/room_access_auth_browser_test.mjs
direnv exec . mix run scripts/room_access_fixture.exs --cleanup
```

These four scenario groups passed in both Chrome and Firefox on 2026-10-24,
with no application JavaScript errors. The earlier harness used a fetch-based
login and missed the missing return destination and static sign-in prompt.
The fix also adds five controller regressions for password/magic-link returns,
bootstrap account recognition, and restricted return destinations; `mix precommit`
now passes 151 tests. The existing 14 native unit tests also pass.

The completed implementation run performed this cleanup. The report is
`.spike-access/browser-report.json`. Each endpoint's selected local
candidate must be `relay`, with actual received audio and decoded video. Under
QEMU's forwarding, Firefox can report the remote candidate as peer-reflexive;
requiring a remote `relay` label would incorrectly reject this working path.
Neither this observation nor a local relay pass establishes public NAT behavior.

Results from 2026-10-24:

| Check | Result |
| --- | --- |
| `mix precommit` | 146 tests passed, including 18 new spike-5 backend/security tests |
| Native player/capture/report unit tests | 14 passed |
| Real-browser account login, anonymous creation refusal and CSRF protection | Pass |
| Five-person YouTube + named chat + forced TURN mesh, sixth-seat rejection | Pass |
| Shared-browser tab replacement and hardware/peer cleanup | Pass |
| Ten-second handoff, guest pause/seek/play, automatic owner reclaim, forged/stale guest control rejection | Pass |
| Controller succession and reserved reconnect identity | Pass |
| Thirty-second reservation expiry and subsequent admission | Pass |
| Account logout revokes room transport and triggers guest handoff | Pass |
| Existing seven-check 3B browser regression | Pass |
| Application console errors | None in either browser suite |
| Production compilation with warnings as errors | Pass |
| Compiled production metadata | New ownership page, controller routes and socket excluded |

The browser run used Chrome 155.0.8059.84 and Firefox 158.0, synthetic capture,
four Chrome browser contexts and a Firefox profile for the five active seats,
plus separate contexts/tabs for rejection and replacement scenarios. These are
distinct browser identities, not five physical machines. Backend deadlines were
tested with a controlled clock; the browser suite used the actual 10/30-second
deadlines. Existing local TURN and earlier manual 3B acceptance remain separate
evidence.

Manual acceptance for this spike is complete. Supported Edge/Safari coverage,
production deployment, public-network/TURN cost validation and the multi-hour
combined soak remain separate verification work.
