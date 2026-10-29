# Rooms: data model and implementation proposal

Status: accepted for implementation, 2026-10-25, with durable chat explicitly
selected as `chat_room_messages`. The backend is implemented; see
[integration and verification notes](rooms-backend.md). Authentication/user creation
now comes from current main after rebasing; the room backend reuses its user scope
and account fixtures.

## Sources and checkout boundary

At planning time this worktree contained the initial Phoenix scaffold, with no
account schema, migrations, or planning documents. The existing implementation
and planning sources were inspected read-only in `/home/dillon/review_project`:

- `docs/release-contract-v1.md`: authoritative first-release scope.
- `docs/ownership-spike.md` and `lib/review_project/ownership_spikes/{room,rooms}.ex`:
  accepted account ownership, guest identity, capacity, and controller succession.
- `docs/youtube-sync-spike.md` and `lib/review_project/sync_spikes/timeline.ex`:
  serialized playback commands, monotonic time, and revision checks.
- `docs/local-mesh-spike.md`, `docs/manual-mesh-spike.md`, and `docs/turn-spike.md`:
  conferencing, chat, transport cleanup, and temporary relay credentials.
- `org_mode_plans/{rough_plans,phase_0_teardown,phase_1_orientation}.org` and
  `docs/adr/0001-proposed-recording-export-composition-strategy.md`: historical
  architecture context. The release contract overrides conflicting earlier plans.
- `lib/review_project/accounts/users.ex` and
  `priv/repo/migrations/20260626214110_create_users_auth_tables.exs`: current accounts.

The branch has since been rebased onto current main, which includes the account,
spike, and planning baseline. Authentication now uses `Accounts.User` and
`Accounts.Scope.user`; the original plural account schema references above are
historical. Room tests reuse the merged account fixtures and migrations.

## Requirements versus proposed choices

Accepted requirements:

- An authenticated account creates and permanently owns the room. Guests need no
  accounts and choose display names. An invitation grants guest admission only.
- Five seats total: the owner's seat plus four guest seats. The owner's place
  remains available throughout an absence.
- A guest browser identity shares one seat across tabs. A new tab replaces the old
  transport and releases its media. Other browsers/profiles/devices are distinct.
- A disconnected guest keeps its seat and original join order for 30 seconds.
- After 10 seconds of owner absence, the earliest-joined connected guest receives
  playback control. An eligible replacement takes over immediately if that guest
  disconnects. Reconnecting earlier guests do not displace a connected controller.
  The returning owner always reclaims control immediately.
- YouTube synchronization, mesh voice/video, and chat are included. Occupied rooms
  have no application-imposed duration cap. No recording or drawing is included.
- Future capabilities derive from the owner's subscription. Guest control never
  changes ownership or entitlements. Billing is deferred.

Implementation choices: persist room identity so the owner can revisit an open
room; store current seats as operational records; persist chat in
`chat_room_messages`. Closing a room preserves history. There is no automatic
room expiry or message purge. Empty-room cleanup, a time-based retention policy,
and guest removal remain future product decisions. Neither the spike's 30-minute
empty cleanup nor its latest-50 chat buffer is a release retention policy.

## Recommended tables

Use UUID primary keys for new room-domain tables and bigint references to the
existing `users.id`. Timestamp fields below use Ecto `:utc_datetime_usec`; binary
digests use `:binary` / PostgreSQL `bytea`. All columns are required unless marked
nullable. Tables include `inserted_at` and `updated_at` in UTC.

### 1. `rooms`: durable identity and ownership

| Column | Type / default | Purpose |
| --- | --- | --- |
| `id` | UUID primary key | Opaque room identifier suitable for URLs. |
| `owner_id` | bigint FK to `users`, delete restricted | Stable authenticated owner and future entitlement source. |
| `name` | varchar(120), nullable | Optional owner-facing label; names need not be unique. |
| `next_join_sequence` | bigint, default `1` | Allocate deterministic guest join order under a room lock. |
| `next_chat_sequence` | bigint, default `1` | Allocate durable message order under the same room lock. |
| `closed_at` | UTC timestamp, nullable | Proposed explicit closure marker; null means admission remains enabled. |
| `inserted_at`, `updated_at` | UTC timestamps | Creation and metadata changes. |

