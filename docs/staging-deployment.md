# Fly staging release preparation

Fly remains configuration-only: no Fly resources, builds or deployments were run.
An explicitly authorized isolated Supabase database setup was attempted, but stopped
on insufficient privilege and rolled back (see execution record below). There is
**no live release/Fly compatibility claim**. Future cloud operations still require
separate approval; the database authorization is not deployment authorization.

## Approved envelope

- Fly personal organization (not a new shared/paid organization), `iad`.
- Supabase specifically **US East (N. Virginia), `us-east-1`**. Do not substitute a
  nearby region. Use the project's direct PostgreSQL IPv6 endpoint, not the
  transaction pooler and not the Data API.
- One always-on shared CPU, one vCPU, 1 GB Machine, no volumes, no second region.
  `min_machines_running` is a floor, not a replica cap. First deploy must use
  `--ha=false`; inspect Machine count after every deploy and scale to one if an
  existing app already has extra Machines.
- Total recurring budget **under $25/month**, including Fly, Supabase, email,
  TURN and egress. This is a ceiling, not a price quote or enforced spending cap.
  Verify current prices and free-plan limits first; paid Supabase, dedicated IPv4,
  managed databases, volumes, remote builders and extra replicas are not approved.
  Release/rolling replacement Machines can temporarily overlap; account for this.
  Set billing alerts and stop if the estimate exceeds the ceiling.

## Build review and remaining verification

`Dockerfile` uses Elixir 1.20 / OTP 28 (matching `.tool-versions`) on Debian
bookworm in both stages. Verify the pinned Hex image tag exists and record its
immutable digest before a real build; tag availability was not checked remotely.
The build needs network downloads (Hex, Git, npm, Phoenix asset binaries,
Bundlex precompiled libraries, apt); **do not run a build under the current
no-dependency-installation approval**. No builder was provisioned here.

The native toolchain covers argon2, Unifex/Bundlex and DTLS/OpenSSL; FFmpeg,
Opus and SRTP system libraries are included. FDK-AAC uses the dependency's
precompiled provider (not Debian main). The runtime copies the whole release,
including dependency `priv` libraries. Hologram is a project compiler and needs
Node/npm during compilation; `mix compile` precedes Phoenix minification/digest
and `mix release`. `vendor/uuid_compat` must be copied before dependency compile.
The allow-listed Docker context excludes local secrets, databases, captures,
spike configuration, dependencies and existing build artifacts.

Before deployment, build locally after approval, inspect every NIF and packaged
shared library with `ldd` for missing libraries, boot the release as its non-root
user, verify Hologram page bundles and digested CSS/JS, and exercise media code
paths. Image tag existence, native ABI compatibility and memory fit are unproven.
Do not use `fly deploy` as a build-validation shortcut.

## Approved local image smoke (2026-11-23)

Downloads/build dependencies were explicitly approved for this local validation;
this supersedes the earlier no-install restriction for the local build only.
No Fly commands, remote database connections or host configuration changes ran.

- The original Hex tag did not exist. `Dockerfile` now uses the published
  `1.20.5-erlang-28.3.3-debian-bookworm-20261104-slim` index pinned to
  `sha256:73b445e0957bb0719ac8e89aec76eb712750f0f369c6de50bc61f0129e59d2cb`.
- `sg docker -c 'docker build --progress=plain -t review-project:staging-smoke .'`
  succeeded. Retained image:
  `sha256:3cd87fb9629e3b463f666f66f13bc1fa2977ed265ee05cb11b34da59e36ac829`
  (2,308,545,822 bytes). Node and runtime Debian tags remain mutable.
- Smoke exposed Hologram's release environment detection returning `:dev` and
  disabling its router (home returned 404). The runtime image now explicitly sets
  `HOLOGRAM_ENV=prod`; RPC confirmed `{:prod, true}` and home returned 200.
- A disposable, unexposed PostgreSQL 17 container on a dedicated Docker network
  received all six migrations through `/app/bin/review_project eval
  'ReviewProject.Release.migrate()'`; repeat returned `Migrations already up`.
  SQL confirmed six versions. Local trust authentication was confined to this
  disposable network; remote TLS configuration was not changed or exercised.
- Release ran as UID/GID 65534, limited to one CPU/1 GiB, with HTTP bound only
  to `127.0.0.1:18080`. Requests supplied `X-Forwarded-Proto: https`.
  Health returned 200/15 bytes; home 200/25,791 bytes; digested CSS/JS and
  Hologram runtime/WatchPage bundles all returned 200 (121,833 / 153,094 /
  590,892 / 617,556 bytes respectively).
