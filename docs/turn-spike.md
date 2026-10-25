# Spike 4: local coturn VM

This is the local infrastructure stage of spike 4, using the
[first release contract](release-contract-v1.md). It does not close the public
network/cost spike. The mesh remains limited to five participants including the
host, with no recording and no application session time limit.

Status: **local manual connectivity checks accepted as successful by the project
owner, 2026-10-24**. After reporting success with automatic STUN/TURN and being
given the forced UDP/TCP/TLS test sequence, the owner confirmed that everything
was tested and working. Physical-device count, browser matrix, duration and
exported reports were not supplied, so this acceptance does not establish those
details or close the public-network/cost stage. Spike 5 (access, ownership and
host-absence playback control) was subsequently completed and accepted; see the
[ownership/handoff report](ownership-spike.md). The public-network/cost stage
remains open.

## What is installed and configured

`infra/turn-vm/default.nix` builds a headless NixOS VM using the exact Nixpkgs
revision in the project's existing `flake.lock`. It uses 2 vCPUs, 2 GiB RAM and
a 12 GiB sparse disk. Coturn 4.9.0 supplies STUN and authenticated TURN.

KVM works on this host. QEMU and libvirt tools are installed, but the host's
libvirt daemons are not enabled and the current login is not in `libvirtd`.
This setup launches QEMU directly as the current user; it does not require
libvirt, root, a host bridge, router port forwarding, or a host NixOS rebuild.
It uses QEMU's user networking with explicit, port-preserving forwards. The
VM's address is `10.0.2.15`; coturn advertises the detected host LAN address
(`192.168.1.58` at setup) for relay candidates.

| Purpose | Host binding | Guest port |
| --- | --- | --- |
| STUN / TURN over UDP | LAN IPv4:3478 UDP | 3478 |
| TURN over TCP | LAN IPv4:3478 TCP | 3478 |
| TURN over TLS | LAN IPv4:5349 TCP | 5349 |
| Relayed media | LAN IPv4:49160–49259 UDP | Same ports |
| VM administration | 127.0.0.1:2223 TCP | SSH 22 |

TCP/TLS here describe the browser-to-TURN connection. The relay's peer-facing
media sockets remain UDP. Coturn's `no-tcp-relay` disables RFC 6062 TCP relay
allocations; it does not disable TURN-over-TCP or TURN-over-TLS.

The relay range, allocation quotas (80 total / 16 per credential), one-hour
credential lifetime and renewal at half-life are **research settings**, not
accepted production limits. They do not impose a room duration cap.

## Start, inspect and stop

From the project directory, using the usual Nix/direnv environment:

```sh
node scripts/turn_vm.mjs build
node scripts/turn_vm.mjs start
node scripts/turn_vm.mjs status
node scripts/turn_vm.mjs logs
node scripts/turn_smoke_test.mjs
```

Build once, then reuse the build and disk on subsequent starts. Rebuild after
changing the VM configuration, lockfile or host LAN address. Only one instance
can use these ports. The VM stays running after the launcher exits.

To enable TURN in the existing LAN app, stop an existing app instance first:

```sh
node scripts/start_mesh_lan.mjs --stop
TURN_SPIKE_CONFIG="$PWD/.spike-turn/app.json" node scripts/start_mesh_lan.mjs
```

Open <https://192.168.1.58:4001/dev/spikes/youtube-mesh-manual>.
Choose the network research mode **before** creating a room. Share the generated
invitation, which carries the mode to guests. Available modes:

- **Direct**: previous 3B behavior, no ICE servers.
- **Automatic**: STUN plus all three TURN transports; direct paths may win.
- **STUN only**: binding discovery without TURN allocations.
- **Force TURN over UDP / TCP / TLS**: relay-only policy and one TURN URL,
  preventing a different transport from hiding failure.

You can also open the page with `?ice=relay-udp`, `?ice=relay-tcp`,
`?ice=relay-tls`, `?ice=auto` or `?ice=stun`. Hologram currently removes query
parameters during initialization; the native module reads the invitation mode
from the document's original Navigation Timing URL. The visible status and downloaded
report show the actual active mode and candidate statistics.

Start media, enable room audio, enable YouTube playback on each device, and
have the host press **Play for everyone**, as in the successful 3B test. For a
relay pass, every remote peer should be connected and show `relay`; observing
audible voices and usable video still requires people and real hardware.

Stop independently:

```sh
node scripts/start_mesh_lan.mjs --stop
node scripts/turn_vm.mjs stop
```