Indexes/constraints: index `(owner_id, inserted_at)` for the owner's room list;
check `next_join_sequence >= 1`. Restricting owner deletion prevents an orphaned
room; an account-deletion workflow must explicitly delete owned rooms before
deleting the account.

Why: ownership must outlive the controller and transport. Keeping it here avoids
putting room-specific roles on accounts. There is no `ends_at`, session allowance,
subscription snapshot, or editable feature-flags map. An open room can be revisited;
whether an empty room is later closed or deleted needs a separate policy.

### 2. `room_invitations`: guest admission credentials

| Column | Type / default | Purpose |
| --- | --- | --- |
| `id` | UUID primary key | Invitation record identity. |
| `room_id` | UUID FK to `rooms`, delete cascades | Room admitted to. |
| `token_hash` | binary, 32 bytes | SHA-256 digest of a server-generated random bearer token. |
| `revoked_at` | UTC timestamp, nullable | Allows explicitly invalidating the invitation. |
| `inserted_at`, `updated_at` | UTC timestamps | Credential lifecycle. |

Indexes/constraints: unique `token_hash`; partial unique `room_id` where
`revoked_at IS NULL`; check digest length is 32 bytes. The partial index supports
one current shared invitation, not a four-use invitation: browser seats determine
capacity, and reconnects must not consume an invitation quota.

Why: the room ID identifies a room; possession of the separate token authorizes
guest admission. A dedicated credential record keeps this boundary clear and
allows future revocation without changing room identity. One reusable invitation
matches the accepted experience; invitation expiry and rotation UI are proposals,
not already accepted behavior.

Generate a high-entropy token on the server and return the raw token only when
issued. Persist only its digest; filter raw invitations from logs and public room
snapshots. With this storage choice, an owner cannot retrieve the original token
from the database later: re-sharing after losing it requires replacing the
invitation. Decide that UX before implementation. If replacement is added, revoke
the old invitation and create its replacement atomically. Decide separately
whether revocation affects existing guests or only future joins. The owner can
recover through authenticated ownership without possessing an invitation.

### 3. `room_seats`: bounded current occupancy and reconnect identity

These are operational seat records, not a permanent membership or attendance log.
Persisting them is a proposed implementation choice; the accepted reconnect rules
alone can also be implemented in a supervised room process without a seat table.

| Column | Type / default | Purpose |
| --- | --- | --- |
| `id` | UUID primary key | Public participant identity; never expose account IDs or browser identity secrets. |
| `room_id` | UUID FK to `rooms`, delete cascades | Owning room. |
| `slot` | smallint | `0` for the owner; `1..4` for guests. |
| `browser_identity_hash` | binary, nullable | Room-scoped digest of the guest's server-issued browser identity; null for owner. |
| `display_name` | varchar(60) | Participant-chosen label for this room. |
| `join_sequence` | bigint | Owner is `0`; guests receive increasing values. |
| `disconnected_at` | UTC timestamp, nullable | Disconnect observation; audit/recovery metadata, not authoritative live presence. |
| `reserved_until` | UTC timestamp, nullable | Guest disconnect plus 30 seconds; always null for owner. |
| `connection_generation` | bigint, default `0` | Increment on each attachment to reject commands from replaced transports. |
| `inserted_at`, `updated_at` | UTC timestamps | Seat lifecycle. |

Indexes/constraints:

- Unique `(room_id, slot)` and check `slot BETWEEN 0 AND 4`: database capacity
  ceiling of five, with exactly one available owner slot.
- Unique `(room_id, join_sequence)`; check nonnegative sequence/generation.
- Partial unique `(room_id, browser_identity_hash)` for guest slots: one browser
  identity cannot occupy multiple seats in the same room.
