# Temporary uploaded video: operations and evidence

> Historical: the approved direct-file sharing replacement supersedes this upload path.
> See [current operations](direct-file-sharing.md) and the [release contract](release-contract-v1.md).

Status: owner-approved for rollout on 2026-11-27; this update does not deploy it. The
[release contract](release-contract-v1.md) and [saved plan](uploaded-video-plan.md)
define the accepted product policy. This document distinguishes local evidence
from remaining verification follow-ups, which no longer block deployment.

## Rollout decision, 2026-11-27

The owner accepted the current local five-person H.264/AV1 results after the
playback corrections as sufficient for deployment. Outstanding browser coverage,
repeatability, long-file/device checks and hosted-capacity measurements are
follow-up work, not rollout prerequisites. This decision supersedes the earlier
upload-specific gating language retained in the historical evidence below; it
does not relabel failed runs as passes or change playback acceptance targets.

`fly.staging.toml` now sets `UPLOADED_VIDEO_ENABLED=true` for the next deployment.
Other release environments still opt in explicitly; unset or false disables
uploads. The 1 GiB per-file/global quotas, one concurrent upload, 1 GiB free-disk
reserve, validation, private delivery and cleanup rules remain in force. No
deployment, provisioning or remote configuration change was performed here.

## Upload overhead investigation, 2026-11-27

The owner reported multi-minute uploads in the deployed environment and requested
investigation before deciding whether to replace staging with host-device delivery.
No deployed timing, credentials, configuration or media were accessed in this
investigation; the measurements below are local controls, not staging results.

**Initial baseline, before optimization:** the raw HTTP receive loop reads at
most 256 KiB at a time. Before each read,
`same_authority/3` calls `Rooms.media_request/4`, then `Session.http_request/4`.
That handler calls `Store.open?/2`, which performs `Repo.exists?/1` against the
rooms table, before checking the live seat/controller and authority revision.
The append then runs `df -Pk` synchronously through `Media.free_bytes/1` before
writing. Consequently, 1 GiB in full-sized chunks requires about **4,096 serial
database round trips and 4,096 df subprocesses**, plus boundary checks. Smaller
reads can require more. This also occupies the room coordinator while each
database check completes.

`scripts/upload_overhead_benchmark.exs` decomposes these paths with actual Media
writes and room authorization calls, a local SQL sandbox whose fixture writes
roll back, and exclusive disposable media roots. It repeats each case three times
using a reusable 256 KiB binary; payload files are canceled/deleted. The delayed
cases inject an explicitly synthetic delay after every real local query. They do
not measure real remote database latency, HTTP/TLS/proxy behavior, WAN upload,
media validation or durable disk throughput. Fixed-free-space results are a
benchmark control only and do not change production admission checks.

| Case | Payload | Median elapsed | Measured work |
| --- | --- | --- | --- |
| Append with real df | 64 MiB | 321.728 ms | 256 df calls, median 297.944 ms inside disk checks |
| Append with fixed free-space control | 64 MiB | 9.752 ms | Same 256 writes, no df processes |
| Authorization + append, local database | 16 MiB | 96.398 ms | Exactly 64 real queries and 64 df calls |
| Same path + synthetic 20 ms/query | 16 MiB | 1,459.716 ms | Exactly 64 real queries and 64 df calls |
| Same path + synthetic 50 ms/query | 16 MiB | 3,388.521 ms | Exactly 64 real queries and 64 df calls |

Initial report: `/tmp/review-upload-overhead.json`. The extended harness now
reproduces legacy controls alongside the optimized paths below:

```sh
nix develop --command env MIX_ENV=test REPORT=/tmp/review-upload-overhead-optimized.json \
  mix run --no-start scripts/upload_overhead_benchmark.exs
```

At 4,096 chunks, database round trips alone add **81.92 seconds at 20 ms** or
**204.8 seconds at 50 ms**, excluding all transfer/writing work. These are
arithmetic examples, not measurements of the deployed database. The df work
projects to about five seconds per GiB on this workstation; a weaker VM may
differ. The serial database dependency is therefore the stronger candidate for
the reported minutes-long delay, and should be measured in staging before
attributing it to VM CPU or changing delivery architecture.

The initial investigation proposed separating durable room checks from live
authority checks, plus bounded disk accounting. It left runtime behavior
unchanged. The subsequent implementation is recorded below.

### Implemented optimization and local comparison

Upload continuation now uses `Session.http_request/4` with `:continue_upload`.
This checks the connected seat, enabled flag and current controller directly in
the live coordinator, returning the current epoch/authority revision for the
request's existing equality guard. It performs no SQL or database-backed
maintenance. Join, departure, replacement, handoff and normal room-close
notifications update/stop that same coordinator; routine maintenance still owns
timed transitions and expiry. Only the continuation path bypasses SQL: status,
stream admission and other room HTTP operations retain durable room checks.

The POST still queries durable room state at admission, after receiving bytes
before probing, and after probing before returning ready metadata. Thus the
normal upload has **three room-open queries**, independent of chunk count.
Database errors at those boundaries still fail the request. A delayed/missing
close notification can permit continued receiving until the boundary check, but
cannot publish a completed upload for a durably closed room. The design remains
single-node and relies on the live coordinator for prompt local revocation.

Media takes a fresh free-space measurement before each reservation, budgeting
the full declared size and all outstanding reserved bytes, and before validation
of a completely received file. Between observations it subtracts each successful
write from the last observed free space. Before another append it refreshes if
the measurement is **one second old**, the next write would exceed **32 MiB**
since the last measurement, or the remaining estimate cannot cover the write
above the reserve. Unknown/insufficient fresh results retire the partial file.
This bounds observation age/bytes during writing; unrelated processes can still
consume disk between measurements. File-write errors retain their cleanup path.
The 1 GiB reserve, file/global caps, concurrency and retention rules are unchanged.

Three-repeat comparison using real local authorization and writes:

| 16 MiB upload-loop case | Legacy median | Optimized median | Queries, legacy → optimized |
| --- | --- | --- | --- |
| Local database | 101.184 ms | 5.172 ms | 64 → 3 |
| Synthetic 20 ms/query | 1,468.677 ms | 68.060 ms | 64 → 3 |
| Synthetic 50 ms/query | 3,388.890 ms | 157.936 ms | 64 → 3 |

