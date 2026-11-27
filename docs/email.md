# Production account email (Resend)

Production uses the native `Swoosh.Adapters.Resend` adapter and existing Req API
client; no additional Resend SDK is needed. Confirmation, magic-link login, and
email-change messages share the fixed application-config sender
`{"ReviewProject", "noreply@whatgrabsme.org"}` in `config/config.exs`.

## Required runtime variable

`RESEND_API_KEY` must be a nonblank Resend API key authorized to send from
`whatgrabsme.org`. It is required in every production release, including staging
and release migration commands. A missing or blank key stops boot with a
configuration error rather than silently using local mail storage. The sender is
application configuration, not an environment variable.

## Owner setup prerequisite

1. Add `whatgrabsme.org` in the Resend dashboard, publish the requested DNS
   records, and wait for verification before attempting real delivery. Domain
   verification is a prerequisite, not something established by this repository
   change or its tests.
2. Create a sending API key in Resend, preferably restricted to that domain. Keep
   the key out of Git, images, browser code, logs, and deployment documentation.
3. Supply `RESEND_API_KEY` through Fly's secrets mechanism for the intended app
   before the next release/release migration. Apply to staging and production
   separately. No credentials are included in this repo.
4. Deploy through the normal deployment process. Any real delivery verification
   must be owner-authorized and use a controlled recipient; automated tests do
   not contact Resend. Rotate the Fly secret when rotating the Resend key.

Development continues to use `Swoosh.Adapters.Local` and `/dev/mailbox`; tests use
`Swoosh.Adapters.Test` with the HTTP client disabled. Both use the same configured
sender without requiring the production API key. A verified domain does not
guarantee inbox placement; check Resend delivery logs and the domain's email
authentication configuration when investigating delivery failures.