- Owner slot requires null browser digest, sequence `0`, and null reservation.
  Guest slots require a 32-byte digest and positive sequence. A guest's disconnect
  and reservation timestamps must either both be null or have a 30-second interval.
- Trim and validate names as nonempty, at most 60 characters, without control
  characters; enforce nonblank/length bounds in the database too. Names are not
  unique and never confer permissions. These bounds follow the spike and remain
  proposed product limits.

Create slot `0` with the room transaction, initially labeled `Host`, then use the
owner's chosen display name when joining. Owner identity always comes from
`rooms.owner_id`; a seat has no second owner/user FK to become inconsistent.
Authenticated visitors who do not own the room still use invitation guest seats.
Server context authorization, rather than a client-supplied slot or role, selects
the owner seat.

Guest identity comes from a random server-issued value in the signed browser
session, shared across tabs. Persist a digest scoped to the room, for example
SHA-256 of an unambiguous room UUID and identity encoding. Do not store raw cookie
values or use display names/IP addresses as identity. Owner identity comes from
the authenticated account and therefore works across signed-in browsers.

On reconnect within the reservation, reuse the seat ID and join sequence. On
expiry, remove the guest seat; a later admission gets a new ID and sequence.
The owner's seat never expires. Explicit guest Leave should release immediately
as a proposed UX rule; accidental transport loss uses the accepted reservation.
Seat deletion must not be mistaken for a guest ban or permanent removal feature.

Why: fixed slots enforce the five-person ceiling, while separate join order
supports fair handoff. Per-room names support anonymous guests and let an account
use a different label in each room. Expiring seat records bound storage independently
of session duration. The cost is database writes on seat transitions and a need
to reconcile stale records after coordinator failure.

## Users table: no mandatory change

The main checkout already has `users.id`, `email`, `hashed_password`,
`confirmed_at`, and timestamps, plus the existing `users_tokens` authentication
table. These are sufficient for authenticated ownership.

An optional `users.display_name` (`varchar(60)`, nullable) can prefill the owner's
chosen name. Copy it into the seat at admission and allow a room-specific choice.
Do not backfill it from email or expose email as a room display label. Existing
accounts can remain null and be prompted for a name when joining.

Do not add `current_room_id`, `role`, `is_host`, or subscription/billing columns to
users. Roles are room-specific; multiple rooms must remain representable. Initially
an entitlement function derives free capabilities from the room owner. Add a
subscription relation only when paid tiers and their lifecycle are specified.

## Live state and conditional persistence

Use a supervised coordinator per active room, with Registry/PubSub/Channels for
routing and broadcasts. Admission, disconnect, tab replacement, and commands pass
through that coordinator. Lock the room row in seat-allocation transactions so
simultaneous joins, cleanup, and sequence allocation serialize. Commit before
broadcasting successful admission; uniqueness constraints provide a final guard.

Keep these in the coordinator: active channel PID/monitor, current controller seat
ID, owner-absence deadline, playback and authority revisions, and a playback
snapshot (`youtube_video_id`, position, playing/paused, monotonic anchor). Every
operation checks current membership and connection generation. Shared playback
commands also check controller identity, playback revision, and authority revision.
Reclaim revokes guest authority on the server immediately. Media signaling only
connects joined seats in the same room.

The 10/30-second live deadlines use the server's monotonic clock; database UTC
timestamps are persistence metadata. A replaced transport's later DOWN message
must not disconnect its replacement. Persisted seat data does not prove a channel
is connected. Startup recovery must reconcile stale seats before accepting joins.
A new coordinator incarnation invalidates old commands and requires fresh joins;
never restore PIDs, monotonic clock anchors, or controller authority from rows.

The implementation restores room identity and durable chat after a coordinator
restart. It reconciles seats, clears controller authority, and starts playback
unselected/paused with a fresh revision epoch. The selected video and playback
position are not persisted. No elapsed-duration limit is imposed by recovery.