Optimized measurements include all three boundary queries, completion's fresh
disk check and a stubbed probe; legacy controls force the original per-chunk df
and durable-authority checks. Both exclude initial media reservation and actual
format probing. The optimized 16 MiB cases made one measured df call, plus the
unmeasured reservation check; the 64 MiB case took **14.957 ms** with three
queries and two measured df calls, plus reservation. Network, proxy, real format
validation and actual Fly performance remain outside this comparison. Report:
`/tmp/review-upload-overhead-optimized.json`. No deployment was performed.

Regression coverage checks SQL-free continuation, fixed boundary-query count,
departure/handoff revocation, durable closure during validation, byte/time disk
refresh bounds, unknown/insufficient disk results and completion cleanup. Existing
real transport and coordinator-restart coverage remains green. `mix precommit`
passed **474 tests** after these changes.

## Current policy: 1 GiB and AV1 accepted

On 2026-11-27, after reviewing the local original-file results below, the owner
approved **1 GiB (1,073,741,824 bytes) per file** and accepted **AV1 Main 8-bit
yuv420p WebM with Opus or no audio** for normal uploads. The experimental probe
opt-in has been removed; the normal validator accepts that combination.
Configuration, controller fallback, client fallback and upload guidance now use
the approved cap. The isolated verification server uses these normal defaults.

The global staged quota stays **1 GiB**, so one full-cap file consumes it; the
separate **1 GiB non-media disk reserve** and one-at-a-time receiving/validating
limit remain. Releases retain explicit enablement; staging is configured on for
its next deployment. Existing browser/capacity gaps and the recorded five-person active-call
failure remain evidence for follow-up, not reasons to keep AV1 disabled. This
decision does not relabel failed checks as passes or relax synchronization targets.
Historical investigation and recommendations below describe the earlier policy;
this section and the release contract supersede them.

Post-acceptance verification used the normal policy with no probe or cap
overrides: the original **775,550,155-byte AV1/Opus file** passed actual upload,
automatic selection/modal closure, private ranges, decoded audio/video, long
seeks, pause/discard/replacement and final staged-file cleanup in a two-Chrome
room. The server advertised exactly **1,073,741,824 bytes**. Initial p95 drift
was **0.129 s**, maximum spread **0.031 s**; start/middle/end seek convergence
took **0.780 / 0.770 / 0.784 s**. Report: `/tmp/review-av1-approved-report.json`.
`nix develop --command mix precommit` passed **464 tests**, and the JavaScript
and harness unit checks passed **28 tests**, including exact-1-GiB acceptance
and one-byte-over rejection without allocating full-size fixtures. Existing
running development servers must restart to pick up changed upload configuration.

## Usage and retention

Outside a room, **Upload video** opens room-staging guidance and a **Create a
room** action instead of silently doing nothing. No file chooser or media request
is started from the personal workspace. Unjoined/disconnected participants and
followers see an explanation beside the disabled upload entry.

Join the room first to choose a file. The current playback controller (host, or
authorized guest after ten seconds of host absence) can open **Upload video**
beside the source field, after **Switch video** during playback. Upload a
compatible MP4 or WebM; validation automatically selects it and the modal closes
when the room accepts it, paused at zero for review. **Use this video** remains
available for an existing staged file or a selection retry.

One file total is allowed per room, including partial, validating, ready, selected
and retiring files with readers. **Discard and replace** stops/deletes the old
upload before accepting another; a failed replacement cannot restore it. YouTube
may continue during upload; switching to YouTube does not free the staged slot.

Media expires after five continuous minutes empty **or** one hour without video
playback or deliberate user interaction, regardless of conferencing. Chat and
intentional device/playback actions reset idle; camera/microphone streams,
signaling, polls, heartbeats, and upload progress do not. Cleanup never closes the
room, deletes chat, or stops conferencing. Restart/deployment/file loss requires
re-upload; there is no occupied-session duration cap or durable media library.

## Formats and player

| Container | Accepted video | Accepted audio | Verification boundary |
| --- | --- | --- | --- |
| MP4 | H.264 baseline/constrained baseline/main/high, yuv420p | AAC-LC or none | Container brand/codecs/duration inspected; local Chrome/Firefox H.264/AAC decode/seek measured below, other browser/profile/audio combinations remain unverified |
| WebM | VP8/VP9 or AV1 Main, 8-bit yuv420p | Opus or none | EBML WebM doctype required; local Chrome/Firefox VP9 and original-file AV1/Opus decode/audio/seek measured below; other combinations/browsers remain unverified |
| Other/HEVC | Rejected | — | Renaming MOV/MKV/HEVC to `.mp4`/`.webm` does not bypass inspection |

Native HTML5 video uses the existing Elixir timeline/reconciliation and controls;
YouTube retains its embedded player. No player library or transcoding dependency
was added. ffprobe metadata validation is not proof of decoding every frame,
fast-start layout, seek quality, or browser codec support. Local mute/volume and
blocked/buffering-player recovery remain participant-local.

## Configuration and private disk

| Setting | Current value |
| --- | --- |
| `:uploaded_video, :max_file_bytes` | 1,073,741,824 (1 GiB, owner approved) |
| `:max_total_bytes` | 1,073,741,824 (1 GiB reserved staged bytes globally) |
| `:max_uploads` | 1 receiving/validating file globally |
| `:min_free_bytes` | 1,073,741,824 (1 GiB non-media free reserve) |
| `:max_chunk_bytes` | 1 MiB service bound; HTTP reads/writes 256 KiB |
| `:upload_timeout_ms` | 120,000 without appended bytes |
| `:probe_timeout_ms` | 15,000 service deadline; native process deadline 12 seconds |
| `:sweep_interval_ms` | 10,000 for stalled uploads/retiring resources |
| `:free_check_bytes` | 33,554,432 (32 MiB written between fresh disk checks) |
| `:free_check_interval_ms` | 1,000 (refresh before appending once the observation is this old) |

These global limits are conservative **unmeasured engineering guardrails**, not
measured Fly capacity or an approved increase of the per-file cap. Ready files
consume reserved quota; only one upload validates at a time. Files stream to disk
without whole-file buffers/copies. Disk failures fail closed.

