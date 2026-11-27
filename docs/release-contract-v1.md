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
| Video sources | YouTube plus temporary uploaded prerecorded MP4 and native WebM; uploaded-video rollout approved 2026-11-27, with remaining browser/capacity verification accepted as follow-up work. |
| Participants | Five total per room, including the host. |
| Session duration | No application-imposed time limit. |
| Features | Synchronized YouTube/uploaded-video playback, mesh voice/video conferencing, and chat. |
| Recording and drawing | Neither included. No recording of any kind in the free tier. |
| Access | Host signs in; guests join by invitation link without accounts and choose display names. |
| Browsers | Current desktop Chrome, Edge, Firefox, and Safari. Mobile support is deferred. |
| Playback authority | Host normally selects the video and controls shared playback; a connected guest takes control during host absence. |
| Handoff policy | After 10 seconds of host absence, the earliest-joined connected guest receives playback control. The returning host automatically reclaims control. |
| Guest admission and identity | Anyone with the invitation can join and choose a display name. One browser identity occupies one seat across tabs; a disconnected guest seat is reserved for 30 seconds. |
| Future capabilities | Determined by the room owner's subscription, rather than individual guests' subscriptions. |

## Expected session experience

Signed-in users have a profile dropdown in every application header, showing
their email beside the supplied silhouette icon. Clicking it reveals User
settings and Log out. Signed-in users can view settings without reauthentication;
email and password changes require authentication within the last 20 minutes.
Older sessions use the existing login flow and return to settings to re-enter
unsaved changes. Email-confirmation links retain their destination through this
flow. These choices were selected by the project owner on 2026-11-21.

1. An authenticated host creates a room and shares its invitation link.
2. Up to four guests join without registering, bringing the room to a maximum of
   five participants including the host.
3. The current playback controller selects a YouTube video or a validated temporary upload. Play, pause, and seek actions synchronize
   playback across participants. Participants can use chat and mesh voice/video
   conferencing during the session.
4. If the host disconnects, a connected guest receives playback control so the
   session can continue. This does not transfer ownership: the original
   authenticated host remains the room owner.
5. A session is not ended because it reaches an elapsed-time allowance. A room
   expires after three hours continuously empty, as described below.

Room expiry was selected by the project owner on 2026-11-22: the last participant
leaving or disconnecting starts a three-hour abandonment deadline. Any successful
join before that deadline cancels it. A room that has never been joined expires
three hours after creation. Occupied rooms have no time limit, including rooms
where only guests remain. Expiry closes admission, revokes invitations, removes
the room from the active room list, and stops its live coordinator; it preserves
stored chat. The deadline survives restarts and is checked on admission as well
as by a supervised worker at startup and every minute. Recovery of a previously
occupied room with no surviving coordinator begins a new three-hour grace period;
already-empty rooms retain their original deadline. Existing empty rooms receive
a full grace period when expiry is introduced. Chat deletion remains undecided.

Room creation begins in a modal on the main page. Invitations are shareable links
that people can distribute however they like; built-in invitation delivery is
not required. This entry flow was selected by the project owner on 2026-10-28.

Leaving a room releases the participant's session and returns them to the main
workspace at `/`, rather than leaving them on the room page. This behavior was
selected by the project owner on 2026-11-21.

The workspace has no drawing board section or placeholder. The project owner
selected its removal on 2026-11-21.

Video selection lives in the player header: a link input and adjacent load button
appear before selection. After selection, the header shows the current URL in a
read-only textbox, never a clickable link, and a switch-video button that opens
a modal for choosing a replacement. The numbered
video heading and separate link footer are removed. This presentation was selected
by the project owner on 2026-11-21.

Room chat loads the full stored conversation on entry and rejoin, without
manual pagination or a displayed-message cap. Incoming messages preserve the
reader's position when they have scrolled up. This presentation was selected by
the project owner on 2026-10-29; chat retention and storage remain open decisions.

The chat composer uses one rounded, pale green field with comfortable internal
padding, a borderless multiline input, and focus and error treatment on the outer
field. The "Your message" label stays above it; the character count and an inset
Send message button sit inside it below the writing area. This presentation was
selected by the project owner on 2026-11-22.

The composer has no manual resize handle. New messages are limited to 1,000
Unicode codepoints, enforced in the composer and on the server. Previously stored
messages remain readable. These choices were selected by the project owner on
2026-11-22.

The participant panel has no visible header (the "In this room" and "Room call"
labels are removed), with padding above the participant tiles. Neither the
participant panel nor the Chat header shows a
numeric count badge. This presentation was selected by the project owner on
2026-11-22.

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