- Dashboard, mailbox and `/tidewave/mcp` returned 404. Existing echo spike
  returned 200 and remains a public-release risk. GET `/signaling` returned 404,
  which does **not** prove the unconditional signaling WebSocket is absent.
- Every packaged `*.so*` was checked with `ldd`, using each library's own directory
  as `LD_LIBRARY_PATH` for bundled sibling dependencies: zero missing libraries.
  Bare `ldd` on FFmpeg provider libraries reports sibling SONAMEs missing without
  that lookup context. RPC successfully loaded Argon2, DTLS, SRTP, Opus encoder/
  decoder, H264 FFmpeg encoder/decoder and FFmpeg resampler native modules.
  This is loading evidence, not end-to-end media/browser validation.
- Idle sample: 207.9 MiB/1 GiB, 0.07% CPU, 61 PIDs. This is not load/capacity proof.
- `nix develop --command mix precommit` exited 0: **401 passed** (seed 304323).
  Plain `mix precommit` initially failed because Mix was outside the host PATH.
- Both created containers (including anonymous volumes) and the dedicated network
  were removed. Built image retained. No global prune or remote data writes.

## Database/security checklist (not yet completed)

1. Create/choose the Supabase project in `us-east-1` only after approval; record
   project identity without committing credentials. Disable the **Data API** in
   project API settings. Verify its REST/GraphQL endpoints cannot read app data.
2. Inspect grants and default privileges on `public`, tables and sequences for
   `anon`, `authenticated`, `PUBLIC`, `service_role` and application roles.
   Remove unintended API-role access to app tables and future objects. Disabling
   the API is not a substitute for grant review; do not apply blanket revocations
   to Supabase-managed schemas without understanding their requirements.
3. Verify `citext` is installed and resolvable by migrations (`pg_extension`,
   `SHOW search_path`, and `SELECT 'A'::citext = 'a'::citext`). Existing migrations
   request `CREATE EXTENSION IF NOT EXISTS citext`; preinstall it using an admin
   if the migration role cannot create it. Confirm extension schema/search path.
4. Use a dedicated least-privilege app role, not `postgres` or `service_role`.
   Verify LOGIN, database CONNECT, schema USAGE, table CRUD and sequence privileges
   and future-object defaults. Verify migration ownership/DDL rights and Ecto's
   migration advisory locking. Set `DATABASE_URL` to the restricted runtime role
   and `MIGRATION_DATABASE_URL` to the migration role. Only `Release.migrate/0`
   selects the latter; it refuses an already-running Repo and restores application
   configuration after migration. Without the override it retains the legacy
   single-URL behavior. If both secrets are distributed to all Fly Machines, the
   runtime process still has access to the migration secret: separate secret
   delivery for a migration job is stronger isolation and remains operational work.
5. Store the direct `db.<project-ref>.supabase.co` connection URL with URL-encoded
   credentials as a Fly secret. Never commit it or use `sslmode` to weaken TLS.
   `DATABASE_SSL=true` configures peer and hostname verification, SNI and OS CA
   roots; `ECTO_IPV6=true` selects IPv6; staging pool size is three. Dev/test
   configuration is unchanged. `DATABASE_CA_CERT_FILE` optionally reads a PEM
   certificate bundle and **adds** it to system roots. Missing/unreadable or empty
   bundles fail closed when TLS is enabled. Both URLs use verified TLS; migration
   SNI/hostname verification uses the migration URL's hostname. Mount the reviewed
   dashboard CA at that path in the release environment; no mount is provisioned
   by this change. Never substitute `verify_none`.
6. Verify direct IPv6 connectivity from Fly, connection limits with the app plus
   the temporary migration Machine, backups/restore, migration rollback strategy
   and no application access to Supabase admin APIs.

## Isolated database execution record

The operator confirmed a dedicated empty Free `us-east-1` project and disabled
Data API. The setup used credentials parsed in memory (never sourced as shell),
the dashboard CA plus system roots, peer verification, SNI and HTTPS hostname
verification. The read-only audit reached PostgreSQL **17.12** over direct IPv6;
`public` contained **zero tables**. This is connectivity evidence from the local
host, not from Fly or a packaged release.

The audit found role-specific defaults: `supabase_admin` grants app-like objects
in `public` to API roles; `postgres` table defaults also grant some API privileges.
These defaults cannot be assumed safe for app tables. The intended ownership is
`review_migrator`, with its own global/schema defaults revoking API/PUBLIC access,
CRUD-only table and sequence-usage defaults for `review_runtime`, and no role
membership linking runtime to migrator. Supabase-managed defaults/schemas must
remain intact. Preinstall `citext` in `extensions` and give app roles USAGE with
`search_path = public, extensions` so the existing first migration resolves it.