Development/test enable uploads; releases default **off** unless explicitly
enabled. Rollout is approved and staging sets `UPLOADED_VIDEO_ENABLED=true`.
Set it to `false` to disable uploads on a subsequent deployment. The production
`UPLOADED_VIDEO_ROOT` defaults to `/tmp/review-project-media`. It must be an
exclusive, private, node-local directory outside static roots, never shared with
another BEAM/OS process or replica. Do not point it at a directory containing
valuable files: orphan `.stage` files are disposable and swept. Symlink ancestors
are rejected. Directory/file modes are 0700/0600.

The service requires Linux `/proc/self/fd` for restart descriptor fencing and
`df -Pk` for free-space checks; missing support fails admission closed. Old open
orphan/deleted-file descriptors block new reservations until closed, rather than
quietly permitting two physical files. HTTP readers monitor the exact coordinator
PID and close descriptors before releasing their lease. The room supervisor uses
`rest_for_one` with Media before session supervision so a media-service restart
also invalidates live room coordinators. A full OS/BEAM restart loses sessions and
staged content; an application-only restart fences surviving readers first.

The runtime image definition now includes ffmpeg (for ffprobe), GNU coreutils
(timeout/df), and util-linux (prlimit). The image has not been built/deployed by
this work. The validator permits only local file protocol and approved demuxers,
limits CPU/address space/descriptors/output/analysis/time, and performs no
transcoding. A killed probe worker's native subprocess may survive until its
independent 12-second timeout; do not claim immediate process-group cancellation.

This design is single-node. Scaling requires sticky room/media routing or a
separately reviewed delivery architecture; node-local files do not become shared
by adding replicas.

## HTTP/authentication boundary

Routes live in the Phoenix `/room-media` controller scope with a dedicated
`:room_media` pipeline: fetch signed session, CSRF protection, secure browser
headers, and `fetch_current_scope_for_user`. There is no LiveView `live_session`
and no login-only redirect because admitted accountless guests must stream.
The room coordinator verifies a currently connected host scope or the signed
room-specific guest browser identity; client IDs/roles/PIDs are never authority.
Hologram command middleware remains separate and unchanged.

Endpoint parsing explicitly leaves **all** `/room-media` bodies unread, avoiding
multipart disk spooling ahead of authorization. POST accepts raw octet-stream;
DELETE parses only a bounded 4 KiB JSON body after controller authorization.
Mutations retain header CSRF. Authentication/quota checks happen before body
reads. Live upload authority is checked in memory before each body chunk;
durable room checks run at admission, after receiving, and after probing.
Changed epoch/authority revision rejects completion. Activation uses the normal
controller/epoch/authority/playback-revision guards.

| Method/path | Contract |
| --- | --- |
| `GET /room-media/:room` | Membership-only status: `staged`, `max_file_bytes`, `enabled` |
| `POST /room-media/:room` | Controller-only raw File body; URI-encoded `x-video-filename`, decimal `x-video-size`, `x-csrf-token`; returns ready metadata after validation |
| `DELETE /room-media/:room` | Controller-only JSON epoch/authority_revision/revision; guarded discard; channel `discard_upload` is preferred |
| `GET` / `HEAD /room-media/:room/:asset` | Membership-authorized full or single-byte range; 206/Content-Range or 416; private no-store |

No paths or secrets appear in public metadata. Multiple ranges are deliberately
rejected with 416, not assembled into memory. Retirement cancels streaming at the
next chunk boundary; a backpressured request can retain its lease longer, and the
slot remains occupied until it closes. Error details expose policy codes, not
filesystem paths.

## Historical capacity investigation: initial 500 MiB cap

Repository evidence: `fly.staging.toml` configures one shared CPU and 1 GiB RAM,
without a media volume. This does **not** establish temporary disk availability.
Actual deployed free disk, proxy/body/time limits, sustained throughput, egress
budget, and responsiveness during conferencing are **unknown**. No remote load
tests, provisioning, or deployment were performed or authorized.

Ideal transfer arithmetic (decimal link Mbps, no protocol overhead, retries, or
contention) illustrates costs, not hosting capacity:

| Candidate cap | Upload at 20 Mbps | Upload at 100 Mbps | Five complete reader transfers | Current 1 GiB staged quota |
| --- | --- | --- | --- | --- |
| 500 MiB | 3m 30s | 42s | 2.44 GiB | At most two full-cap ready rooms, one upload globally |
| 1 GiB | 7m 10s | 1m 26s | 5 GiB | One file consumes the entire quota; now the approved cap |
| 2 GiB | 14m 19s | 2m 52s | 10 GiB | Exceeds quota; not enabled |

Admission also requires the 1 GiB non-media reserve plus all promised unreceived
bytes. Five independent viewers can multiply delivery by five before seeks and
retries. Sustained streaming demand depends on bitrate and concurrent viewers,
not file size alone; bounded memory does not make disk/egress unlimited. Larger
files increase transfer interruption/retry exposure and request-duration needs.

**Original recommendation (superseded by the owner decision above):** retain 500 MiB and production opt-in pending deployment
capacity evidence. The local sample check below establishes feasibility of larger
files in the staging service, not a safe deployed ceiling. Before enabling 1 GiB
or 2 GiB, separately authorize guest
disk/headroom inspection and local-to-deployment upload/seek/five-reader tests;
measure validation CPU, memory/disk, proxy timeouts, bitrate/egress and conference
latency. Do not extrapolate from checkout free space, shared CPU count, or RAM.

### Owner's larger sample, 2026-11-27

The repository-root `SSBM…[HeX8SlPzlXI].webm` is **775,550,155 bytes
(739.62 MiB)** and **2,424.181 seconds (40m 24s)**. Local ffprobe inspection
reports **AV1 Main, yuv420p, 1280×720, 60 fps**, with **Opus** audio and average
container bitrate **2.559 Mbps**. At the time of the initial investigation, two independent policies rejected it:
the 500 MiB file cap and the WebM VP8/VP9 codec allowlist. Raising the cap alone
would not make this exact sample accepted. `MediaProbe.probe/1` returned
`{:error, :unsupported_media}` in **82 ms** using its existing bounded probe.

