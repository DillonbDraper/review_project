# First release contract

Status: agreed product scope, recorded 2026-10-18.

This document is the authoritative scope for the first release. It records the
product decisions agreed with the project owner; it does not claim these features
are implemented or verified. Future sessions should use this contract when
planning work and evaluating research spikes. Earlier plans and proposed ADRs
provide historical context and do not override these decisions.

## Agreed scope

| Area | Decision |
| --- | --- |
| Release | Free tier only. |
| Video sources | YouTube only; support is required for launch. |
| Participants | Five total per room, including the host. |
| Session duration | No application-imposed time limit. |
| Features | Synchronized YouTube playback, mesh voice/video conferencing, and chat. |
| Recording and drawing | Neither included. No recording of any kind in the free tier. |
| Access | Host signs in; guests join by invitation link without accounts and choose display names. |
| Browsers | Current desktop Chrome, Edge, Firefox, and Safari. Mobile support is deferred. |
| Playback authority | Host normally selects the video and controls shared playback; a connected guest takes control during host absence. |
| Handoff policy | After 10 seconds of host absence, the earliest-joined connected guest receives playback control. The returning host automatically reclaims control. |
| Guest admission and identity | Anyone with the invitation can join and choose a display name. One browser identity occupies one seat across tabs; a disconnected guest seat is reserved for 30 seconds. |
| Future capabilities | Determined by the room owner's subscription, rather than individual guests' subscriptions. |

## Expected session experience

1. An authenticated host creates a room and shares its invitation link.
2. Up to four guests join without registering, bringing the room to a maximum of
   five participants including the host.
3. The host selects a YouTube video. Play, pause, and seek actions synchronize
   playback across participants. Participants can use chat and mesh voice/video
   conferencing during the session.
4. If the host disconnects, a connected guest receives playback control so the
   session can continue. This does not transfer ownership: the original
   authenticated host remains the room owner.
5. A session is not ended because it reaches an elapsed-time allowance. Empty-room
   expiry and resource cleanup are separate lifecycle decisions still to be made.

Room creation begins in a modal on the main page. Invitations are shareable links
that people can distribute however they like; built-in invitation delivery is
not required. This entry flow was selected by the project owner on 2026-10-28.

Room chat loads the full stored conversation on entry and rejoin, without
manual pagination or a displayed-message cap. Incoming messages preserve the
reader's position when they have scrolled up. This presentation was selected by
the project owner on 2026-10-29; chat retention and storage remain open decisions.

Conferencing must allow joining with camera and microphone, microphone only,
camera only, or neither. Missing, unavailable, or denied camera/microphone access
must not prevent room admission or receiving other participants' media. Joined
participants appear above the main video review section in separate square
tiles; a participant without video has a black tile. These requirements were
selected by the project owner on 2026-10-29. The immediate conferencing work
focuses on connecting participants; host controls for removing or muting others
are deferred. See the [conferencing implementation plan](conferencing-plan.md)
for proposed integration and verification steps, rather than additional agreed
product requirements.

After a brief signaling outage, the same page releases capture immediately and
automatically reacquires previously enabled camera/microphone after rejoining.
Device permission failures leave that device off with a retry action. Fresh page
loads, navigation, explicit leave, replacement, and logout start with devices
off. This recovery preference was selected by the project owner on 2026-10-30.

YouTube playback should use the supported embedded player. YouTube content that
is unavailable or disallows embedding may fail with an appropriate explanation;
the release does not promise playback of every YouTube URL. Downloading,
scraping, or rehosting YouTube media is outside this contract.

Shared video controls were selected by the project owner on 2026-11-20:

- Provide video selection, play/pause, a seek bar, elapsed/duration display, and
  volume/mute. Volume, mute, and captions are local to each participant.
- The current playback controller may use the shared bar or native YouTube
  play/pause/seek controls. Confidently inferred native actions update the room;
  ambiguous changes stay local and reconcile. Follower actions do not control
  the room. Designated-controller grants are deferred.
- Support individual prerecorded videos and Shorts. A link containing a video
  ID and playlist context loads only that video. Playlist-only input and live/DVR
  playback are unsupported for this pass.
- A locally buffering, blocked, or failed player does not pause everyone. It
  catches up when available, with a local enable/retry action when necessary.
- Stop at the end; the controller can replay from zero or select another video.
- Target p95 absolute timeline drift and participant spread of at most 0.5
  seconds during settled playback. This measures player-reported position,
  rather than frame-accurate presentation. Preparation, buffering, autoplay
  blocks, and recovery are measured separately. Native-action inference and
  tighter synchronization must pass real-browser validation before production
  integration; the target must not be silently weakened.

The approved implementation plan defaults recovery acceptance to alignment
within five seconds once the transport and player are ready and local playback
is enabled. Verification is still required; these decisions do not claim that
any implementation currently meets these targets.

## Explicitly deferred

- Paid tiers, billing, and subscription purchase flows.
- Uploaded or self-hosted videos and providers other than YouTube.
- Drawing and annotation features.
- Session recording, recording exports, and screen-capture features.
- Mobile browser support.
- Host conferencing moderation controls, including removing or muting others.

Chat belongs in every tier, including free. The exclusion of recording does not
settle chat retention or storage policy; that remains an open decision.

If paid tiers are introduced, the room owner's subscription determines the room's
capabilities. Giving a guest playback control does not make that guest the owner
or change the room's entitlement source. This future rule does not require billing
or paid infrastructure in the first release, and no paid feature set is promised
here.

## Decisions still open

These details need explicit decisions before their dependent implementation;
they must not be treated as already agreed:

- Guest removal rules, when moderation is introduced, and identity continuity
  across different browsers/devices.
- Empty-room expiry, room persistence, and resource cleanup.
- Chat retention and storage.
- Additional YouTube player edge cases beyond the prerecorded single-video
  behavior and recovery target agreed above.

The handoff and browser-seat policies above were explicitly accepted by the
project owner on 2026-10-24 while starting spike 5. A reconnect within the guest
reservation period retains that seat and its join order. Separate browsers or
devices have separate guest identities. The owner remains the same authenticated
account throughout handoff; up to four guests can occupy the room.

## Verification required before release

The implementation must demonstrate the agreed experience in the supported
desktop browsers, including synchronized YouTube playback, five-person mesh
conferencing, chat, enforcement of the participant limit, and guest playback
handoff without ownership transfer. Real-browser verification must cover the
YouTube integration and conferencing across representative networks, including
TURN relay where needed.

Existing interop or media echo spikes are evidence for the paths they exercise;
they do not establish that the complete release experience works. No application
session-duration cap should be introduced while resolving operational lifecycle
or cleanup requirements.

Changes to this scope should be recorded here following an explicit product
decision. Resolve open questions here as they are agreed, keeping proposed
implementation choices distinct from accepted requirements.
