# Manual five-device mesh test (3B)

Status: **spike 3B accepted as successful by the project owner, 2026-10-24**,
following manual testing on the home network. Use the
[release contract](release-contract-v1.md) as scope.
The [3A results](local-mesh-spike.md) used synthetic capture and muted playback;
3B adds an explicit audible mode and human observations.

The owner confirmed that the guest camera worked on retry and that the test
worked successfully after the capture/startup fixes. This records the owner's
acceptance of the viability spike. Exact physical-device count, full browser
matrix, session duration and exported manual measurements were not supplied in
the conversation, so this note does not assert those coverage details. Network
relay setup and local mode checks were subsequently accepted; see the
[TURN report](turn-spike.md). Public-network/cost testing from spike 4,
and the combined multi-hour soak (spike 6) remain outstanding.
Ownership/handoff is now implemented in the separate
[spike-5 harness](ownership-spike.md).

## Start on the test host

From the project root with Node.js 24, OpenSSL, iproute2 and direnv available:

```sh
node scripts/start_mesh_lan.mjs
```

The launcher discovers the private IPv4 LAN address from the default route,
starts the existing PostgreSQL environment if necessary, and runs `mix holo` in
development. It binds HTTPS **only to that LAN address on port 4001**. The normal
HTTP development listener stays on loopback. A small setup server on port 4002
serves the public CA certificate, setup instructions and this document; it does
not serve project files, private keys or the app over HTTP. Use `--ip 192.168.1.58`
to override detection, or `--setup-only` to generate certificates without servers.

The printed URLs on the current host are:

- Setup: `http://192.168.1.58:4002/`
- Test: `https://192.168.1.58:4001/dev/spikes/youtube-mesh-manual`

The address can change with DHCP. Use the URLs printed by the launcher, and
restart it if the host's LAN address changes. The host should use the same LAN
URL as its guests so invitations contain the correct address.

Private keys, certificates and server logs live in ignored `.spike-lan/` with
restricted permissions. The CA lasts 30 days; the server certificate lasts seven
days and is renewed on launcher startup. The CA is reused, so normal restarts do
not require guests to import a different CA. If it expires, stop the launcher,
move the old `.spike-lan` directory aside, restart, and trust the new CA on each
computer. Compare the new fingerprint. Logs are in `.spike-lan/server.log`.

Ctrl+C in the launcher terminal stops Phoenix and the setup server. It leaves
PostgreSQL running. Restart after code or configuration changes; finish formatting
and build checks before a manual measurement session to avoid live reload.
If the agent started it or you are in another terminal, stop it with
`node scripts/start_mesh_lan.mjs --stop`, then run the start command again.
The helper verifies the saved process belongs to this launcher before signaling it.

## Temporary host firewall rules

This host uses the NixOS `nixos-fw` iptables chain. In a separate terminal run:

```sh
sudo bash scripts/mesh_lan_firewall.sh open enp7s0 192.168.1.0/24
```

The helper permits only this interface and home subnet: TCP 4001/4002 for the app
and setup page, plus UDP 32768–65535 for browser media sockets when this host is
also a participant. It does not alter router forwarding or NixOS configuration.
It is idempotent and tags its own rules. Use the interface/subnet printed by the
launcher if your network differs. Other test computers must also allow their
browser's local-network media traffic.

After the test:

```sh
sudo bash scripts/mesh_lan_firewall.sh close enp7s0 192.168.1.0/24
```

A firewall reload or reboot also removes these temporary rules. This helper
requires your local administrator password; the application launcher does not
request or store it. There is no need to open a router port to the internet.

## Trust HTTPS on each test computer

1. Open the setup URL from that computer on the same home network. Download
   `review-project-3b-ca.crt`.
2. Compare the CA's SHA-256 fingerprint to the value printed on the host. This
   is the public certificate; private `.key` files stay on the host.
3. Import it as a trusted certificate authority for websites:
   - Windows Chrome/Edge: import into the current user's **Trusted Root
     Certification Authorities** store (Certificate Import Wizard / certmgr.msc).
   - macOS Safari/Chrome: import using Keychain Access, open the certificate's
     Trust settings and trust it for SSL. The OS may ask for authentication.
   - Firefox, including Linux: Settings → Privacy & Security → Certificates →
     View Certificates → Authorities → Import. Allow the CA to identify websites.
     Firefox may already use a trusted OS root, depending on the platform/config.
4. Restart the browser and open the HTTPS test URL. It must load without a
   certificate warning. Use normal permission prompts and autoplay policy.
5. After testing, remove **Review Project 3B LAN Test CA** from the stores where
   you imported it.

Importing a CA is an explicit trust change on each computer. The setup page does
not install it automatically. Bypassing a certificate warning or marking an HTTP
origin as secure is not the intended test configuration.

