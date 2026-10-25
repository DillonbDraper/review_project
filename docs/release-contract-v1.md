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

YouTube playback should use the supported embedded player. YouTube content that
is unavailable or disallows embedding may fail with an appropriate explanation;
the release does not promise playback of every YouTube URL. Downloading,
scraping, or rehosting YouTube media is outside this contract.

## Explicitly deferred

- Paid tiers, billing, and subscription purchase flows.
- Uploaded or self-hosted videos and providers other than YouTube.
- Drawing and annotation features.
- Session recording, recording exports, and screen-capture features.
- Mobile browser support.

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

- Guest removal rules and identity continuity across different browsers/devices.
- Empty-room expiry, room persistence, and resource cleanup.
- Chat retention and storage.
- The scope of YouTube playlists, live videos, and other player edge cases.
- Measurable playback synchronization targets and acceptable recovery behavior.

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
