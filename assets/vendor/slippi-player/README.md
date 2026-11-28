# Locally bundled SlippiLab adapter

Derived from https://github.com/frankborden/slippilab at
ba4e09172344d1e7957de2d8a6eebab31632d92f, MIT; retain LICENSE. Runtime dependency
licenses are in licenses/. See docs/slippi-integration-spike.md at the repository
root for modifications, scope and limitations.

Rebuild: `npm ci --ignore-scripts --cache /tmp/slippi-npm-cache && npm run build`.
Commit runtime.mjs, worker.mjs, sources and package-lock.json together. The normal
Phoenix asset build imports runtime.mjs and copies worker.mjs plus zips/*.zip.
There are no runtime CDN dependencies. Keep all game/renderer buffers native;
only primitive metadata and lifecycle events should cross the Hologram bridge.

## Provenance and packaging

Pinned source: https://github.com/frankborden/slippilab/tree/ba4e09172344d1e7957de2d8a6eebab31632d92f
The parser, stage/character mappings and SVG animation archives are retained from
that source snapshot; `zips/*.zip` are the upstream game-derived character
animation data, not recordings supplied by users. Approximate rendering does not
include original models or game audio. MIT attribution is retained in LICENSE;
notices for bundled Solid and fflate dependencies are in licenses/. The inherited
UBJSON dependency notice is also retained, although arbitrary metadata decoding
has been removed from the worker. An upstream code license does not independently
establish rights to every game-derived asset; provenance is recorded here without
claiming an additional asset license.

Local changes include instance-scoped Solid stores, cancellable per-instance
animation caches, positional markers for absent optional animation fields,
bounded raw-element parsing, rollback truncation, and required-player validation.
`manifest.json` records SHA-256-derived worker/archive filenames. Build with
`npm run build`; verify committed bundles against pinned sources and lockfile with
`node build.mjs --check`. Phoenix copies manifest-named files to same-origin
static storage. No runtime CDN is involved; nested node_modules are excluded from
Docker. See docs/slippi-replays.md for release gating and actual validation.

`provenance.json` records the exact upstream path and Git blob identity for each
of the 26 character archives, verified against the pinned GitHub tree, plus full
SHA-256 checksums. Builds refuse archives that differ from these checksums.
`NOTICES.txt` combines upstream and dependency attribution for release packaging;
the asset build publishes both it and the provenance record beside the manifest.
