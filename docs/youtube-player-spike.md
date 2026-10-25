# YouTube player integration spike

Date: 2026-10-18. Scope: spike 1 from the first-release viability research.

This experiment validates a single official embedded player through Hologram.
It does not implement rooms, host/guest authorization, synchronized playback,
conferencing, or chat. The [release contract](release-contract-v1.md) remains the
product scope.

## Run locally

The development-only page is `/dev/spikes/youtube`. Like the existing Hologram
probes, it is enabled by `:hologram_spikes` in development and served by
`Hologram.Router`, before the Phoenix router. It adds no Phoenix browser pipeline,
authentication scope, or LiveView session. It is not a production guest-access
implementation. Production and test configurations do not compile the page.

Start PostgreSQL if needed, then generate a temporary localhost certificate:

```sh
direnv exec . dbstart
mkdir -p /tmp/review-youtube-spike
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout /tmp/review-youtube-spike/key.pem \
  -out /tmp/review-youtube-spike/cert.pem -days 2 \
  -subj '/CN=localhost' \
  -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1'
direnv exec . env \
  DEV_HTTPS_CERT=/tmp/review-youtube-spike/cert.pem \
  DEV_HTTPS_KEY=/tmp/review-youtube-spike/key.pem mix holo
```

Open `https://localhost:4001/dev/spikes/youtube`. The certificate is self-signed;
trust it locally or use the automated harness's certificate override. HTTP on
port 4000 remains available. Restart `mix holo` after changing spike modules to
ensure the running server and Hologram bundles use the same code.

The page initially loads no YouTube SDK or iframe. Create the player, then click
Enable playback or the embedded player's Play button. Changing a video cues it;
it does not automatically start it. Play is disabled until the replacement video
is cued, avoiding a playback request being lost during preparation. Controls
remain outside the embedded player.

## Browser harness

Requires Node.js 24 and running browsers with isolated temporary profiles. No npm
packages are needed. Do not use the relaxed autoplay flags from the older media
echo smoke test: normal autoplay behavior is part of this experiment.

```sh
google-chrome --headless=new \
  --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222 \
  --user-data-dir=/tmp/review-youtube-spike/chrome-profile \
  --no-first-run --no-default-browser-check about:blank
```

In a separate terminal:

```sh
REPORT_PATH=/tmp/review-youtube-spike/chrome-report.json \
  node scripts/youtube_browser_test.mjs
```

For Firefox:

```sh
mkdir -p /tmp/review-youtube-spike/firefox-profile
firefox --headless --no-remote \
  --profile /tmp/review-youtube-spike/firefox-profile \
  --remote-debugging-port 9223 about:blank
```

In another terminal:

```sh
BROWSER=firefox REPORT_PATH=/tmp/review-youtube-spike/firefox-report.json \
  node scripts/youtube_browser_test.mjs
```

Chrome uses CDP; Firefox uses WebDriver BiDi. The harness allows the temporary TLS
certificate but does not change autoplay policy. It creates and closes its own
test tab, uses real pointer actions for user-initiated playback, and first tries
playback without any user activation. Reports include browser versions,
check-by-check player telemetry, and console/network diagnostics.

Overrides: `APP_URL`, `CHROME_DEBUG_URL`, `FIREFOX_DEBUG_URL`, `YOUTUBE_VIDEO`,
and `YOUTUBE_ALTERNATE`. Set `SCREENSHOT_PATH` to save a final page screenshot.
Default real video IDs are `M7lc1UVf-VE` and
`aqz-KE-bpKQ`. Video availability can change independently of the application.
Use fresh profiles when checking first-visit autoplay behavior.

Run deterministic facade tests separately:

```sh
node --test --test-isolation=none scripts/youtube_probe.test.mjs
direnv exec . mix precommit
```

Those tests use a fake SDK to exercise URL validation, error explanations,
blocked-playback recovery, stale callbacks, resource cleanup, cancellation while
loading, and SDK-load failure/retry. They are not evidence of real YouTube media
playback. Browser tests use the real SDK and media without interception or mocks.

## Implementation boundary

- Hologram holds the resource ID, form inputs, and serializable status telemetry.
- The bundled JS facade owns `YT.Player`, timers, DOM observation, and disposal.
- The official SDK is loaded on demand from YouTube by the facade so the
  experiment exercises the supported provider interface. No external SDK script
  or inline custom script is added to an application layout.