WebRTC connections, SDP/ICE messages, capture settings, and TURN credentials are
ephemeral. They need no database tables. Relay credentials must be renewable for
joined participants without expiring the room. Local mute/volume/autoplay consent
remain client settings. No free-tier recording, drawing, export, or event-log
tables are proposed. Playback synchronization can use current state without a
durable event history; historical event sourcing is not required by this release.

### 4. `chat_room_messages`: durable chat

Durable chat was explicitly selected during implementation. The initial history
snapshot contains the latest 50 messages; callers can page backward in bounded
batches of at most 100. This is a retrieval bound, not deletion or retention.

| Column | Type / default | Purpose |
| --- | --- | --- |
| `id` | UUID primary key | Message identity and client deduplication. |
| `room_id` | UUID FK to `rooms`, delete cascades | History scope. |
| `sender_seat_id` | UUID FK to `room_seats`, nullable, delete sets null | Attribution while the operational seat exists. |
| `sender_display_name` | varchar(60) | Server-captured name snapshot survives seat expiry/name changes. |
| `sequence` | bigint | Server-assigned room message order. |
| `body` | text | Nonblank plain text, at most 2,000 characters. |
| `inserted_at` | UTC timestamp | Server acceptance time. |

Use unique `(room_id, sequence)`, an index `(room_id, inserted_at, id)`, and
nonblank name/body constraints. Allocate sequence atomically under the room lock
with the durable `rooms.next_chat_sequence` counter. The server assigns
author/name/order and verifies the sender belongs
to that room. Escape text on rendering. Message insert timestamps/order are
immutable; this table has no `updated_at` unless editing becomes a feature.

The database also enforces same-room sender attribution with a composite foreign
key. Seat deletion nulls only the sender reference; the message and sender name
survive. Joined guests can read history while joined, including late joins.
Authenticated owners can read history after closure. Messages are retained until
the room is deleted; no age-based purge or message editing API is implemented.

## Delivery plan and review decisions

1. Integrated: current main's account migration precedes the room migration.
   Room tests use its real user scope and account fixtures. Room persistence and
   durable chat were accepted for this implementation.
2. Implemented: generate migrations using `mix ecto.gen.migration`; implement `Rooms` context
   functions with `current_scope` first and assign ownership server-side. Create
   room, owner seat, and invitation atomically. Cover FK/check/index constraints
   and competing guest admissions.
3. Implemented: extract the accepted admission/controller state machine into a supervised
   production room coordinator. Cover shared-browser replacement, stale DOWN
   events, 30-second reservation/expiry, 10-second handoff, guest succession,
   owner return from another browser, stale commands, and logout revocation.
   Use supervised test processes and an injected clock rather than sleeps.
4. Remaining transport/client integration: connect YouTube, chat, mesh, and renewable TURN with membership authorization.
   Preserve the Hologram/native-browser facade established by the spikes; schema
   design does not require migrating the client UI framework.
5. Backend tests cover seat limits, owner capacity during long absence, handoff,
   durable chat, and recovery. Remaining release verification includes actual
   browser endpoints, media cleanup, and unlimited-duration operation.
   Complete the contract's supported desktop-browser checks, public-network/TURN
   coverage, and combined multi-hour soak. Run `mix precommit` on implementation.

Decisions needed before the dependent implementation:

- Whether to introduce empty-room expiry beyond explicit owner closure?
- Whether to introduce age-based message deletion beyond the implemented durable policy?
- What does the user see after a server restart, and is cross-node recovery needed
  for launch? Persisted room metadata alone does not provide it.
- Whether to introduce guest removal or revoke already-joined guests when an
  invitation is replaced? Replacement currently affects future admissions only.
- Add an account default display name, or prompt separately for every room?
- What YouTube edge cases and numerical synchronization/recovery targets are
  accepted? The existing spike thresholds are provisional.

The implemented backend has four new tables and no account columns or auth schema
changes. Account display-name defaults remain optional work for the account branch.
See the implementation notes for the exact auth integration boundary and remaining
transport/UI and release-verification work.
