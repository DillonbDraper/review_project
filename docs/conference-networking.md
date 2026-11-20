# Conference networking and recovery

Room admission works without microphone, camera, or relay availability. With no
configuration, WebRTC tries direct connections. To provide STUN and authenticated
TURN, set `CONFERENCE_ICE_CONFIG` to the absolute path of a server-side JSON file:

```json
{
  "stun_urls": ["stun:relay.example.com:3478"],
  "turn_urls": [
    "turn:relay.example.com:3478?transport=udp",
    "turn:relay.example.com:3478?transport=tcp",
    "turns:relay.example.com:5349?transport=tcp"
  ],
  "secret_file": "/run/secrets/conference-turn",
  "ttl_seconds": 3600
}
```

Configure coturn's REST shared secret to match that file. It must contain at
least 32 bytes; restrict access to the application and relay processes. The
application reads it when issuing credentials and never returns it to clients.
The JSON is loaded at application startup; restart to change URLs or lifetime.
The secret file can be replaced without restarting the application.

`ReviewProject.Rooms.ICE` issues coturn REST credentials with an expiry-prefixed
username and Base64 HMAC-SHA1 password. The existing room channel validates live
membership, account session, epoch, and connection generation before issuance.
Credentials are renewed halfway through their lifetime (allowed range: 60–86400
seconds). The browser applies the new configuration and restarts ICE on each
pair. Temporary credentials live in scoped native handles, outside saved
Hologram state. Credential expiry does not end the room. Failed renewals retain
the working configuration, show a retry action, and retry after five seconds.
An initial credential failure permits direct connections while retries continue.

Each pair also creates an unused negotiated data channel, from Elixir, so an
all-inactive audio/video answer can still establish an ICE transport in Firefox.
It carries no application data and closes with the peer.

A disconnected peer gets three seconds to recover naturally. Failed paths (or
initial connections not established within fifteen seconds) get an ICE restart,
then a coordinated pair replacement after ten seconds if necessary. A replacement
gets fifteen seconds to connect; recovery then stops and offers **Retry call
connection**. Only the affected pair is replaced. The server advances a pair
version at both endpoints and rejects obsolete signals and duplicate resets.

Signaling loss immediately closes peers and releases devices. The same page
remembers which devices were enabled and reacquires them after admission is
restored. Pending permission requests are not remembered. Device errors remain
independent and retryable. Navigation, reload, explicit leave, seat replacement,
logout, and page removal clear these preferences. Peer replacement alone keeps
local capture, other peers, the review iframe, and chat intact.

## Local relay verification

An isolated coturn on loopback or the existing development coturn VM is enough
to exercise the protocol and browser paths. Public networking is a separate
deployment gate. Use an isolated secret, narrow relay range, trusted local TLS
certificate, and loopback-only listeners for a host-local relay. Coturn needs
`allow-loopback-peers` for that test topology; do not copy that option into a
public relay configuration.

The protocol test takes a separate endpoint metadata file:

```json
{
  "host": "127.0.0.1",
  "port": 34780,
  "tls_host": "localhost",
  "tls_port": 53490,
  "ca_file": "/tmp/conference-turn/cert.pem",
  "secret_file": "/tmp/conference-turn/secret",
  "min_port": 50400,
  "max_port": 50500
}
```

```sh
TURN_TEST_CONFIG=/tmp/conference-turn/test.json node scripts/conference_turn_protocol_test.mjs
```

This checks anonymous allocation refusal, authenticated UDP/TCP/TLS allocation
and release, certificate validation, and refusal of expired/incorrect credentials.

Start the app with its ICE configuration and an isolated Chrome debugging port
with fake capture devices. Keep normal autoplay restrictions enabled:

```sh
CONFERENCE_ICE_CONFIG=/tmp/conference-turn/app.json mix holo
APP_URL=http://localhost:4000 CHROME_DEBUG_URL=http://127.0.0.1:9234 \
  CONFERENCE_RELAY=udp node scripts/rooms_browser_test.mjs
```

