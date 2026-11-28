# Uploaded video implementation plan

> Historical: the approved direct-file sharing replacement supersedes this upload path.
> See [current operations](direct-file-sharing.md) and the [release contract](release-contract-v1.md).

Status: uploaded-video rollout approved 2026-11-27 after local playback corrections
and five-person H.264/AV1 passes. Remaining browser/capacity verification is
follow-up work, not a deployment prerequisite; see the release contract.

This document records the plan for adding uploaded prerecorded videos to the
existing room workspace. It is not evidence that upload delivery, browser support,
storage capacity, or synchronization targets have been implemented or verified.

## Goal

Let the current playback controller upload a video during a call and switch the
whole room to it. Temporarily stage the file on the existing application server,
stream it privately to admitted participants, and reuse the existing room authority
and synchronization policy. Preserve YouTube playback, chat, and conferencing.

## Approved product decisions

| Area | Decision |
| --- | --- |
| Delivery | Private temporary files on the existing app server, streamed over HTTP. |
| Retention | Call-scoped staging, not a permanently saved media library. |
| Room quota | Exactly one staged file per room, including receiving, validating, ready, or selected media; no active file plus pending replacement. |
| Upload authority | The current playback controller, including a guest who receives control during host absence. |
| File limit | 1 GiB, exactly 1,073,741,824 bytes; owner approved 2026-11-27 after local full-file verification, superseding the initial 500 MiB cap. |
| Empty cleanup | Delete staged media after five continuous minutes with zero connected participants. |
| Idle cleanup | Delete staged media after one continuous hour with neither video playback nor user interaction, regardless of ongoing conferencing. |
| Cleanup scope | Remove staged media only; do not end conferencing, close the room, or delete chat. |
| WebM | VP8/VP9 and AV1 Main 8-bit yuv420p, with Opus or no audio; AV1 accepted by the owner on 2026-11-27. |
| Entry point | Beside the URL/source textbox; during playback, show Switch video followed by Upload video (owner update 2026-11-27). |
| Completion | Automatically select a newly validated upload and close the modal once accepted by the room; keep Use this video for staged files and retries (owner update 2026-11-27). |

The two cleanup conditions are alternatives: whichever is reached first triggers
cleanup. Video playback prevents idle expiry; deliberate user interaction resets
the idle deadline. Continuing camera/microphone streams, enabled devices,
RTP/signaling, polling, heartbeats, and background progress reports are not user
interaction. A deliberate action such as sending chat or toggling a device is
interaction; the resulting ongoing media traffic is not. No conference activity
detector is required.

These are media-retention rules, not an application session-duration cap. Existing
room expiry after three hours continuously empty remains a separate lifecycle.
Cancellation, validation failure, explicit discard/replacement, and room closure
can remove media earlier.

## Recommended formats and player

| Container | Proposed supported encoding | Handling |
| --- | --- | --- |
| MP4 (`.mp4`) | Browser-compatible H.264/AVC profiles and pixel formats, with AAC-LC audio or no audio. | Required first format; validate actual content and desktop-browser playback. |
| WebM (`.webm`) | VP8/VP9 or AV1 Main 8-bit yuv420p video with Opus audio, or no audio. | Accepted through the native player and staging path; preserve documented browser/synchronization verification gaps. |
| Other combinations | HEVC/H.265, ProRes, MOV, MKV, AVI, or otherwise unverified container/codec combinations. | Initially reject with an actionable explanation. |

A filename extension does not establish codec compatibility. The initial pass does
not include transcoding, remuxing, or accepting every file whose name ends in
`.mp4` or `.webm`.

Use native HTML5 `<video>` with a thin browser adapter and the existing shared
controls. Do not implement a decoder or a separate JavaScript room-policy engine.
Video.js is an alternative if richer controls, accessibility features, or future
adaptive streaming justify its dependency and integration costs; it does not make
unsupported codecs universally playable. No new library installation is implied
by this plan.

Verify actual decoding, audio, and random seeking in current desktop Chrome, Edge,
Firefox, and Safari. `canPlayType` alone is not sufficient evidence.