References: [Microsoft certificate stores](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/trusted-root-certification-authorities-certificate-store),
[Apple certificate trust](https://support.apple.com/guide/keychain-access/change-the-trust-settings-of-a-certificate-kyca11871/mac),
[Firefox private CAs](https://support.mozilla.org/en-US/kb/setting-certificate-authorities-firefox).

## Participants and session procedure

Use five physical desktop/laptop computers, one browser participant each, including
an older/weaker laptop. Include Chrome, Firefox, Edge and Safari where available.
Use real people, cameras and microphones. Begin with headphones in separate rooms
so direct speech cannot disguise a broken media path. Use one LAN without guest
Wi-Fi/client isolation. Wi-Fi is useful for realistic observation; note it in the
report along with any wired devices.

On every device, fill in the participant label, hardware/OS/power and audio/network
fields. These labels are local report metadata, not production guest identities.
The host creates a research room and shares the **guest link shown on the page**.
Guests click Join room. Each participant enables YouTube playback, starts their
camera/microphone, then clicks Enable room audio. Their own preview stays muted.

YouTube startup has two distinct controls shown together: **1. Enable playback
on this device**, then the host's **2. Play for everyone**. Enabling a device
alone keeps a paused room paused. The player status explicitly identifies that
state rather than claiming playback is already following the timeline. A paused
initial video is cued so the embedded player can display its preview/controls.

Camera and microphone acquisition are independent. If the camera cannot open,
a working microphone stays usable and the page identifies the camera failure.
You can also choose **Start microphone only** to avoid requesting the camera at
all. Stop media before changing modes. Microphone-only participants can receive
other people's camera video; they simply send no camera track of their own.

Room audio has a local volume slider and a separate Mute room audio button.
Neither button mutes the microphone or changes other participants. Microphone and
camera stream toggles keep capture open; Stop media releases both devices. The
YouTube player has its own volume. If audible playback is blocked, the page asks
for another click on Enable room audio; do that once peers are connected.

Follow the page's 45–60 minute checklist:

1. Verify two-way media with two people, then add three. Each person should
   positively identify all four others' voices and moving video.
2. Watch YouTube and talk naturally for about 30 minutes with all cameras on.
   Move on camera, interrupt one another, use chat and judge volume balance.
3. Host pauses, seeks and resumes; participants background/restore tabs.
4. One guest stops/restarts media, disconnects/reconnects, and leaves/rejoins.
   Try denied camera/microphone permission and headset removal/reconnection.
5. Try speakers one person at a time, then additional people. Listen for echo,
   clipped syllables and delayed conversation. Note CPU, memory, fan/thermal
   behavior and whether quality declines on a warm or battery-powered laptop.
6. Everyone presses Leave and checks hardware indicators. Finish observations
   and download a report from **every** computer before closing/reloading tabs.

The sampler starts when a room is created/joined. Mark this moment attaches a
UTC event marker and up to 500 characters of current notes. Leave stops sampling
and releases media; the report remains downloadable on that page. Starting a new
room or reloading replaces the in-memory test, so export first. This is a proposed
research procedure, not an application session-duration limit or release SLA.

## Reports and evaluation

Each JSON report contains browser version/user agent, participant-entered metadata,
manual pass/fail/untested observations, timestamps, visibility, playback drift,
peer/track/audio playback state, actual capture dimensions and available WebRTC
statistics. It includes codec, frame/packet/byte counters, jitter, RTT, encoder
limitations and supported audio concealment counters. Missing browser fields are
not replaced by invented measurements. OS CPU, memory, thermal load and perceived
audio quality require manual notes; the browser harness does not infer them.

Samples are collected every five seconds, retaining at most 720 (the latest hour)
and 200 event markers. This bounds diagnostic memory; it never ends the session.
Timers can be throttled in background tabs, so use actual timestamps for analysis.
No camera/microphone recordings, YouTube downloads or chat message bodies are
included. Local device IDs/group IDs are removed from exported settings. Typed
metadata/notes remain in the report. Preserve the five files together with a
session identifier in the notes and record which browsers/devices were absent.

Do not turn a connected peer status or nonzero audio counter into a human-audio
pass. The checklist deliberately defaults to Untested. Suggested acceptance:
everyone can converse over YouTube, videos remain useful, playback/reconnects
recover, weaker machines remain responsive, and leaving releases capture. Quality
and synchronization thresholds remain research decisions under the release
contract. This harness uses the 3A 320 × 180 / 15 fps profile; it has no quality
profile selector and does not establish that this resolution is acceptable for
release.

## Troubleshooting and remaining coverage

- Setup URL times out: confirm the launcher is running, firewall command was
  applied, both devices use the home LAN, and guest/client isolation is disabled.
  The launcher READY check runs on the host; it cannot prove another computer
  passes the firewall. Check from a second device before scheduling everyone.
- HTTPS certificate warning: verify import into the right browser/OS store,
  fingerprint, system time and exact printed IP. Trusting the leaf certificate
  temporarily is not a substitute for importing the CA.
- API unavailable: verify trusted HTTPS and normal browser camera/mic permission.
  No virtual capture or insecure-origin flags are needed for manual testing.
- Media connected but silent: enable room audio, check its volume and the OS
  output device, then confirm the speaker's microphone stream is enabled.
- Camera not found: use Start microphone only, or use the regular media start
  and let it retain a working microphone. Errors now name the affected device
  and include the browser error type. A microphone failure is reported separately.
- YouTube stays paused after Enable: the host must press Play for everyone.
  Enabling room audio affects remote voices only; it does not start YouTube or
  open a microphone. Check the status/error immediately above the video.
- Web page works but peers do not connect: check local firewalls, Wi-Fi isolation
  and selected ICE candidates. The default Direct mode uses no STUN/TURN. For
  the optional automatic or forced relay modes, follow the
  [coturn configuration and firewall guide](turn-spike.md).
- Transport disconnect intentionally keeps local capture active for reconnect;
  use Stop media or Leave to release it. After permission/device failure use
  Stop media then Start camera and microphone to reacquire capture.
- These original research rooms retain their token-host behavior. Use the
  [spike-5 harness](ownership-spike.md) for real account ownership, invitation
  admission and automatic host-absence handoff.

The owner has accepted this manual viability spike. Full release coverage still
needs documented device/browser coverage, sustained performance and the combined
soak; Edge/Safari coverage and thermal/battery measurements are not established
by the recorded evidence. Separate-home NAT/TURN testing is spike 4; a multi-hour
combined soak is spike 6. Browser automation with fake capture validates the
harness's controls, exports and cleanup; human observations remain separate.

## Apparatus verification (2026-10-18)

- `mix precommit`: 123 Elixir tests passed.
- Nine JavaScript test groups passed, including report identifier redaction,
  bounded diagnostics retained after Leave, and real OpenSSL LAN certificate
  generation/validation with restricted private-key permissions.
- Four Chrome participants and one Firefox participant passed seven manual-mode
  browser checks: mode-preserving invitations/full mesh, remote playback versus
  silent self-preview, local volume/mute, injected autoplay-refusal feedback and
  retry, report content/redaction, metadata surviving Hologram updates, and native
  media cleanup with downloadable reports after Leave. Actual JSON files were
  downloaded by both browsers. Human checklist outcomes remained Untested.
- The existing 3A ten-scenario browser matrix passed after these additions.
- Production compilation with warnings as errors passed; the manual page,
  invitation page and manual panel are absent from the production BEAM output.
- HTTPS returned 200 when verified against the generated CA at the LAN IP;
  setup and public-certificate URLs returned 200; a private-key path returned
  404. Host listener inspection confirmed LAN-only 4001/4002 and loopback HTTP
  4000. This host-side check does not establish remote firewall reachability.

Automation used Chrome 155.0.8059.79 and Firefox 158.0, synthetic capture and
browser certificate overrides. It validates controls and report delivery, not
the actual certificate-import workflow on other computers or physical audio.
TLS verification above used the CA normally, without disabling certificate
validation. Raw browser reports/downloads are under `/tmp/review-mesh-spike/`.

The host firewall was not changed by the agent: local `sudo` authentication
requires the owner's password. Apply the temporary helper above before attempting
access from another computer, then check the setup URL there. This limitation is
an operating-system authentication requirement, not a completed network test.

## Device/startup fixes verified (2026-10-24)

A user testing Zen on NixOS reported a camera/microphone error and a blank
YouTube player after enabling local playback. The combined device request
required both devices; an unavailable camera could reject the working microphone
as well. Capture is now requested separately, preserves any working device, and
offers an explicit microphone-only button. Warnings identify the failed device
and browser error type. Audio-only offerers include a receive-video section, so
they can still receive a video-capable participant's camera.

The reported YouTube sequence was reproduced in an isolated Zen 1.24t profile:
Enable left the room paused, while the old UI incorrectly said it was following
the timeline. Pressing the host's Play command played real YouTube media.
Playback status now states that the room is paused, and numbered Enable/Play
controls appear together. Initial paused videos are explicitly cued, and the
coordinator avoids unnecessary Pause calls on an unstarted/cued player.

Validation: 14 Node test groups, 123 Elixir tests through `mix precommit`, and
real-browser tests using Chrome 155.0.8059.84 and isolated Zen 1.24t. The new
`scripts/mesh_device_recovery_browser_test.mjs` checks real YouTube startup,
simulated missing-camera fallback, microphone-only offerer and answerer media
delivery, and native capture/connection cleanup. The existing five-participant
manual-mode browser matrix also passes with Zen as the Firefox-family browser.
Neither run reports uncaught application errors. These tests use synthetic
capture; they do not establish whether the user's physical camera is functional
or replace the listening/device-quality session.

For the targeted regression, with the existing isolated browser launch setup:

```sh
APP_URL=https://192.168.1.58:4001 \
  REPORT_PATH=/tmp/mesh-device-recovery.json \
  node scripts/mesh_device_recovery_browser_test.mjs
```

The Firefox-family driver defaults to port 9223; use `FIREFOX_DEBUG_URL` for
another isolated Firefox/Zen BiDi endpoint. Zen was tested on port 9224.
