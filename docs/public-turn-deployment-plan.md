# Public STUN/TURN deployment plan

Date: 2026-11-19. Status: proposed first public deployment; nothing deployed by
this plan. The [first release contract](release-contract-v1.md) remains the
product scope. Runtime ICE configuration and recovery are already implemented;
see [conference networking](conference-networking.md).

## Confirmed inputs and proposed topology

The owner has an always-on NixOS server at home, a public IPv4 address, and an
unused TCP port 443. These are suitable inputs for a first home-hosted relay.
Upload capacity, whether the public address is static, the DNS provider, and
router forwarding behavior still need checking.

Propose one coturn service on that server and a dedicated hostname such as
turn.example.com under a domain the owner already controls. There is no need to
purchase a separate domain. Creating this subdomain leaves the existing website
and mail records in place. The app and relay hostnames can be different; the
app's runtime configuration selects the relay independently of its own origin.

This deployment serves STUN and relays conference microphone/camera traffic.
YouTube review footage continues to load from YouTube in each browser. It does
not add a media server, recording, or application session-duration limits.

## 1. Confirm reachability and capacity

- Reserve a stable LAN address for the server and confirm router administration
  access. With a public IPv4, ordinary inbound forwarding is viable if the ISP
  allows the selected ports. Check for any additional router/NAT layer.
- Determine whether the WAN address changes. If dynamic, arrange both DNS updates
  and updates to coturn's advertised public address; updating DNS alone does not
  repair existing relay allocations after an address change.
- Measure sustained upstream capacity and latency under load. Record ISP upload
  limits/data allowances and other household traffic before choosing concurrency.
- Budget for the mesh rather than a single camera feed. Five participants can
  send 5 x 4 = 20 directed copies. As a planning example, if every direction uses
  0.5 Mbps and all copies traverse this relay, remote deliveries require roughly
  10 Mbps of relay upload and similar incoming traffic, before overhead. This is
  an illustrative estimate, not a measured bitrate or a capacity promise. Measure
  real traffic and leave headroom. Only the paths selecting TURN incur relay use.

Exit: a selected server LAN address, reachable WAN address, forwarding access,
and an initial bandwidth/concurrency budget.

## 2. Create DNS and obtain a certificate

- Create an A record for turn.example.com pointing to the public IPv4. Publish
  an AAAA record only after IPv6 listeners, routing, and firewall rules work.