VM shutdown is graceful and the helper waits for it to finish. PostgreSQL is
left running. VM console, disk, build symlink, SSH key and reports live under
ignored `.spike-turn/`; do not commit or share that directory wholesale.

## Other computers on the home network

The existing HTTPS setup remains at <http://192.168.1.58:4002/>. Devices that
already trust the matching 3B test CA can reuse that trust. TURN-TLS uses a
certificate signed by the same CA; browser trust is required for it as well as
for HTTPS. Accepting a webpage certificate warning alone is not a dependable
way to establish TURN-TLS trust. The CA private key is never shared with the VM.
The leaf certificate lasts seven days; restarting the VM regenerates it.

TURN-TLS uses `192-168-1-58.sslip.io:5349` rather than a literal IP. This public
wildcard DNS service resolves the encoded name to `192.168.1.58`; traffic still
stays on the LAN. The name is included in the locally signed certificate and
is generated from the detected address at VM startup. This avoids the current
[Firefox TURN-TLS IP-address issue](https://bugzilla.mozilla.org/show_bug.cgi?id=2019255),
which also matters for Firefox-derived browsers such as Zen. UDP/TCP continue
to use the LAN IP directly. DNS resolution of that name was verified on this
host. A DNS rebinding filter or unavailable external DNS can block it on other
devices; use a local DNS record or a hostname under your own domain in that
case, with a matching certificate and `tls_host` in the app configuration.
Do not disable certificate verification to work around a hostname mismatch.

The host firewall may still block new TURN listener ports. Run in your own
terminal (requires your sudo password):

```sh
sudo bash scripts/turn_lan_firewall.sh open enp7s0 192.168.1.0/24
```

The helper adds only tagged IPv4 rules for the stated interface and private
subnet: TCP 3478/5349, UDP 3478 and 49160–49259. Existing HTTPS 4001/4002 rules
are handled by `scripts/mesh_lan_firewall.sh`. Undo the TURN rules with:

```sh
sudo bash scripts/turn_lan_firewall.sh close enp7s0 192.168.1.0/24
```

Rules are temporary and disappear after firewall reload/reboot. No router
changes are needed. Same-host automation alone does not establish access from
another physical computer; the owner's subsequent local manual acceptance is
recorded separately above.

## Credentials and diagnostics

The launcher generates a random shared secret in `.spike-turn/runtime/secret`.
Only the VM's small runtime directory is shared, read-only. Systemd loads the
secret/certificate/key into coturn's credentials directory; secret contents are
not included in Nix expressions or derivations. SSH accepts the generated key
and no password, through a localhost-only host forward.

Phoenix reads `.spike-turn/app.json` only when explicitly enabled with
`TURN_SPIKE_CONFIG` in **development**. Joined channel members receive an
expiry-and-member username and Base64 HMAC-SHA1 password, following coturn's
REST credential scheme. The shared secret stays server-side. This is the
existing development-only signaling/membership apparatus, not production room
authorization, rate limiting or an abuse policy.

Clients request fresh credentials halfway through their lifetime, apply the
new configuration, and let the deterministic offerer restart ICE to establish
allocations with renewed credentials. A configuration update alone would not
renew authentication on an existing allocation. Room identity, chat and the
YouTube timeline remain in place during this operation. Retry does not end the
room. Background throttling, sleep/wake and extended outages still require a
longer soak and recovery testing.

Reports include candidate types, relay protocol when the browser exposes it,
selected-pair byte counters, RTP counters and renewal count. They exclude
TURN usernames/passwords, the shared secret and media recordings. Candidate
byte counters help compare paths; they are not a cloud provider billing meter.

## Validation and remaining work

The protocol smoke test checks STUN bindings, rejects anonymous allocations,
creates authenticated UDP/TCP/TLS allocations, verifies the advertised relay
IP and port range, releases allocations, verifies TLS against the local CA,
and rejects expired/incorrect credentials. It never prints credentials or
places them in process arguments.

`scripts/turn_mesh_browser_test.mjs` uses the existing CDP/BiDi browser adapter,
isolated Chrome/Firefox profiles and synthetic camera/microphone capture.
The renewal scenario requires a separate app config with `ttl_seconds: 60`;
normal `.spike-turn/app.json` retains 3600 seconds. Firefox's isolated profile
must trust the test CA for TURN-TLS. Browser debug ports default to Chrome
9222 and Firefox 9223. The script writes `.spike-turn/browser-report.json`.

The automated TLS phase uses two Firefox tabs with explicit CA trust; Chrome's
CDP webpage certificate bypass does not establish TURN-TLS trust. Import the CA
into the isolated Firefox profile before launching it, using NSS `certutil`:

```sh
# Obtain certutil from the same pinned Nixpkgs revision, if needed.
turn_nss_tools=$(nix build github:NixOS/nixpkgs/567a49d1913ce81ac6e9582e3553dd90a955875f#nss.tools --no-link --print-out-paths)
mkdir -p .spike-turn/firefox-profile
"$turn_nss_tools/bin/certutil" -N --empty-password -d sql:.spike-turn/firefox-profile
"$turn_nss_tools/bin/certutil" -A -n review-turn-local-ca -t 'C,,' \
  -i .spike-lan/root-ca.crt -d sql:.spike-turn/firefox-profile
```

Initialize the NSS database once; do not overwrite a profile in use. Firefox
synthetic capture uses `media.navigator.streams.fake=true` and
`media.navigator.permission.disabled=true` in that profile's `user.js`, as in
the existing browser harness. Use isolated profiles, not a personal browser.
Chrome uses `--use-fake-device-for-media-stream --use-fake-ui-for-media-stream`.
Neither browser needs an autoplay-bypass flag. For subsequent focused tests,
`TURN_TEST_MODES=relay-tcp,relay-tls` restricts phases;
`TURN_TEST_RENEWAL=0` skips the expiry scenario when using the normal TTL.

Results from 2026-10-24:

| Check | Result |
| --- | --- |
| VM boot, stop/restart, KVM acceleration, coturn service | Pass; coturn 4.9.0, KVM enabled |
| STUN bindings and signed UDP/TCP/TLS allocation/release | Pass |
| Anonymous, incorrect-secret and expired allocation credentials | Rejected as expected |
| TLS certificate verification against local CA and hostname | Pass |
| Five-person UDP mesh, four Chrome tabs + one Firefox tab | Pass; all 20 directed paths relay/relay, audio received and video decoded |
| Two-person TCP mesh, Chrome + Firefox | Pass |
| Two-person TLS mesh, Firefox + Firefox, hostname URL | Pass |
| Short TTL renewal past original expiry | Five-person UDP recovered with growing video counters and four renewals per member in the retained accelerated run |
| Application console errors in final relay run | None |
| Existing five-person YouTube/manual harness regression | All seven checks passed: playback, voice/video, controls, reports, state persistence and resource cleanup; no application errors |
| `mix precommit` | 128 tests passed |
| Browser helper unit tests | 14 passed |

Browsers: Chrome 155.0.8059.84 and Firefox 158.0. Final transport results are in
`.spike-turn/browser-report.json` and `browser-final-test.log`; the accelerated
renewal evidence is retained in `browser-udp-tcp-report.json`.

The accelerated renewal run exposed transient failed peer states before
recovery on a repeated test. Growing counters and eventual reconnection do
**not** establish interruption-free renewal. Measure interruptions, allocation
cleanup and recovery during the multi-hour soak before treating renewal as
release-ready. Chrome TURN-TLS remains unverified with proper CA trust;
the successful automated TLS check used Firefox. Edge/Safari were not tested.

Still needed to close spike 4:

- Public coturn VM with a real hostname, publicly trusted TLS certificate,
  correct public/private address mapping and matching relay firewall range.
- Real browsers across independent networks, including restrictive networks;
  demonstrate UDP failure and working TCP/TLS fallback. TLS on 5349 does not
  establish reachability on networks that permit only 443.
- Multiple-hour renewal/recovery and five-device mixed-browser validation,
  including supported Edge/Safari where available.
- Measured relay usage and a cost estimate using the selected provider's actual
  bandwidth pricing, plus production authorization and abuse controls.

QEMU SLIRP forwards proxy inbound packets; the VM can see virtual gateway
addresses rather than the original client addresses. Local STUN binding
success therefore does not verify Internet-facing NAT discovery or the
behavior of a public STUN server. This VM is useful for relay plumbing and
credentials; it is not a representative public network/performance benchmark.

Sources: [coturn configuration reference](https://github.com/coturn/coturn/blob/master/examples/etc/turnserver.conf),
[QEMU networking](https://www.qemu.org/docs/master/system/devices/net.html), and the
coturn/QEMU NixOS modules from the project's pinned Nixpkgs revision.
