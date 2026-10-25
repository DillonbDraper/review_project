# 0001. Proposed Recording Export Composition Strategy

Date: 2026-06-26
Status: Proposed

## Context

The watch-party platform requires server-side MP4 exports that bake in the watched/source video, playback state, participant media, and drawing overlays. A participants-only recording is not acceptable, and browser screen capture must not become the final source of truth.

The Phase 0 Membrane recording-branch spike produced evidence under:

- `priv/media_spikes/recording_branch/SUMMARY.md`
- `priv/media_spikes/recording_branch/outputs/watch_party_recompose_spike.mp4`
- `priv/media_spikes/recording_branch/outputs/membrane_remux_sample-30s-720p.mp4`
- `priv/media_spikes/recording_branch/outputs/membrane_remux_sample-10s-h265.mp4`

## Decision

Use post-session server-side recomposition as the default export architecture until a live recording branch is separately proven.

The recomposition inputs should be:

1. the pristine uploaded/source video,
2. an event-sourced playback timeline,
3. participant media recordings or track artifacts,
4. persisted drawing/overlay events rendered into a video overlay layer,
5. mixed participant/source audio.

The target output is a standard MP4 with one composited video track and one mixed audio track.

For Membrane integration, keep `Membrane.MP4.Demuxer.DemuxingSource`, `Membrane.MP4.Muxer.ISOM`, and `Membrane.File.Sink` as validated building blocks for MP4 remux/mux. A Membrane-native video compositor still needs to be selected; `membrane_smelter_plugin` remains the leading candidate to evaluate once dependency/version concerns are resolved.

## Consequences

Positive:

- Preserves the project constraint that final exports are recomposed from server-side source material and durable event logs.
- Avoids depending on browser screen capture quality or drift.
- Allows deterministic replay of playback pauses/seeks and drawing overlays.
- Keeps export correctness separate from live client rendering.

Negative / tradeoffs:

- Post-session exports may not be immediately available after a room ends.
- Requires durable participant media artifacts or track recording strategy.
- Requires a production compositor decision before Phase 3.
- A pure Membrane-native end-to-end composition path is not yet proven.

## Options Considered

### Post-session recomposition from source + event logs + participant recordings

Chosen as the proposed default. It best preserves replay determinism and final export quality.

### Live recording branch during the session

Still viable, especially for reducing post-session render time, but not yet proven. It may be harder to correct drift or recover from live pipeline failures.

### Browser/client screen capture

Rejected for final export. It violates the source-of-truth and quality constraints. It may be useful only as a debugging or user-local fallback, not as the product export source.

### FFmpeg-only compositor

Used in the spike as a deterministic oracle/fallback because the current project dependency set lacks a pinned Membrane-native compositor. Not selected as the final architecture, but useful as a reference implementation and validation tool.

### Membrane-native compositor, likely Smelter

Preferred long-term direction, but not accepted yet. `mix.exs` already notes dependency concerns around `membrane_smelter_plugin`; those must be resolved before adoption.

## Validation / Evidence

The spike validated:

- Membrane MP4 demux/remux for H.264/AAC source media.
- Membrane MP4 demux/remux for H.265/AAC source media.
- A deterministic final MP4 can include:
  - watched/source video,
  - playback pause/freeze/resume semantics,
  - participant picture-in-picture video,
  - drawing-like overlay during the paused interval,
  - one mixed AAC audio track.

The final probe for `watch_party_recompose_spike.mp4` showed:

- MP4 container,
- duration `10.000000s`,
- video: H.264 High, `1280x720`, `30fps`, `300` frames,
- audio: AAC LC, stereo, `44100Hz`, `10.000000s`.

## Risks

- Membrane-native video composition remains unresolved.
- Live WebRTC ingest into recording/export artifacts remains unresolved.
- Participant track timestamp normalization and drift handling remain unresolved.
- H.265 can be remuxed by the current Membrane MP4 path, but a Membrane-native H.265 decode/compose path was not proven.
- Export job duration and resource cost are still unknown for longer sessions and larger source videos.

## Follow-up

- Evaluate `membrane_smelter_plugin` or another Membrane-native compositor in a focused follow-up.
- Decide whether participant media should be stored as individually recorded tracks, live branch fragments, or another intermediate format.
- Include WebRTC track timestamp behavior in the RTC-layer decision spike.
- Define an event-log schema for playback and drawing events before building Phase 1/2 persistence.
- Revisit this ADR after the RTC-layer decision and compositor evaluation; mark accepted only when the production compositor path is validated.