- If DNS is managed by Cloudflare, use DNS-only for this record. Its standard
  HTTP proxy is not the TURN transport. See [Cloudflare proxy status](https://developers.cloudflare.com/dns/proxy-status/).
- Use NixOS ACME to obtain and renew a publicly trusted certificate for the exact
  relay hostname. Prefer DNS-01 if the provider has an automation API: it avoids
  opening port 80 and does not compete with coturn on 443. Store a narrowly scoped
  DNS API credential outside Git and the Nix store. HTTP-01 on port 80 is an
  alternative if DNS automation is unavailable.
- Give coturn access to the certificate/key and configure the appropriate
  reload/restart after renewal. Verify the live listener serves the renewed
  chain; issuance alone is not the check. Consult [NixOS ACME](https://wiki.nixos.org/wiki/ACME)
  and [Let's Encrypt challenge types](https://letsencrypt.org/docs/challenge-types/).

The temporary hostname can remain in use or later be replaced by a product
hostname. A move requires the new DNS record, matching certificate, and updated
app ICE configuration followed by an app restart; it is not merely a website
redirect. Plan the transition so existing calls are not interrupted unexpectedly.

Exit: DNS resolves from outside the home and the certificate chain is trusted
without installing a test CA or bypassing verification.

## 3. Prepare the NixOS coturn service and router rules

Prepare a reusable NixOS module for the server's actual Nixpkgs version. Use the
normal coturn service or a VM with a properly routed/bridged network interface.
The existing QEMU user-networked research VM is not the public deployment recipe.

Proposed public ports:

| Traffic | Public port | Forward to / allow on server |
| --- | --- | --- |
| STUN and TURN over UDP | 3478 UDP | 3478 UDP |
| TURN over TCP | 3478 TCP | 3478 TCP |
| TURN over TLS | 443 TCP | coturn TLS listener, proposed 443 TCP |
| Peer-facing relayed media | 49152-49407 UDP, initial proposed range | Same UDP ports |

The relay range is an operational setting, not a room-participant limit. Start
with 256 ports for the trial and observe usage. Twenty peer connections can
probe three TURN transport URLs, and renewal can overlap old/new allocations;
20 x 3 x 2 = 120 is an initial budgeting scenario, not an exact allocation count.
Increase the range if observed allocations, port reservations, or concurrency
need it, updating router and server rules together.

Both firewall layers must agree. Forward relay ports without changing their
numbers, and configure coturn's external-ip mapping from public IPv4 to server
LAN IPv4. Test household clients too: router hairpin/NAT-reflection behavior can
affect paths to the home's own public relay address. Coturn documents the mapping
and port preservation in its [configuration reference](https://github.com/coturn/coturn/blob/master/examples/etc/turnserver.conf).

The UDP relay range is still needed when the browser connects using TCP or TLS:
those names describe the browser-to-relay connection. Peer-facing WebRTC relay
traffic remains UDP in this deployment. TCP 443 improves compatibility with
restricted networks but cannot guarantee passage through every HTTP-only proxy.
See the [TURN deployment guidance](https://nextcloud-talk.readthedocs.io/en/latest/TURN/).

Reserve TCP 443 for TURN in this initial topology. If the Phoenix app will later
share this same public IP and also needs HTTPS on 443, explicitly plan a separate
public IP, a TCP/TLS routing arrangement, or a separate relay host. An ordinary
HTTP reverse proxy or website redirect does not forward TURN packets.

Exit: the coturn configuration, router mappings, firewall rules, public/private
address mapping, and port-443 ownership are all explicit and reviewable.

## 4. Configure authorization and service operation

- Use coturn REST shared-secret authentication to match Rooms.ICE. Generate a
  separate deployment secret, load it through a restricted runtime file, and
  provision the same value to coturn and Phoenix. Keep secret contents out of
  Nix expressions/derivations, source control, browser code, and command arguments.
- Require authentication for TURN allocations. Public STUN binding requests can
  remain unauthenticated. Disable unused administration listeners and local-test
  loopback exemptions. Block relaying to loopback, link-local, private,
  and other non-public destinations so the service cannot reach household LAN
  services on behalf of remote clients; preserve legitimate public relay paths.
- Choose allocation and bandwidth limits from the measured workload, including
  candidate gathering and renewal overlap. These are resource limits, not room
  duration limits. Keep clocks synchronized for credential expiry checks.
- Configure service restart behavior and monitor certificate expiry, allocation
  counts, traffic, authentication failures, and saturation. Keep ordinary logs
  concise; avoid verbose SDP/ICE/credential logging. Document secret replacement,
  certificate renewal, address changes, upgrades, and rollback.

The [coturn server reference](https://github.com/coturn/coturn/blob/master/README.turnserver)
describes authentication, quotas, peer restrictions, and runtime options.

Exit: authenticated operation survives a service/host restart and certificate
renewal, with observable usage and a rollback procedure.

## 5. Connect the existing app

Provision a server-side JSON configuration, using the selected hostname:

    {
      "stun_urls": ["stun:turn.example.com:3478"],
      "turn_urls": [
        "turn:turn.example.com:3478?transport=udp",
        "turn:turn.example.com:3478?transport=tcp",
        "turns:turn.example.com:443?transport=tcp"
      ],
      "secret_file": "/run/secrets/conference-turn",
      "ttl_seconds": 3600
    }

Start/restart Phoenix with CONFERENCE_ICE_CONFIG pointing to that file. The
already implemented membership checks, credential issuance/renewal, and bounded
recovery remain in use. Normal joining retains automatic direct/STUN/TURN
selection; relay-only behavior stays in test tooling.

This does not publish the Phoenix app. For tests with people outside the house,
all participants also need access to the same app over browser-trusted HTTPS,
using public hosting or an appropriate private test access path. Decide that app access path
separately from the relay deployment, including the port-443 conflict above.

Exit: admitted members receive the public ICE configuration and temporary
credentials; receive-only room admission still works if relay issuance fails.

## 6. Verify from independent networks

Use actual room pages and inspect the selected candidate pair, traffic counters,
decoded/displayed video, and audible conversation. Ordinary successful calls may
use direct paths and therefore do not prove TURN works.

1. From a trusted operator environment, check STUN, UDP/TCP/TLS allocations,
   hostname/CA verification, allocation release, and rejection of anonymous,
   expired, and incorrect TURN credentials. Adapt the existing protocol harness
   to use system/public CA trust rather than its local test-CA fixture. Keep the
   deployment shared secret confined to trusted operator/app/relay environments.
2. Run the existing room suite with each forced relay mode, then automatic mode.
   The existing TLS metadata supports a configurable port, including 443. Test
   external participants on different networks, plus a client on the home LAN.
3. Block outbound UDP at a test client while leaving the relay's peer-facing UDP
   ports available. Demonstrate TCP/TLS fallback, including actual TLS on 443.
4. Exercise camera/microphone denial, receive-only entry, reconnect, device resume,
   replacement, leave, and five participants with real devices. Check current
   Chrome, Edge, Firefox, and Safari; Firefox background-tab work is closed after
   owner verification, and remains ordinary regression coverage.
5. Use short-lived credentials in an isolated validation configuration to cover
   multiple renewals, then run a multi-hour session with the intended deployment
   lifetime. Measure media interruptions, allocation cleanup, WAN usage, latency,
   and household uplink impact. Reboot/restart and certificate renewal are explicit
   operational checks, rather than inferred from a successful initial call.

Exit: retained results identify browser versions, physical devices, networks,
transport selected, duration, renewals, audio/video quality, and measured traffic.
Local-loopback results remain separate from this public evidence.

## Implementation order and remaining inputs

Next implementation deliverables are a parameterized NixOS coturn/ACME module,
an app ICE-config template, a router forwarding checklist for the selected router,
and the public-CA adjustments to the protocol/browser test instructions. Build
and review those before applying server or router changes.

Still needed: the chosen subdomain/DNS provider, the server's NixOS configuration
location/version and LAN address, whether public IPv4 is static, measured upload
capacity, and the app access path for outside testers. Home hosting is the
proposed first deployment.