The initial all-in-one attempt rolled back with SQLSTATE **42501**. A controlled
follow-up isolated the boundary: setup-admin `postgres` cannot alter another
role's defaults because its automatically created membership has `SET=false`.
No SET/admin membership escalation was granted. The successful staged procedure
committed restricted LOGIN roles, `citext` in `extensions`, schema USAGE for both
roles and public CREATE only for the migrator; it then authenticated directly
as `review_migrator` to configure its own defaults **before any app tables**.
Only that role's global/public table, sequence and function defaults were changed;
Supabase-managed defaults were left intact. Runtime receives table CRUD and
sequence USAGE only through migrator defaults.

All **six migrations completed** through `Release.migrate/0` using
`MIGRATION_DATABASE_URL`, with a stopped Repo and without starting the application
supervision tree. A second invocation succeeded with the same six migration
versions (no-op). Strict peer verification, the dashboard CA plus system roots,
SNI and hostname verification were used for every connection.

The restricted runtime authenticated independently: public-schema CREATE and
migrator membership both tested false; persistent CREATE TABLE failed with
**SQLSTATE 42501** inside a rolled-back transaction. Synthetic user INSERT,
SELECT, UPDATE and DELETE succeeded inside an explicitly rolled-back transaction;
users remained empty afterward. Sequence counters can advance despite rollback.
The ownership audit found all public tables owned by `review_migrator`; both
LOGIN roles have no superuser, database/role creation, replication or bypass-RLS
capabilities. Effective privilege checks found **zero** API-role privileges on
migrator-owned app tables/sequences/functions for `anon`, `authenticated` and
`service_role` (function checks are vacuous where no app functions exist).

`/home/dillon/supabase-staging.env` is now marked **ACTIVE** only after those
checks passed, with mode **0600**. Its original inactive contents are preserved
in an exclusively created external `.inactive-backup`, also mode **0600**.
Existing generated passwords were suitable and reused; no credentials or raw
connection URLs appear here. Active means verified local database credentials,
not a deployed application or permission to distribute migrator credentials.

Backup export and isolated restore **have not been executed**. A restore
exercise must use a disposable local database or separately approved isolated
target, never overwrite staging or Supabase internal schemas. Release packaging,
CA mounting, Fly IPv6, connection budgets and all deployment/cloud checks above
remain outstanding. No Fly provisioning, installation or deployment was done.

## Packaged release read-only Supabase check (2026-11-23)

The retained `review-project:staging-smoke` image, ID
`sha256:3cd87fb9629e3b463f666f66f13bc1fa2977ed265ee05cb11b34da59e36ac829`,
was tested with `/app/bin/review_project eval` against the active staging database.
This supersedes the outstanding local release/CA-connectivity check above only;
it is **not Fly networking or deployment evidence**.

- Docker ran through `sg docker`. Credentials were parsed programmatically from
  the existing mode-0600 file, never sourced or printed, and delivered using
  disposable mode-0600 env files. The runtime check received only the runtime URL;
  the separate migration-identity check additionally received the migration URL.
- Actual packaged production runtime configuration used `DATABASE_SSL=true`,
  `DATABASE_CA_CERT_FILE=/run/supabase-db-ca.crt` (the existing dashboard CA mounted
  read-only), `ECTO_IPV6=true`, `POOL_SIZE=3`, `PHX_HOST=localhost`, and an ephemeral
  `SECRET_KEY_BASE`. Assertions verified peer verification, the HTTPS hostname
  match function, IPv6 socket options, pool size, custom certificates added to
  system roots, and `/etc/ssl/certs/ca-certificates.crt` present inside the image.
- Default Docker bridge resolved one IPv6 address but TCP returned `enetunreach`
  (eval exit 2). With `--network host`, the same image/config reached the direct
  IPv6 endpoint. No Docker/host networking configuration was changed.
- Host-network runtime and migration-identity evals both exited **0**. They started
  only SSL/Ecto dependencies and Repo; application supervision was absent and no
  HTTP server was started or port published. `Release.migrate/0` was **not called**;
  the migration check used the packaged helper's `migration_options/2` only.
- Every database query ran inside an explicit transaction with `SET TRANSACTION
  READ ONLY`, confirmed by `SHOW transaction_read_only = on`. Both identities saw
  **six** schema migrations, resolved `'A'::citext = 'a'::citext` as true, and
  reported `pg_stat_ssl.ssl = true`, version **TLSv1.3**.
