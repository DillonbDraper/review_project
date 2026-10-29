# Rooms backend

The backend implements the accepted room data model with durable messages named
`chat_room_messages`. It adds `rooms`, `room_invitations`, `room_seats`, and
`chat_room_messages`, Ecto schemas, the `ReviewProject.Rooms` context, and a
supervised coordinator for each active room. This change adds no user schema,
auth flow, web routes, client UI, or browser media implementation. The native
YouTube/mesh/TURN spike integration remains a transport/client task.

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
are `video`, `play`, `pause`, and `seek` (with `position` in seconds). Every command
uses the latest snapshot's epoch, playback revision, and authority revision. The
server checks controller identity before changing shared state. Native player
callbacks must not be treated as shared playback commands.

Other requests are `:snapshot`, `:leave`, `{:media, boolean}`, and
`{:signal, %{"to" => seat_id, "data" => description_or_candidate}}`. Signals only
reach connected, media-enabled seats within the same room. Notifications are
`{:room_state, snapshot}`, `{:room_chat_message, message}`, `{:room_signal, signal}`,
`{:room_seat_replaced, reason}`, `{:room_left, reason}`, and `{:room_closed, reason}`.
Public snapshots expose random seat IDs, not account IDs or browser identity hashes.

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
the 10/30-second deadlines. Real-browser YouTube/media behavior, account logout
integration, desktop-browser coverage, public TURN networks, and the combined
multi-hour soak still need verification when the transport/client is connected.