Reference: [MDN media container formats](https://developer.mozilla.org/en-US/docs/Web/Media/Guides/Formats/Containers).

## Architecture and lifecycle

### Temporary staging

- Use a configurable private directory outside public static roots, restrictive
  permissions, generated filenames, and opaque room-scoped asset IDs.
- Keep only necessary ephemeral metadata: room, uploader, safe display filename,
  private path, actual byte count, validated codecs/duration, and lifecycle state.
- Do not add an object-storage service, persistent media volume, durable media
  catalog, or database media bytes. No database asset migration is assumed.
- Stream bytes to disk rather than holding whole files in application memory or
  sending them through Hologram state or room-control messages.
- Reserve the room's single slot atomically before accepting bytes. Incomplete,
  validating, ready, selected, and retired-but-still-open files count against it.
- Enforce actual received bytes, not only claimed Content-Length or client
  metadata. Bound per-room/global disk usage, upload concurrency, validator work,
  minimum free disk, upload stalls, and abandoned transfers.
- Validate content with bounded isolated ffprobe or an approved equivalent. Use
  local file inputs, prohibit arbitrary network access, and limit process time,
  output, concurrency, and memory. Avoid whole-file validation copies.

### Private delivery

Each participant independently streams the same staged file over an authorized
same-origin HTTP endpoint. Only authoritative playback controls travel over the
room channel. A local browser blob URL is not accessible to other participants.

Support GET and HEAD, byte-range requests with 206/Content-Range, correct media
headers and lengths, and invalid-range handling with 416. Check room membership
and file readiness on every new request, including range requests. Accountless
admitted guests must work. Opaque asset IDs alone are not authorization.

Prefer the existing verified browser/session identity. Use short-lived room-bound
local capabilities only if needed; do not introduce cloud signed-URL renewal.
Avoid public static delivery, credential/path leaks, and unsafe media caching.

### Strict one-file replacement

Uploaded-to-uploaded replacement cannot retain the old staged video while the new
one uploads. Provide explicit **Discard and replace** confirmation, explaining
that the old file will be removed and cannot be restored if the replacement fails.

After confirmation:

1. Authoritatively stop/clear the old staged source and retire its player generation.
2. Cancel old readers/transfers and release/delete the file.
3. Confirm the single slot is free before receiving replacement bytes.
4. Upload and validate the new file.
5. Automatically activate it through an authorized revisioned room command,
   paused at zero, and close the modal after acceptance. Retain **Use this video**
   for a selection retry or an existing staged file.

An open-but-unlinked file still consuming disk is not a free slot. Wait or reject
while resource release is pending; do not stage a second file. A cancelled pending
upload must likewise be cleaned before replacement.

YouTube can continue playing while the room's sole uploaded file is prepared.
Failure in that case leaves YouTube untouched. Chat and conferencing continue
through either replacement path. Switching to YouTube does not permit a second
staged file; free any retained staged file before the next upload.

### Cleanup and failure recovery

Track empty and idle deadlines server-side, with stale-timer and rejoin/activity
race protection. Cleanup must invalidate the staged source/generation and stop
obsolete media requests without disrupting chat or conferencing. Active playback
must not expire merely because nobody clicks controls, and an ended/paused stale
player must not claim perpetual activity.

Host departure alone does not delete media while guests remain; guest-only rooms
still follow the same empty/idle conditions. Cleanup after an hour without playback
or interaction must work even while those guests continue their voice/video call.

Use supervised sweeps for orphaned files and crash recovery. Restarts, deployments,
or machine replacement may lose staged media; do not promise persistence. Missing
files should produce clear unavailable/re-upload feedback and permit YouTube
selection, not endless retries. Define coordinator versus media-supervisor restart
ownership explicitly.

The initial design is node-local. Upload and media requests must reach the same
staging node. Future replicas require explicit routing or a redesigned delivery
strategy; local files must not be assumed shared.

## Implementation sequence

Implementation of the phases below is authorized and in progress. Completion and
verification evidence must be recorded separately; authorization is not a claim
that any phase or browser check has passed.

### 1. Finalize codec/player details and assess capacity

Confirm the recommended native player and supported codec/profile matrix, with
MP4 required and WebM prioritized if feasible without substantial expansion.
Inspect candidate fixtures rather than trusting their names:

- `sample-30s-720p.mp4`
- `sample-10s-h265.mp4`

The initial investigation started at 500 MiB; the owner has since approved 1 GiB.
Continue measuring deployment capacity before proposing further increases. Relevant inputs include:

- `fly.staging.toml`
- `Dockerfile`
- `lib/review_project_web/endpoint.ex`
- Runtime configuration and current hosting documentation.

The checked-in Fly configuration specifies one shared CPU and 1 GiB RAM with no
media volume. This does not establish available temporary disk or a safe file cap.
Local checkout free disk is not deployment-capacity evidence.

Compare the approved 1 GiB with candidate 2 GiB and larger limits where evidence
supports them. Budget temporary disk minus OS/app/log headroom across expected
concurrent rooms, plus bounded upload/validation overhead. Include HTTP/proxy
request and time limits, slow/interrupted upload and retry cost, validation CPU,
range/seek responsiveness, five-participant delivery bandwidth, egress, and
conferencing responsiveness. Separate accepted file size from bitrate-driven
streaming demand; RAM is not the file-size ceiling with bounded streaming.

Return a table of supported measurements, assumptions, unknowns, room concurrency,
and conservative recommended file/global caps. Ideal upload time is file bytes
times eight divided by available uploader bits per second. Complete delivery to
five participants can approach five times the file size before retries or repeated
seeks; actual traffic depends on viewing and buffering.

Use only authorized read-only inspection. Do not run deployment load tests,
provision resources, or automatically raise limits. Surface missing measurements
or infrastructure needs for approval. A higher safe limit has not yet been measured.

### 2. Build staging, validation, and HTTP delivery

Add the supervised room-scoped media boundary under `lib/review_project/` and
focused tests, following the architecture, quota, security, and lifecycle rules
above.

Important existing integration detail: `lib/review_project_web/endpoint.ex` parses
multipart before Phoenix router authentication. Authorization in a later controller
alone does not protect disk from large unauthenticated bodies. Design scoped
pre-body authorization/resource limits or a safely ordered streaming route while
preserving session and CSRF protections.

Place routes in explicitly documented session/current-scope-aware scopes in
`lib/review_project_web/router.ex`, with room/controller checks in the context.
Use appropriately typed accepts handling rather than exposing an unauthenticated
API. Preserve guest browser identity without requiring guest accounts. Document
exact pipeline/scope placement and rationale during implementation.

### 3. Generalize authoritative room sources

Use the production paths, not development-only YouTube sync spikes:

- `lib/review_project/rooms/timeline.ex`
- `lib/review_project/rooms/session.ex`
- `lib/review_project_web/channels/room_channel.ex`
- `lib/review_project/video_source.ex`

Introduce a tagged stable source descriptor, for example:

```elixir
%{kind: :youtube, id: youtube_id}
%{kind: :upload, id: staged_asset_id}
```

Resolve authorized delivery endpoints separately; never put filesystem paths or
access credentials into shared source identity. Validate room association,
readiness, and file existence before activation.

Retain controller ID, epoch, authority revision, playback revision, and player
generation protections. Recheck authority/revisions on activation so a delayed
upload cannot overwrite a newer choice or act after control changes. Keep late
joins/reconnects consistent with the selected source and cleanup state.

Preserve handoff after ten seconds of host absence and automatic host reclaim.
The guest controller does not become the room owner. Activation starts paused at
zero; strict discard-before-replace and missing-file cleanup must coordinate with
the staging supervisor and revisioned source state.

### 4. Add the in-call upload interface

Primary integration targets:

- `lib/review_project_web/hologram/video_panel.ex`
- `assets/css/`
- `lib/review_project_web/router.ex`
- `lib/review_project_web/endpoint.ex`

Add the requested button beside the URL/source field, accessible keyboard/dialog
behavior, supported-format/size guidance, progress, validation, cancel, retry,
errors, **Use this video**, and **Discard and replace**. Show safe filenames for
uploaded sources rather than constructing YouTube URLs. Explain temporary
availability and the exact empty/idle cleanup policy. Keep follower permissions
clear and preserve narrow-desktop usability.

Keep UI/progress policy in Hologram with a thin browser file/network adapter.
LiveView upload helpers must not be assumed to work in Hologram. Hologram commands
require their own middleware; Phoenix router scopes do not authenticate them.

Skip means seeking or selecting a replacement under existing controls, not a new
playlist/queue/automatic-next-video feature.

### 5. Connect native video to shared playback

Integration targets:

- `assets/js/playback_native.mjs`
- `lib/review_project_web/hologram/playback_state.ex`
- `lib/review_project_web/hologram/video_panel.ex`

Add a native HTML5 adapter alongside YouTube, normalizing readiness/metadata,
position/duration, playing/paused/ended, seeking, buffering, errors, play promise
rejection, sampling, volume/mute, and teardown. Reuse the existing playback policy,
not a second JavaScript state machine. Programmatic reconciliation must not echo
as user commands; ignore stale-source/player callbacks.

Synchronize controller play/pause, seeks/skips, replay, and source changes.
Followers do not control the room and reconcile to it. Volume, mute, and captions
stay local. One participant buffering, failing, or being autoplay-blocked must not
pause everyone; retain local enable/retry and catch-up behavior.

Apply clock/RTT-aware targets after readiness, late joins, reconnects, tab resume,
and buffering recovery. Report meaningful playback/user actions for cleanup,
not passive media or transport traffic. Release old elements, listeners, timers,
and HTTP readers on switch/leave without touching conference resources.

Retain existing acceptance targets:

- Settled p95 absolute timeline error and participant spread each at most
  **0.5 seconds**, based on player-reported position, not frame-accurate presentation.
- Recovery alignment within **five seconds** once transport/player are ready and
  local playback is enabled; preparation, buffering, and autoplay blocking are
  measured separately.
- Stop at the end; the controller may replay from zero or select another video.

### 6. Verify and prepare rollout

Extend existing suites and add focused temporary-media/HTTP tests:

- `test/review_project/rooms/session_test.exs`
- `test/review_project/video_source_test.exs`
- `test/review_project_web/hologram/playback_interaction_test.exs`
- `test/review_project_web/controllers/page_controller_test.exs`
- `test/js/playback_native_test.mjs`
- A real-room browser harness under `scripts/`.

Use disposable staging directories and deterministic clocks. Cover:

- Exact 1 GiB boundary/overflow and actual versus claimed bytes.
- Pre-body authorization, accountless guests, followers, cross-room access, and
  authority changes during upload/activation.
- Concurrent admission, retries, cancellation, stalls, disk exhaustion, one-file
  accounting, open readers, discard-before-replace, and no rollback promise.
- Corrupt/unsupported/HEVC rejection and validated MP4/WebM, including no-audio files.
- GET/HEAD/Range, 206/416, late/random seeking, and revoked or missing media.
- Both cleanup thresholds before/at/after deadlines, rejoin/activity races,
  heartbeat-only traffic, active playback, ended-player reports, and orphan sweeps.
- Ongoing conferencing for an idle hour without review-video playback or user
  interaction: staged media expires but room/chat/conferencing remain functional.
- YouTube/upload switching, host handoff/reclaim, late join, reconnect, stale
  generations, old-player HTTP teardown, and restart/deployment file loss.
- Five participants with chat and conferencing active, measured disk/memory/network
  use, and the existing drift/recovery targets in all four supported browsers.

Run targeted ExUnit/Node suites and `mix precommit` after code changes, reporting
blockers honestly. No tests or browser/capacity checks are claimed complete by
saving this document.

With implementation now authorized, update `docs/release-contract-v1.md`,
`README.md`, and operations documentation with approved source scope, codec matrix,
permissions, quotas, exact cleanup policy, temporary directory configuration,
restart re-upload behavior, single-node constraints, and verification evidence.
The current release contract still records the older YouTube-only scope; this
plan records the owner's requested scope change without claiming implementation.

Propose an upload configuration flag and safe disk/validation/cleanup/sync telemetry.
YouTube must remain usable with uploads disabled. Do not log private paths, media
credentials, or invitation fragments. Infrastructure expansion and deployment
require separate approval.

## Remaining technical decisions and evidence

- Exact verified codec/profile/pixel-format combinations and any WebM limitations.
- Final native-player versus library decision; native HTML5 is recommended.
- Measured global disk quota, free-space headroom, upload/validation concurrency,
  stall limits, and evidence-backed recommendations for future increases above 1 GiB.
- Concrete streaming-route/body-parser arrangement and guest media authentication.
- Safe single-slot reader cancellation, deadline race handling, and supervisor
  restart/orphan reconciliation details.

Approved retention thresholds, conferencing-independent idle semantics, one-file
quota, current-controller permission, and initial size cap are not open questions.