A disposable local Media service with only its per-file cap overridden to
**1 GiB** reserved and staged all **775,550,155 bytes** through the real 256 KiB
append path, including the real per-chunk `df` free-space checks, in **4.162 s
(177.7 MiB/s)**. The real validator then rejected AV1 in **81 ms**, removed the
staged copy and left no room reservation or files. Application limits and the
original sample were unchanged. Report: `/tmp/review-large-upload-check.json`.
This measures local file staging and validation rejection only: no HTTP upload,
AV1 browser decoding, long-distance seeking, conference load, memory profiling,
or deployed throughput was tested.

There is no product-length limit in the upload validator or player; accepted
prerecorded duration is metadata and playback remains range-streamed. The probe
inspects a bounded amount of metadata instead of decoding the entire recording.
Longer files therefore do not require an architectural rewrite, though actual
decode/seek behavior still needs verification. This sample's rejection is not
caused by its 40-minute duration.

Implementation difficulty and a concrete next step:

- **Larger supported-codec files:** small configuration/UI work for a candidate
  **1 GiB** cap (about 38% above this sample). Keep service/controller/client
  limits consistent and make the dialog's currently literal size guidance follow
  configuration. At the existing global 1 GiB quota, one such near-cap file can
  exclude other rooms; choosing a larger global quota needs measured disk headroom
  while preserving the 1 GiB non-media reserve.
- **This exact AV1 sample:** the allowlist edit is small, but support is a separate
  codec decision. Verify real decode/audio/seek and synchronized playback at the
  start, middle and end in all supported browsers and representative hardware.
  If that is not viable, supply an H.264/AAC MP4 or VP9/Opus WebM externally;
  server-side transcoding remains outside the release contract. No conversion
  or AV1 support was enabled by this investigation.
- **Reliable long uploads:** the current single XHR has no resumable/chunked-upload
  protocol. Continuous uploads are not capped at two minutes; that service timer
  concerns absent appended bytes, while HTTP body reads have a 15-second read
  timeout. A lost connection retries the whole file. Verify proxy deadlines and
  interruptions on the actual hosting path before a cap increase; resumable
  uploads would be a larger follow-up than changing limits.

Ideal transfer time for the actual sample is **5m 10s at 20 Mbps** or **62s at
100 Mbps**. Five complete reader transfers total **3.61 GiB** and average about
**12.8 Mbps** at this sample's bitrate, before seeks/retries/overhead and separate
conference traffic. These are arithmetic estimates, not deployed measurements.
The investigation supports trying a 1 GiB cap in an isolated end-to-end capacity
run with a supported-codec long fixture; it does not approve a higher production
limit or AV1 compatibility.

### Upload completion and button order, 2026-11-27

Newly validated XHR completions now automatically submit the guarded room
selection. The upload dialog closes only after that upload is accepted; failed
selection keeps the file and error available for retry. Merely opening or
refreshing staged status never switches playback. Existing staged files retain
**Use this video**. During playback the header order is source, **Switch video**,
then **Upload video**. Earlier browser evidence below records the previous
explicit-selection flow and should be read as historical behavior.

Verification of this update: `nix develop --command mix precommit` passed **462
tests**; the JavaScript and harness unit checks passed **27 tests**. The real
two-participant Chrome 158 run with `sample-30s-720p.mp4` passed initial upload
and replacement auto-selection/modal closure, header ordering, reopening staged
status without selection, private 206 delivery, shared pause, Keep video,
confirmed discard and replacement. Its 60 settled samples measured **0.108 s
p95 absolute drift**, **0.060 s maximum spread**, and **0.779 s seek recovery**.
Report: `/tmp/review-upload-flow-report.json`. Devices were off; this is not
long-file or deployed capacity acceptance. An initial overlapping run was
interrupted by the development server reloading during precommit compilation;
the successful run began after compilation finished.

## AV1 verification, 2026-11-27