- Runtime was `review_runtime`: LOGIN true; superuser, CREATEDB, CREATEROLE,
  replication, BYPASSRLS, public-schema CREATE and migrator membership all false.
  Migration identity was `review_migrator`: LOGIN/public CREATE true; all five
  elevated role attributes false. No grants or DDL were attempted.
- Both identities successfully executed `SELECT * ... LIMIT 0` on every public
  table: `chat_room_messages`, `room_invitations`, `room_seats`, `rooms`,
  `schema_migrations`, `user_identities`, `users`, `users_tokens`. This verifies
  SELECT access without displaying application rows; it does not re-test writes.
- All disposable containers and protected env files were removed after each run;
  temporary local check scripts were removed. Existing image, credentials and CA
  were preserved. No migrations, application expiry jobs, remote data writes,
  Fly commands, provisioning, deployment or public listener were involved.

Fly CA delivery, direct IPv6 reachability from Fly, full application startup with
this database, remote connection budgets, backups/restore and browser/media
validation remain unverified. Host-network success is not default-bridge success.

## Future operational commands

Use Bash. The app name is supplied by the operator and is deliberately absent
from TOML; no invented hostname is shipped. Run only after remote operations are
approved and existing Fly login and a reviewed local image build are available:

```bash
read -r -p 'Existing approved staging Fly app name: ' FLY_APP
: "${FLY_APP:?app name required}"
export FLY_APP
export PHX_HOST="${FLY_APP}.fly.dev"
fly secrets set --app "$FLY_APP" PHX_HOST="$PHX_HOST"
# Import DATABASE_URL and SECRET_KEY_BASE from a secret manager through stdin:
# fly secrets import --app "$FLY_APP"
# Input format is KEY=value, never paste real secrets into documentation/history.
fly deploy --app "$FLY_APP" --config fly.staging.toml --ha=false --local-only
fly status --app "$FLY_APP"
fly machine list --app "$FLY_APP"
curl --fail --show-error "https://${PHX_HOST}/healthz"
```

App creation is intentionally not automated. Verify the existing app belongs to
the personal org and has only the approved resources before deployment. For a
custom domain, configure DNS/certificate first and explicitly replace `PHX_HOST`
with that verified domain. Production startup now fails if `PHX_HOST` is missing,
instead of silently generating `example.com` links. Configure the exact Google
OAuth callback `https://${PHX_HOST}/users/auth/google/callback` if Google is used.
`SECRET_KEY_BASE` must be independently generated and stored as a secret.

Fly executes `/app/bin/review_project eval 'ReviewProject.Release.migrate()'`
once per deployment before updating app Machines. The helper starts SSL and the
Repo via `Ecto.Migrator.with_repo`, not the web supervision tree, performs only
forward migrations, and propagates failures. It never creates/drops databases,
seeds data, or performs automatic rollback. Use backward-compatible migrations;
old Machines may remain serving while a migration runs. Snapshot/restore and a
manual rollback plan are prerequisites for destructive future changes.

## Health scope and production exposure audit

`GET /healthz` is in the public `scope "/", ReviewProjectWeb`, through the
existing `:api` pipeline (JSON accepts only), outside all `live_session`s. It
intentionally does not fetch a browser session/current_scope or require login,
because Fly probes have no user identity. It returns only `{"status":"ok"}`,
no-store, with no explicit DB query or sensitive diagnostics. The endpoint's
shared plugs still apply; this is liveness, **not database readiness**, mail,
WebRTC, YouTube or capacity validation. Fly terminates public HTTPS; the internal
HTTP probe supplies `X-Forwarded-Proto: https` to avoid the production SSL redirect.
Never expose the Machine's internal HTTP port directly to the public internet.

Compile-time development flags (`dev_routes`, `hologram_spikes`,
`youtube_sync_spike`) are not enabled by prod config. Dashboard/mailbox and gated
Hologram/YouTube spike routes are consequently excluded; Tidewave and reloaders
are development-only. **Unresolved release risk:** `/spikes/webrtc-echo` and
`/signaling` remain unconditionally exposed in production, and the echo LiveView
uses the public current-user session rather than authenticated access. Native
media dependencies remain in the production release. This preparation does not
silently refactor or remove those contracts; gate/remove or explicitly accept
and resource-limit this surface before making staging publicly available.

Email provider/sender/domain remains undecided: the configured Local mailer with
local storage disabled is not production email delivery. Do not claim signup,
confirmation or password recovery works. TURN provider, credentials rotation,
transport support, usage caps and cost remain undecided. `CONFERENCE_ICE_CONFIG`
expects a server-side file; no TURN secrets are baked into the image and no file
mount is provisioned. Do not claim cross-network mesh reliability without these
choices and browser testing. No credentials are included in this change.