The local enable-playback button has an adjacent info icon whose popover explains:
"Some browsers may need explicit approval to allow syncing video playback".
This presentation was selected by the project owner on 2026-11-22.

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

## Temporary uploaded video

The owner approved temporary app-server staging and authorized implementation on
2026-11-27. These requirements supersede the earlier YouTube-only restriction;
they are not a claim of browser, performance, or deployment verification.

- Exactly one physical staged file per room, including receiving, validating,
  ready, selected, and retired files whose readers still retain disk resources.
- The current playback controller may upload and select, including the authorized
  guest after host-absence handoff. Existing host reclaim/revision guards remain.
- Allow files up to **1 GiB (1,073,741,824 bytes)**. The owner approved increasing
  the original 500 MiB cap on 2026-11-27 after local full-file verification.
  The global staged quota remains 1 GiB, with a separate 1 GiB free-disk reserve.
  Provisioning remains separate from this file-limit decision; see the rollout
  decision below.
- Support browser-compatible MP4 H.264/yuv420p with AAC-LC or no audio. Include
  native WebM VP8/VP9 and AV1 Main-profile 8-bit yuv420p with Opus or no audio.
  The owner accepted AV1 for normal uploads on 2026-11-27 after reviewing local
  verification. Reject HEVC and unverified formats, including AV1 MP4 and 10-bit
  AV1; do not transcode. The known active-call synchronization failure and pending
  Edge/Safari verification remain recorded follow-ups; accepting AV1 does not
  establish universal browser compatibility or change synchronization targets.
- In the selected-video header, put Switch video immediately right of the
  current-source textbox, followed by Upload video. A successful, validated new
  upload automatically selects the video and closes the upload modal once the
  room accepts the selection, ready for review. Offer progress and cancel/retry;
  retain Use this video for an already-staged file or a selection retry. These
  flow and button-order changes were selected by the owner on 2026-11-27.
- Uploaded-to-uploaded replacement requires explicit Discard and replace, stopping
  the old source and releasing readers/file before accepting replacement bytes.
  No rollback of the discarded file is promised; YouTube may continue during upload.
- Delete staged media after **five continuous minutes empty OR one continuous hour
  without video playback or user interaction, regardless of conferencing**.
  Deliberate chat/device/control actions reset idle; continuing camera/microphone
  streams, RTP/signaling, heartbeats, polls and background progress do not.
- Cleanup removes media only, never the room, chat, or conferencing. There is no
  occupied-session duration cap. Restart/deployment/file loss requires re-upload.
- Delivery is private, same-origin, membership-authorized GET/HEAD/range streaming;
  opaque IDs are not authorization. No permanent media library or P2P delivery.
- Native playback uses the same controller/follower, local volume/mute,
  blocked-player recovery, drift/spread and recovery targets as YouTube.

See [the implementation plan](uploaded-video-plan.md) and
[operations/evidence](uploaded-video-operations.md) for architecture and follow-up checks.

On 2026-11-27, after the playback corrections and local five-person H.264/AV1
active-call passes, the owner accepted the current evidence as sufficient for
deployment. The remaining uploaded-video browser matrix, repeatability,
long-file/device and hosted-capacity checks are follow-up work, not prerequisites
for this rollout. This explicitly supersedes earlier upload-specific rollout
gates. Synchronization/recovery targets, format policy and storage guardrails
remain unchanged; historical failures and unverified behavior remain recorded.
Staging enables uploads explicitly with `UPLOADED_VIDEO_ENABLED=true`, retaining
the runtime disable switch. This decision does not claim universal browser
compatibility or completed capacity verification.

## Explicitly deferred

- Paid tiers, billing, and subscription purchase flows.
- A permanently saved media library, object storage, persistent media volumes,
  peer-to-peer file delivery, transcoding, and providers other than YouTube or
  the approved temporary uploaded-video path.
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
- Long-term retention and deletion of expired room records.
- Chat retention and storage.
- Additional YouTube player edge cases beyond the prerecorded single-video
  behavior and recovery target agreed above.

The handoff and browser-seat policies above were explicitly accepted by the
project owner on 2026-10-24 while starting spike 5. A reconnect within the guest
reservation period retains that seat and its join order. Separate browsers or
devices have separate guest identities. The owner remains the same authenticated
account throughout handoff; up to four guests can occupy the room.

## Verification required before release

The uploaded-video rollout exception above applies to this section: its remaining
verification is follow-up work and does not block the approved deployment.

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