- An iframe is created inside a stable, empty Hologram-owned host. The player
  persists across telemetry renders. Native resources are released on explicit
  removal, replacement, host DOM removal, and `pagehide`.
- API loading and player readiness have timeouts and retry instructions. A late
  SDK response cannot recreate a disposed player. A bfcache restoration asks the
  participant to recreate the player rather than reusing released resources.
- The iframe identifies the application with `origin` and preserves an HTTP
  referrer through `strict-origin-when-cross-origin`.
- No API key, scraping, downloads, media capture, recording, or overlays are used.

## Evidence and remaining limits

**Result: the single-player integration is viable in the tested Chrome and
Firefox environments.** Both completed all 13 harness checks using the real SDK
and media over localhost HTTPS, with normal autoplay policy. These results do
not establish multi-user synchronization viability.

| Browser | Version | Result |
| --- | --- | --- |
| Chrome | 155.0.8059.79, headless Linux | 13 checks passed |
| Firefox | 158.0, headless Linux | 13 checks passed |
| Edge | Not installed | Deferred |
| Safari | Not available on this Linux host | Deferred |

| Scenario | Chrome | Firefox |
| --- | --- | --- |
| Official player ready over HTTPS without user activation | Pass | Pass |
| Local click recovers from blocked first-visit playback; media time advances | Pass | Pass |
| Pause holds position | Pass | Pass |
| Seek changes actual player position | Pass | Pass |
| Second video cues and plays | Pass | Pass |
| Invalid source is explained without replacing the current video | Pass | Pass |
| Explicit removal releases the iframe | Pass | Pass |
| Recreate after disposal | Pass | Pass |
| Host DOM removal triggers resource disposal | Pass | Pass |
| Navigation releases the old player and allows recreation | Pass | Pass |
| Reload starts with fresh native resources | Pass | Pass |
| Real provider rejection of an invalid video is explained | Pass | Pass |
| A valid video plays after the provider error | Pass | Pass |

Observed playback samples in both browsers: initial state `unstarted`, position
0, with the local-click prompt; after the click, `playing` at 2 seconds; after
seeking, `paused` at 15 seconds. The second real video also advanced during
playback. The invalid ID `00000000000` produced YouTube's embedding-disallowed
explanation in both runs; this is evidence of real error propagation, not a
stable fixture for distinguishing every provider error code. Deterministic tests
separately cover unavailable/private and embedding-disabled explanations.

No uncaught application exceptions or failing application assertions occurred in
the successful runs. Diagnostics were not completely silent: Chrome reported
canceled navigation requests, development live-reload sockets closing during
navigation, and an iframe permissions warning; Firefox reported YouTube
cross-site cookie rejections and canceled requests during teardown. These did
not prevent playback or the tested recovery paths. The harness retains these
diagnostics in its optional JSON report rather than claiming an error-free
third-party console.

Additional validation passed:

- Three deterministic Node test groups, including resource ownership and failure
  recovery assertions.
- `direnv exec . mix precommit`: 113 tests passed, compilation with warnings as
  errors, formatting, and dependency checks.
- Production compilation with warnings as errors; the spike page's BEAM module
  is absent from the production build.
- JavaScript syntax and `git diff --check`.

The tests exposed and corrected controlled-input resets during telemetry
renders, input event payload handling, and playback requests racing video
preparation. The harness waits for Hologram's mounted-page signal and uses
settled scroll positions with pointer hit checks before clicking.

The complete player experience still needs observation with physical audio
output and on other networks. Further provider error variants need stable real
examples; their explanations are covered deterministically. Ads, regional or
age restrictions, login/consent states, browser extensions, and differing guest
buffering remain important inputs to the subsequent synchronization spike.

## Primary references

- [YouTube IFrame Player API](https://developers.google.com/youtube/iframe_api_reference):
  readiness/state/error events, playback controls, `onAutoplayBlocked`, and player
  destruction.
- [YouTube player parameters](https://developers.google.com/youtube/player_parameters):
  JavaScript API enablement and application origin.
- [YouTube embedded-player requirements](https://developers.google.com/youtube/terms/required-minimum-functionality):
  client identity/referrer requirements and unobscured player presentation.
- [Firefox Remote Agent](https://firefox-source-docs.mozilla.org/remote/):
  WebDriver BiDi browser automation.

These sources describe supported interfaces and integration requirements; a
working local spike does not guarantee that every YouTube video is embeddable.