The owner requested AV1 verification because it is common in yt-dlp output.
The current [yt-dlp format-sorting documentation](https://github.com/yt-dlp/yt-dlp#sorting-formats)
ranks AV1 before VP9/H.264 when earlier sorting criteria are equal; source,
resolution, frame rate and other preferences can still change the selected format.
No download or YouTube extraction was performed in this investigation.

The original experiment used an explicit `allow_av1: true` probe opt-in for
WebM AV1 Main, 8-bit yuv420p, with Opus or no audio, while normal uploads still
rejected AV1. Following owner acceptance, that opt-in was removed and `probe/1`
and `validate/1` accept this combination normally. Tests require acceptance and
continue rejecting other profiles, 10-bit pixels, unverified/MP4 containers,
unsupported audio and extra streams. The existing bounded ffprobe process is
reused; no decoder or transcoder was added to the server.

The reusable `scripts/av1_verification_server.exs` starts an isolated loopback
development app, requires a disposable `review_av1_` database name, generates a
private temporary media root and synthetic local login, and uses the normal
**1 GiB/AV1** upload policy. Earlier runs used temporary overrides for that same
policy. It cannot run in production. No new route,
Phoenix pipeline, authentication scope or Hologram middleware was introduced.
The existing membership-authorized `/room-media` transport and production room
components are exercised as they are normally used.

### Original-file browser results

The **original 775,550,155-byte, 2,424.181-second AV1/Opus WebM** was selected
through the real file chooser and raw XHR on loopback port 4482. No remux,
conversion, clipping or debugger byte injection was used. Chrome was
**158.0.8127.36** on Linux; Firefox was **160.0.1** on Linux. The Chrome profile
was headless with `--disable-gpu`. These are local observations, not deployment
capacity, hardware-decoder or all-device guarantees.

The two-person Chrome-host/Firefox-guest run **passed** upload/validation,
automatic selection/modal closure, membership-authorized 206 reads, decoded
frames, shared pause/seek, staged-state reopening, Keep video, confirmed discard
and replacement. Upload-to-selection took **5.165 s** on loopback. Initial
settled playback yielded **60 samples, 0.064 s p95 absolute drift and 0.032 s
maximum participant spread**; initial native seek convergence took **0.780 s**.

Additional checkpoints used native controller seeks and required the authoritative
target to move to the requested timeline, new decoded frames, all players ready
and playing, and nonzero Opus PCM through Web Audio on both participants:

| Position in recording | Seek convergence | p95 absolute drift | Maximum spread |
| --- | --- | --- | --- |
| 0:30 | 0.771 s | 0.101 s | 0.080 s |
| 20:12.091 | 0.618 s | 0.124 s | 0.108 s |
| 39:59.181 | 0.622 s | 0.126 s | 0.159 s |

Each checkpoint collected 24 settled player samples over approximately 2.4
seconds. Nonzero decoded audio is not a claim about audible speakers. Cumulative
dropped-frame counters were nonzero, especially in Firefox; this does not
establish perfect 60 fps presentation. Both browsers predicted supported/smooth
but not power-efficient decoding; capability API predictions were supplementary
to actual playback. The run did not play the entire 40 minutes continuously,
measure A/V lip sync, or test HDR, 10-bit AV1, AV1 MP4, other resolutions/hardware,
late join, tab resume or reconnection. Report: `/tmp/review-av1-mixed-report.json`.
Firefox's process stderr later included BiDi internal warnings and Hologram
script-timeout warnings; the passing report did not classify these as application
errors. This remains a browser/harness diagnostic caveat, rather than proof of
error-free behavior outside the measured checks.

The five-Chrome **active synthetic conference** run **failed** the unchanged
maximum-spread gate: **0.745 s**, compared with **0.5 s** required. Its p95 absolute
timeline drift was **0.177 s** across 150 samples. All five players reported ready
and playing throughout that window; all 20 directed peer observations had
advancing inbound/outbound audio/video RTP, and chat reached all five people.
Upload/validation/modal closure/private ranges succeeded; upload-to-selection
took **5.925 s**. The harness correctly stopped at the failed spread assertion,
so it did **not** establish five-person long-seek or decoded-PCM acceptance.
No application errors were reported. Codec load, browser scheduling, harness
observation cost and existing room synchronization have not been isolated as
causes. Report: `/tmp/review-av1-five-active-report.json`. Do not treat the
two-person pass or good p95 drift as an active-call acceptance pass.

A separate five-Chrome **devices-off** comparison **passed**, with **150 initial
samples, 0.106 s p95 absolute drift and 0.073 s maximum spread**. Initial native
seek convergence was **1.126 s**. At 0:30, 20:12.091 and 39:59.181, seek
convergence took **0.994 / 0.948 / 1.107 s**; checkpoint p95 drift was
**0.111 / 0.130 / 0.196 s** and maximum spread **0.085 / 0.098 / 0.168 s**.
Each checkpoint sampled all five players 12 times and confirmed new decoded
frames and nonzero audio PCM on all five. Replacement cleanup released the
staged quota. This comparison shows that five-way AV1 playback can meet the
targets here without active capture/mesh load; it does not identify the cause
of the active-call failure. Report: `/tmp/review-av1-five-devices-off-report.json`.

### Browser boundary and recommendation

- [Chromium lists WebM, AV1 and Opus decoding](https://www.chromium.org/audio-video/).
  Actual Chrome playback of this file passed locally as described above.
- [Mozilla documents AV1 in WebM and MP4](https://support.mozilla.org/en-US/kb/audio-and-video-firefox).
  Actual Firefox playback of this WebM passed locally as described above.
- [Microsoft lists AV1 support in Edge](https://learn.microsoft.com/en-us/troubleshoot/microsoft-edge/development/video-playback-issues),
  with hardware acceleration dependent on the device/GPU. Edge was unavailable
  here; Chromium evidence is not an actual Edge acceptance run.
- [WebKit documents AV1 on devices with hardware decoding](https://webkit.org/blog/14445/webkit-features-in-safari-17-0/).
  Its [current Cocoa AV1 implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/platform/graphics/cocoa/AV1UtilitiesCocoa.mm)
  still checks VideoToolbox hardware-decoder availability. Safari was unavailable
  on this Linux host. A current browser version alone therefore cannot establish
  AV1 compatibility on Macs without that decoder. Safari WebM/Opus/AV1 must be
  exercised on actual supported Macs; no blanket Safari support is established.

**Original recommendation, before owner acceptance:** AV1 is technically viable through the existing native player
and private delivery architecture, with no application transcoding needed on the
verified Chrome/Firefox systems. It is not ready for unconditional acceptance
under the current four-browser and five-person active-call contract. Resolve the
active-call synchronization failure, verify Edge and representative Safari
hardware, and explicitly decide how to handle an incompatible room participant
before enabling normal AV1 uploads. Capability checks and an actionable local
message can explain unsupported playback; they cannot make a single AV1 file
decodable by every participant. Supporting a fallback encoding would require
reconsidering the no-transcoding/one-physical-file constraints. The owner has
since accepted normal AV1 uploads and the 1 GiB cap as recorded above; these
measured limitations remain visible for follow-up.

### Reproducing the isolated experiment

Use the Nix environment and disposable local profiles with Chrome debugging on
9242 and Firefox BiDi on 9243. In separate terminals after local PostgreSQL starts:

```sh
PGDATABASE=review_av1_verify mix ecto.create
PGDATABASE=review_av1_verify mix ecto.migrate
PGDATABASE=review_av1_verify HOLOGRAM_START=1 PORT=4482 \
  PLAYBACK_FIXTURE=/tmp/review-av1-fixture.json \
  mix run --no-start --no-halt scripts/av1_verification_server.exs
```

```sh
APP_URL=http://localhost:4482 CHROME_DEBUG_URL=http://127.0.0.1:9242 \
  FIREFOX_DEBUG_URL=ws://127.0.0.1:9243/session MIXED_FIREFOX=1 \
  PLAYBACK_FIXTURE=/tmp/review-av1-fixture.json \
  MEDIA_FILE="/absolute/path/to/recording.webm" LONG_MEDIA_CHECKS=1 \
  PARTICIPANTS=2 REPORT=/tmp/review-av1-mixed-report.json \
  node scripts/uploaded_video_browser_test.mjs
```

For the five-Chrome comparison, omit mixed/Firefox settings and use
`PARTICIPANTS=5`, optionally `ACTIVE_CONFERENCE=1`. Refresh the login fixture using
`scripts/playback_fixture.exs` before each new login attempt with the same
`PGDATABASE`. The harness reads the local server's advertised size cap; it does
not alter it. It now removes its successful replacement file before exiting to
free staged quota. Failure reports retain metrics, sampled playback rows and
diagnostics. Failed runs can leave staged media until normal cleanup; restarting
only the isolated verification server creates a fresh private root. Do not run
precommit/dev compilation concurrently with browser checks because development
reloads invalidate timing evidence. Stop only the test servers/profiles you start.

Regression checks after this work: `nix develop --command mix precommit` passed
**464 tests**; `nix develop --command node --test test/js/*.mjs
scripts/uploaded_video_browser.test.mjs` passed **27 tests**. These green checks
do not override the failed five-person active-call browser gate above.

## Active-call playback investigation, 2026-11-27

The owner requested local work on the five-person playback failures, leaving
deployment and broader browser/capacity testing for staging. Reproductions used
the real room and private media endpoints on an isolated local app/database,
Chrome 158 headless with GPU disabled, five browser identities, synthetic
microphones/cameras and UI-sent chat. No deployment was performed.

The original 740 MiB AV1 sample was no longer present in the checkout. The AV1
comparison therefore uses an explicitly different generated fixture:
`/tmp/review-sync-720p60-av1.webm`, **60.008 seconds, 39,506,036 bytes**, AV1 Main
8-bit yuv420p, 1280×720 at 60 fps with Opus, about 5.27 Mbps. The H.264 comparison
uses the existing `sample-30s-720p.mp4`. This is not a repeat of original-file
capacity or long-recording acceptance.

### Reproduced behavior and correction

The H.264 baseline recovered its follower in **0.759 s** after **7.994 s** of
transport/readiness setup, so the historical 7.360-second convergence failure
was not reproduced in that attempt. It did reproduce active-call instability:
the fourth timing row contained a buffering follower. Player-event diagnostics
showed automatic correction seeks recurring about once per second, each causing
roughly 0.1–0.2 seconds of seek/decode waiting. A player could remain over the
0.2-second correction threshold because each seek itself incurred comparable
delay, causing another seek rather than settled playback. The generated AV1
baseline also failed on buffering, in its third timing row.

The harness now retains raw sampling timestamps, readiness/seeking state,
presented-frame counts, local correction speed, bounded player-event/command
history and browser long-task diagnostics. It preserves the first failed row.
Cross-player sampling skew was under 1 ms in the H.264 baseline and reached
16.6 ms in the short AV1 baseline; these observations do not explain away the
actual seek/wait events. Common-time projected metrics are supplementary
diagnostics only; the existing raw-position acceptance assertions remain.

Uploaded videos now use local **0.95× / 1× / 1.05×** speed correction for modest
playing drift, restoring normal speed inside a 0.1-second deadband, when paused,
or when making a hard seek. Large errors above 0.5 seconds and explicit room
seeks retain hard correction. Explicit uploaded-video seeks bypass the routine
500 ms check interval on the next fresh sample. YouTube retains its existing
seek-based drift correction. Playback policy remains in Elixir; JavaScript only
reads/applies the native element's playback rate. No room-wide speed command or
conference-track change was introduced.

Regression tests exercise correction in both directions, return to normal speed,
hard/explicit seeks, pause behavior and native-source replacement. The harness
also rejects a seek-recovery observation arriving after the five-second deadline,
even if its delayed debugger reply reports aligned players.

### Local comparison results

The first corrected H.264 active-call/reconnect run **passed**, with **150 settled
samples, 0.309 s p95 absolute drift, 0.129 s maximum raw participant spread**,
**0.867 s ready/enabled follower convergence** and **1.312 s native-seek
recovery**. Transport/readiness setup was **8.381 s**, reported separately.
During the settled sample window, diagnostics recorded **no corrective seeks and
no waiting events** on any player. All five participants had advancing
inbound/outbound audio/video RTP on their four peers, and chat reached all five.
Report: `/tmp/review-sync-h264-corrected.json`. Baseline reports are
`/tmp/review-sync-h264-baseline.json` and `/tmp/review-sync-av1-baseline.json`.

The corrected generated-AV1 active-call/reconnect run also **passed**: **150
samples, 0.256 s p95 absolute drift, 0.143 s maximum raw spread**, **0.971 s
ready/enabled follower convergence**, and **0.949 s native-seek recovery**.
Transport/readiness setup was **8.000 s**, separate from convergence. This run
likewise recorded **no corrective seeks or waiting events during the settled
window**, with advancing conference RTP and chat delivered to all five.
Report: `/tmp/review-sync-av1-corrected.json`.

An H.264 repeat subsequently **failed** on buffering in its fourth timing row
(`/tmp/review-sync-h264-repeat.json`), despite ready/enabled reconnect convergence
of **3.124 s**. Diagnostics exposed a second issue after rapid shared
pause/resume: the previous pause's 1.5-second transport retry timer could delay
the newly accepted resume, leaving a follower far enough behind to seek again.
An accepted uploaded-video play/pause change now resets that retry timer and the
routine correction interval. Retries of an unchanged transport intent remain
throttled. A regression test reproduces the delayed resume before the fix and
passes afterward. The earlier passes alone did not establish repeatability.

With both corrections applied, the final H.264 run **passed** with **150 samples,
0.384 s p95 absolute drift, 0.334 s maximum raw spread**, **0.848 s ready/enabled
follower convergence** and **0.983 s native-seek recovery**. Transport/readiness
setup was **8.220 s**. Report: `/tmp/review-sync-h264-final.json`.

The final generated-AV1 run also **passed** with **150 samples, 0.480 s p95
absolute drift, 0.377 s maximum raw spread**, **0.893 s ready/enabled follower
convergence** and **1.048 s native-seek recovery**. Transport/readiness setup was
**8.187 s**. Report: `/tmp/review-sync-av1-final.json`. Both final runs retained
the original raw-position thresholds and verified advancing conference RTP and
chat delivery across all five participants. AV1's p95 is close to the
0.5-second boundary; these passes are evidence of improvement, not sufficient
margin or repeatability to close staging/browser readiness.

The AV1 comparison's maximum sampling skew was **33.2 ms**; its supplementary
common-time projected spread was **0.143 s**. The H.264 comparison's skew was
**21.1 ms**, projected spread **0.109 s**. Both passes use the unchanged raw
spread assertions, not these projected diagnostics. The fix addresses observed
seek-induced waiting; the timing hypothesis did not justify dismissing the
baseline failures.

These are local synthetic-call observations on one workstation. They do not
establish separate-device behavior, audible output, production-release or hosted
capacity acceptance, and they do not remove the earlier failed measurements.
Final validation: `mix precommit` passed **468 tests**, and
`node --test test/js/*.mjs scripts/uploaded_video_browser.test.mjs` passed
**30 tests**. The isolated app/browser were stopped after verification.

## Verification record and follow-up checks

Local verification on 2026-11-27:

| Check | Result | Scope |
| --- | --- | --- |
| `nix develop --command mix precommit` | 461 passed, seed 514036 | Compilation/warnings, formatting, full ExUnit suite |
| `nix develop --command node --test test/js/*.mjs` | 21 passed | Native player, suspension/page-restoration/stale play rejection, upload XHR/correlation/error persistence, conference adapter regressions |
| `node --test scripts/uploaded_video_browser.test.mjs` | 6 passed | Loopback URL guard, drift/spread, seek-target convergence, and advancing RTP evidence validation |
| Real Bandit transport tests (included in ExUnit) | 3 passed | Signed guest authorization, full/HEAD/206/416 lengths and bodies, partial-response retirement/coordinator death |

Automated suites cover media quota/owner/stall/crash/descriptor fencing,
actual ffmpeg-generated MP4/WebM metadata, unsupported/corrupt containers,
authority/handoff/cleanup boundaries, and authenticated raw HTTP/ranges/CSRF.
The Bandit tests use an ephemeral local listener and sparse backpressured files;
retirement and coordinator death close the connection before the advertised body
length, without treating a pipelined request as a successful keepalive response.
Exact 1 GiB reservation/overflow tests do not allocate a 1 GiB fixture and do
not demonstrate end-to-end maximum-size transfer throughput.

### Local Chrome room measurements

The production Hologram room and real private media endpoints were exercised in
Chrome 158.0.8127.36, with five isolated browser contexts (one host and four
admitted guests). The local app used a disposable database and private media root
on loopback port 4481. Each run collected 30 rounds / 150 player samples over
approximately six seconds after all players were ready, locally enabled and
playing. These are player/timeline measurements, not frame-accurate synchronization.

| Fixture | File bytes | p95 absolute timeline error | Maximum participant spread | Preliminary seek timing (not acceptance) |
| --- | --- | --- | --- | --- |
| `sample-30s-720p.mp4`, H.264/AAC-LC, 1280×720, 30.440998 s | 19,472,924 | 0.180 s | 0.098 s | 1.854 s |
| Generated VP9 WebM, no audio, 160×90, 20 s | 215,150 | 0.049 s | 0.020 s | 0.317 s |

Both runs passed the 0.5-second settled error/spread thresholds in this narrow
local scenario. **The historical seek timings above are withdrawn as recovery
acceptance:** review found that the old predicate could accept alignment on the
pre-seek timeline. The current harness focuses the controller's native player and
requires the authoritative target to move to the new seek timeline as well as
player convergence; a regression rejects obsolete-timeline alignment. No product
change or relaxation of the five-second target was made for this correction.
These earlier runs used the actual file chooser and raw File XHR,
verified validation without automatic selection, explicit **Use this video**,
follower-authorized 206 ranges, decoded frames, shared pause, **Keep video**,
confirmed discard, native-player disposal, an empty server slot, and replacement
upload. JSON reports were written to `/tmp/uploaded-video-five-h264-aac-report.json`
and `/tmp/uploaded-video-five-webm-report.json`; these are disposable local
artifacts, not deployment telemetry.

**Limits of those earlier runs:** camera/microphone devices were off. They did not
measure active conferencing, audible output, other browsers, late joins, reconnects,
tab resume, or maximum-size throughput. The initial app-launch attempt omitted
`HOLOGRAM_START=1` and returned 404; successful runs explicitly enabled Hologram.
A preliminary base64/CDP upload timed out; the reusable harness uses the real file
chooser instead of copying fixture bytes through debugger evaluation.

### Upload-dialog presentation regression

The upload dialog is a separate `UploadDialog` presentation component; upload
state and actions remain in `VideoPanel`. It has grouped format/size details,
spaced retention copy, wrapping filenames and a distinct destructive confirmation.
The original markup's always-visible native progress element reproduced the grey
160×16-pixel rectangle in Chrome and Firefox, including at zero progress. Idle,
error and ready states now omit it; transfer progress is an explicitly styled
5-pixel green track.

Presentation harness: `scripts/upload_dialog_browser_test.mjs` (use `BROWSER=chrome`
or `BROWSER=firefox`, the corresponding debugger URL, `APP_URL` pointing to a local
app, and a fresh `PLAYBACK_FIXTURE` login generated immediately before each run).
It uses real room creation and correlated **presentation-only** upload-status
fixtures; fake file IDs are never selected or discarded on the server. Both
Chrome 158 and Firefox 160 passed idle/transfer/error/validating/ready/confirmation
checks at 1440px and a long-filename check at 480px, with 22.1px text line-height,
24px introduction spacing and no horizontal dialog overflow. Optional
`UPLOAD_DIALOG_SCREENSHOTS=/tmp/upload-dialog` writes cropped state images;
`UPLOAD_DIALOG_BASELINE=/tmp/upload-dialog-original` recreates the old markup for
visual diagnosis only.

The actual chooser/raw-XHR/private-range/Keep/discard/replacement path also passed
a two-participant Chrome/Firefox run, recorded in `/tmp/upload-modal-report.json`.
Those devices-off results do not close the active-call release gates below.

### Mixed-browser and active-call follow-up

The workspace entry-point regression was also checked on the running local app
at port 4000 in Chrome and Firefox: clicking **Upload video** opens the room
requirement, and **Create a room** opens the existing creation dialog. The reusable
harness now checks this before login, after login, and on the Firefox workspace
before guest admission. Its follow-up joined-room upload/stream/discard/replacement
run passed; report: `/tmp/uploaded-video-entry-fix-report.json`.

The tightened harness subsequently exercised Chrome **158.0.8127.36** and Firefox
**160.0.1** on loopback. Mixed runs used one Chrome host and one Firefox guest;
the active-call run used five isolated Chrome identities. Each successful run
collected 30 rounds after readiness/playback, checked the new seek timeline, and
completed private 206 delivery, pause/discard/replacement. The current harness
also requires every player to remain ready and playing throughout sampling.

| Scenario | Samples | p95 absolute timeline error | Maximum spread | Native-seek recovery |
| --- | --- | --- | --- | --- |
| Chrome + Firefox, same H.264/AAC MP4, devices off | 60 | 0.153 s | 0.046 s | 1.085 s |
| Chrome + Firefox, same VP9/no-audio WebM, devices off | 60 | 0.055 s | 0.244 s | 0.771 s |
| Five Chrome participants, VP9/no-audio WebM, synthetic call active | 150 | 0.028 s | 0.0084 s | 0.792 s |

The mixed WebM run also closed and rejoined the follower's actual room socket:
transport/readiness/local-enable setup took **0.786 s**, followed by **0.774 s**
ready/enabled convergence. This is one bounded two-person reconnect scenario,
not late-join, tab-resume, or five-person recovery acceptance.

The active WebM call used oscillator microphones and animated 320×180 canvas
cameras through the actual device controls. During the uploaded playback sample
window, all five participants had live/enabled audio and video tracks; inbound
and outbound audio/video RTP byte counters advanced on all four peer connections
per participant (20 directed peer observations). One UI-sent chat message arrived
exactly once at each participant before playback sampling. This demonstrates
real local RTP transport alongside review-video decoding, **not audible speaker
output, sustained chat load, real-device/network interoperability, or deployment
capacity**. CPU, memory, disk throughput and bandwidth ceilings were not profiled.

Successful disposable JSON reports:

- `/tmp/uploaded-video-mixed-h264-aac-report.json`
- `/tmp/uploaded-video-mixed-webm-report.json`
- `/tmp/uploaded-video-five-active-webm-report.json`

**Failed H.264 active-call gates remain visible.** The five-Chrome 720p H.264/AAC
reconnect run observed **13.283 s** transport/readiness setup and **7.360 s**
ready/enabled convergence, exceeding the unchanged five-second target. A separate
active-call H.264 run encountered a buffering follower during the requested
settled sample window, so it produced no accepted settled metrics. Both had
advancing audio/video RTP and chat delivered to five participants. Reports are
`/tmp/uploaded-video-five-conference-h264-aac-report.json` (reconnect failure) and
`/tmp/uploaded-video-five-active-h264-aac-report.json` (sample-window failure).
These are local harness observations; browser scheduling, decoding load and
protocol-observation overhead have not been isolated from application behavior.
Do not relabel these runs as passes or extrapolate the small WebM success to them.

Edge and Safari were unavailable on this Linux host. Four-browser acceptance,
H.264 five-person active-call stability/recovery, late-join/tab-resume timing,
audible output, the remaining profile/audio combinations, and deployed capacity
remain open. These measurements remain follow-up work under the owner's rollout
decision above; synthetic/unit evidence does not establish their completion.

### Re-running the room harness

Use the existing Nix environment, an isolated development database, and an existing
local Chrome debugging listener as described in the README. Start the app with
`mix holo` (or explicitly set `HOLOGRAM_START=1` when using `mix run`); plain
`mix run` without that flag does not enable Hologram routes. Do not reuse a
production database. From the project directory, with the app and database ready:

```sh
PGDATABASE=review_uploaded_local_verify \
  PLAYBACK_FIXTURE=/tmp/review-uploaded-local-fixture.json \
  mix run --no-start scripts/playback_fixture.exs
APP_URL=http://localhost:4000 \
  PLAYBACK_FIXTURE=/tmp/review-uploaded-local-fixture.json \
  MEDIA_FILE=/home/dillon/review_project/sample-30s-720p.mp4 \
  PARTICIPANTS=5 REPORT=/tmp/uploaded-video-room-report.json \
  node scripts/uploaded_video_browser_test.mjs
node --test scripts/uploaded_video_browser.test.mjs
```

The app must use that same `PGDATABASE`; the fixture only creates a synthetic
local login and sends no email. Generate a fresh login token before each run.
`APP_URL` is restricted to loopback. The harness creates and closes only its own
browser contexts, and does not stop the existing browser/app.

Optional modes (prefix the harness command with these environment variables):

| Mode | Configuration | Evidence |
| --- | --- | --- |
| One Firefox guest | `MIXED_FIREFOX=1 FIREFOX_DEBUG_URL=ws://127.0.0.1:9237/session` | Chrome host, exactly one Firefox guest, remaining isolated Chrome guests; existing BiDi listener required |
| Active synthetic call | `ACTIVE_CONFERENCE=1` | Oscillator microphone/canvas camera via real controls; advancing RTP before and during playback, chat delivery; no real-device or audible-output claim |
| Follower reconnect | `RECOVERY_CHECKS=1` | Actual room-socket close/rejoin; setup duration separate from ready/enabled convergence; five-second threshold unchanged |

`CHROME_DEBUG_URL` selects an existing isolated Chrome listener (the active-call
run used port 9238). Do not modify or terminate a browser/app you did not start.
Failure reports retain browser errors and page diagnostics; a failed timing or
sample-readiness assertion is not an acceptance pass. The native-seek check focuses
the controller's video and changes its native `currentTime`; it verifies inference
and convergence, not a physical mouse drag on the native scrubber. For a small
WebM fixture with the already available FFmpeg:

```sh
ffmpeg -hide_banner -loglevel error -f lavfi \
  -i testsrc2=size=160x90:rate=15 -t 20 -c:v libvpx-vp9 -an \
  /tmp/uploaded-video-room.webm
```

Four-browser coverage, further five-person active-conference verification and
deployment-capacity measurements remain follow-up work. The owner has approved
rollout with these gaps; staging enables uploads on its next deployment.