`CONFERENCE_RELAY=udp|tcp|tls` forces relay selection in the test's constructor
and configuration wrapper; the product always uses the normal `all` policy.
With a 60-second local credential lifetime, this exercises five renewals across
more than two lifetimes with advancing RTP, displayed video, and a newly selected relay allocation after
each renewal. It also checks
failed pair replacement, same-page signaling recovery, and denied device resume.
`CONFERENCE_FOCUSED=1` skips the later five-person/chat/lifecycle regression flow
when repeating transport checks. TURN TLS requires the browser to trust the
relay certificate; an HTTPS page certificate bypass does not establish that
trust.

For a focused Firefox TLS workspace check, launch a separate Firefox profile
with fake capture devices, trust the local CA in that profile's NSS database,
and expose its BiDi debugging endpoint. A loopback relay additionally requires
`media.peerconnection.ice.loopback=true` in that isolated test profile because
[Firefox blocks loopback STUN/TURN by default](https://bugzilla.mozilla.org/show_bug.cgi?id=1973521).
This preference is only for a local test relay, not an application requirement.

```sh
APP_URL=http://localhost:4000 FIREFOX_DEBUG_URL=ws://127.0.0.1:9235/session \
  CONFERENCE_RELAY=tls node scripts/conference_firefox_browser_test.mjs
```

For an isolated `/tmp` relay secret, setting `TURN_FAILURE_TEST=1` and
`TURN_TEST_CONFIG` on the Chrome suite temporarily makes the secret unavailable,
checks that established media/room membership survive the credential error, and
restores the secret before verifying retry. Do not use this fault injection
against a shared or public relay.

Before release, validate public DNS/certificates, firewall/relay port reachability,
separate networks, blocked UDP, network changes, all supported desktop browsers,
real microphone/speaker quality with YouTube audio, and a multi-hour soak. Local
relay success does not establish those outcomes.

## Remaining Hologram interoperability work

Firefox calls in two visible windows establish receive-only connections and
exchange media. Negotiation stalled when the test put both participants in tabs
of one window and one tab became hidden. The current Hologram JS dispatch API
schedules each incoming action through a zero-delay timer; Firefox's background
throttling substantially delays that signaling/operation pipeline. Native peer
checks without Hologram did connect over the same local UDP relay.

Background-tab negotiation/recovery is therefore still a release blocker for
Firefox. Investigate a supported dispatch/scheduling path before changing this
boundary; no monkey patch of Hologram's scheduler or private boxing APIs was
added. Conference policy and native API sequencing remain in Elixir; this
framework scheduling boundary is the fragile part to revisit. Verify background
behavior in the other supported browsers as part of the browser matrix too.


## Local evidence (2026-10-30)

- `mix precommit`: 314 ExUnit tests passed; native bridge: 9 Node tests passed.
- Chrome 155: full real-workspace flow over forced UDP relay, including five
  participants, optional/denied devices, peer replacement, bounded exhaustion and
  retry, signaling loss/resume, credential-service failure, chat, navigation,
  seat replacement, leave, and logout.
- Chrome UDP and TCP: five credential renewals over more than two 60-second
  credential lifetimes, each selecting a replacement relay allocation while RTP
  and the product's video elements continue advancing.
- Firefox in visible windows: receive-only TLS admission, audio/video frame
  progress, and five TLS renewals with replacement allocations. Frame callbacks
  supplement its quality counter, which returned zero in this headless setup.
- Coturn protocol checks: authenticated UDP/TCP/TLS allocation/release,
  certificate validation, and rejection of anonymous, expired, or invalid auth.

This evidence uses isolated loopback relays and fake media. It does not cover
public NAT/firewall behavior, subjective audio quality, Edge/Safari, background
Firefox recovery, or the multi-hour soak.
