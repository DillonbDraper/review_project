# Fly staging release preparation

## GitHub Actions review draft (not enabled or executed)

`.github/workflows/staging.yml` is a **draft for a public repository**. Creating
this file locally does not authorize pushing it, configuring GitHub/Fly, or
running a deployment. There is currently no Git remote. Actual deployment remains
**not started**; no working-deploy claim is made.

### Manually approved first setup

Before publishing/enabling Actions, an operator must approve and perform these
steps separately:

1. Audit the public Git history and tracked build context for secrets and private
   data. Do not publish local backup/env files (including `supabase_info.yml~`),
   recordings or unreviewed untracked work. Never blanket-add the working tree.
2. Review and replace mutable action references (Docker actions
   and especially `superfly/flyctl-actions/setup-flyctl@master`) with independently
   verified full commit SHAs and pin the reviewed flyctl version. Checkout is
   pinned to its known v4.2.2 SHA; no unknown hashes were invented. These mutable
   references are an explicit supply-chain review blocker, not final hardening.
3. Create/protect the `staging` branch. Require checks and review for workflow,
   Dockerfile, scripts and configuration changes. Configure the GitHub **staging**
   environment to permit only the `staging` branch (not tags or arbitrary branches).
   Initially require an approving reviewer; after a separately approved first
   deployment, remove approval only if fully automatic deployments are desired.
   Pushes/merges to `staging` deploy automatically after checks; manual dispatch
   also requires `refs/heads/staging` and the same checks/environment controls.
4. After approval, select/create the app in the **personal organization**, `iad`,
   and verify the under-$25 total recurring estimate, billing alerts and one-Machine
   envelope above. Set environment variable **FLY_APP** to that exact app name.
   Empty/invalid values fail before tooling/credential use. Set environment secret
   **FLY_API_TOKEN** to an expiring **app-scoped deploy token**, never an organization
   or personal all-app token. The draft does not create apps or provision resources.
5. Supply production runtime secrets directly through reviewed Fly operations,
   **not GitHub test/build secrets**: `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`
   and any approved OAuth/mail/ICE configuration. The approved public database CA
   is bundled in the image for both app and release Machines (see CA delivery below).
   Use ordinary app-wide Fly secrets for `DATABASE_URL` and
   `MIGRATION_DATABASE_URL`, as approved for staging. This exposes the migration
   credential to web Machines as well as release commands; see the accepted
   staging credential trade-off below. No CA mount is needed.
6. Pin/review remaining mutable base images, review available runner disk/time and
   remote-builder costs, then authorize a first real checks run and deployment separately.
   Inspect Machine count/region, IPv6 TLS, health, assets, migrations, memory and
   budget afterward. `--ha=false` prevents default HA creation, not existing replicas.

### Checks, image custody and public-repository risks

PRs use `pull_request`, never `pull_request_target`, with `contents: read`, no
persisted checkout credentials and no Fly/environment secrets. The disposable
PostgreSQL service uses only public CI credentials; tests never receive Supabase
URLs. The runner builds the Dockerfile build stage, runs the full Mix test suite
(and warnings/format checks), then loads the production image built on that runner.
The build stage contains production dependencies; the temporary test container
fetches test dependencies and mounts only checked-out tests and formatter config.
No host env file is sourced and checks do not use a Fly remote builder.

`scripts/staging_smoke.sh` uses a separate internal Docker network and disposable
PostgreSQL database, runs release migrations twice, checks the packaged signaling
socket registry, starts the non-root production image at one CPU/1 GiB, checks
health/home and referenced CSS/Hologram JavaScript, and requires development paths
and the echo spike to return 404. It deliberately fails if production echo remains
exposed; this draft does not change echo. The current source has a dev-only echo
route gate; older retained images may still expose it. Smoke is not browser/media,
load, remote TLS or Fly networking proof. Containers, volumes and network are
removed on exit.

Only successful staging push/manual runs reach the protected deploy job, which
checks out the same revision and runs
`flyctl deploy --remote-only --app "$FLY_APP" --config fly.staging.toml --ha=false`.
Fly rebuilds remotely: **the deployed image is not the same smoke-tested artifact**.
Dependency downloads, mutable base images and builder differences can change the
result. This trades exact-artifact custody for simpler deployment; runner smoke
is a source/build regression gate, not proof of the remote image. There is no
cross-job image artifact transfer or runner registry authentication/push step.
The app-scoped token is exposed only to the deploy step, not setup or checks.
Deploy jobs share non-cancelling concurrency so release migrations cannot overlap;
GitHub concurrency may replace pending jobs (it is not a FIFO deployment queue).
Do not start out-of-band deploys concurrently. Migrations still need backup/rollback
review and Fly's release command uses runtime secrets as described above.

BuildKit GHA caches contain public build inputs only and use GitHub's branch/ref
cache isolation: PR cache writes cannot update the base branch's cache. Treat all
caches/artifacts/logs in a public repository as public; never pass secrets as build
args, copy credentials into layers, or add privileged `workflow_run` consumers of
PR artifacts. Public PR code can execute arbitrary commands on disposable runners,
so restrict Actions permissions/fork approvals and protect deployment-trusted code.
`contents: read` is sufficient; no package write, OIDC or repository write permission
is requested. Actionlint/full workflow execution and actual cloud validation remain
separate from offline syntax/unit checks.

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
  managed databases, volumes and extra replicas are not approved. Fly remote builds
  are selected for this draft only; verify builder pricing/lifecycle within the
  same ceiling before authorizing any actual remote build.
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
  which did **not** prove the then-unconditional signaling WebSocket was absent.
  Source now registers `/signaling` only at compile time in `Mix.env() == :dev`;
  production/staging (`MIX_ENV=prod`) and test builds exclude it. The retained
  smoke image predates this gate and is outdated: rebuild and verify the packaged
  endpoint socket registry before deployment. `/room-socket` remains the real
  conference transport and is unchanged; the echo spike risk remains outstanding.
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

## Current-source local rebuild and smoke (2026-11-23, 15:22–15:32 UTC)

This is additional evidence, not a replacement for the historical smoke above.
The explicitly authorized local rebuild used the existing dirty working tree;
no unrelated edits or the deleted echo test were restored, and no commit was made.

- Inspected `Dockerfile` and `scripts/staging_smoke.sh` before execution.
  `sg docker -c 'docker build --progress=plain -f /home/dillon/review_project/Dockerfile -t review-project:staging-current /home/dillon/review_project'`
  exited 0. Retained image `review-project:staging-current` has image ID and
  repository digest `sha256:6f95957a1b783eff81fcff8cff67f44711ff186605bd9be93b136ce2f1730875`,
  size **2,308,587,393 bytes**, created `2026-11-23T15:23:22.031210361Z`,
  configured user `nobody`. The build used cached layers where applicable.
- The initial smoke exited 1 after all six migrations, repeat migration and
  packaged signaling-registry check succeeded: Docker 29.9.3 did not publish
  `8080/tcp` on an internal bridge. A separate disposable reproduction confirmed
  null published ports despite the requested host binding. The script now uses
  the container's internal bridge IP directly from the Linux Docker host, with
  **no published port** and no external-egress network attached. This requires a
  local Linux Docker daemon/host bridge, not Docker Desktop or a remote daemon.
- The next attempt reached health/home but exited 127 because `node` was absent
  from the inherited host PATH. Using the existing development environment fixed
  this without installing host tools:
  `sg docker -c 'nix develop /home/dillon/review_project --command bash /home/dillon/review_project/scripts/staging_smoke.sh review-project:staging-current'`
  **exited 0**. Initial connection-refused messages were readiness retries before
  successful startup, not final health failures.
- The successful smoke used disposable `postgres:17-bookworm`, dummy
  `RESEND_API_KEY`, disposable database/secret values, and an internal-only Docker
  network. All six release migrations succeeded; repeat reported `Migrations
  already up`. The compiled endpoint socket registry excluded `/signaling`.
  The non-root release ran with one CPU/1 GiB; health, home and every local asset
  extracted by `staging_assets.mjs` fetched successfully with forwarded HTTPS.
  `/dev/dashboard`, `/dev/mailbox`, `/tidewave/mcp` and `/spikes/webrtc-echo` each
  returned 404. Thus the current image resolves the historical echo/signaling
  exposure checks; the older retained image evidence remains historical.
- Added `scripts/staging_smoke.test.mjs` to guard the internal-bridge/no-publication
  contract. `nix develop /home/dillon/review_project --command node --test /home/dillon/review_project/scripts/staging_assets.test.mjs /home/dillon/review_project/scripts/staging_smoke.test.mjs`
  exited 0: **4 tests passed, 0 failed**. `bash -n /home/dillon/review_project/scripts/staging_smoke.sh`
  and `git -C /home/dillon/review_project diff --check` exited 0.
  Python workflow checks could not run: neither `python` nor `python3` was available
  in the host or existing development environment; no Python changes were retained.
  Application code was unchanged, so full application precommit was not rerun.
- All created smoke/reproduction containers, anonymous database volumes and
  networks were removed. Post-run Docker listings contained no `staging-smoke`
  containers/networks. One unrelated dangling volume dated 13:49 UTC (before this
  run) was preserved; no global prune ran. The current image remains retained.
- Build dependency resolution reported security advisories for the existing locked
  dependencies (including Bandit 1.13.1 HIGH advisories); successful smoke is **not**
  a security clearance. Dependency upgrades are outside this packaging/smoke task.
  No Fly/cloud operations, remote builds, Supabase connections, real credentials
  or live email delivery were used. This run does not prove browser/media behavior,
  native-library coverage, load/capacity, remote TLS or live-network compatibility.

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
   runtime process still has access to the migration secret. This is the accepted
   staging trade-off below, not migration credential isolation.
5. Store the direct `db.<project-ref>.supabase.co` connection URL with URL-encoded
   credentials as a Fly secret. Never commit it or use `sslmode` to weaken TLS.
   `DATABASE_SSL=true` configures peer and hostname verification, SNI and OS CA
   roots; `ECTO_IPV6=true` selects IPv6; staging pool size is three. Dev/test
   configuration is unchanged. `DATABASE_CA_CERT_FILE` optionally reads a PEM
   certificate bundle and **adds** it to system roots. Missing/unreadable or empty
   bundles fail closed when TLS is enabled. Both URLs use verified TLS; migration
   SNI/hostname verification uses the migration URL's hostname. The approved public
   dashboard CA is bundled at the configured path in both app and release images;
   no mount or global trust-store installation is needed. Never substitute `verify_none`.
6. Verify direct IPv6 connectivity from Fly, connection limits with the app plus
   the temporary migration Machine, backups/restore, migration rollback strategy
   and no application access to Supabase admin APIs.

## CA delivery (resolved: approved public certificate in image)

`priv/certificates/supabase-root-ca.crt` is the reviewed public **Supabase Root
2021 CA**, not a credential. SHA-256:
`80:70:25:AD:50:D4:ED:21:9D:2C:9C:7D:29:9C:00:4F:82:4E:B0:0C:F7:F6:5A:FE:F6:07:D0:7B:72:E6:CA:FA`.
It expires **2031-04-26 10:56:53 UTC**. Source validation required exactly one
PEM certificate, no private key or extra payload, and the approved fingerprint
before copying. Focused runtime tests pin its identity and CA basic constraints.

Docker copies it root-owned, mode `0444`, to
`/app/certificates/supabase-root-ca.crt`; Docker and Fly staging set
`DATABASE_CA_CERT_FILE` to that stable path. App and release-command Machines
use the same image. This only augments **database connection** trust when
`DATABASE_SSL=true`; it does not enable TLS by itself, install the root into the
OS trust store, or change peer verification, hostname checking or SNI.

Before expiry or a provider CA rotation, obtain the replacement public CA through
an independently reviewed provider channel, verify its fingerprint and CA
constraints, reject keys/extra PEM entries, and update the certificate and pinned
test together. Rebuild the image, verify packaged permissions and database TLS
with the intended hostname, then seek deployment approval for both app and release
Machines. Replacing a host file alone cannot rotate an already-built image.
Do not work around rotation with `verify_none` or global trust installation.

## Accepted staging credential trade-off

The operator approved ordinary Fly app secrets for staging rather than a separate
migration job or migration app. Set `DATABASE_URL` to the restricted
`review_runtime` connection and `MIGRATION_DATABASE_URL` to the `review_migrator`
connection on the same Fly app. Keep the existing Fly release command invoking
`ReviewProject.Release.migrate/0`; do not put either URL in GitHub build/test jobs,
Docker build arguments, images, or committed files.

Fly supplies app secrets to both web and release Machines. The website normally
uses only the runtime role, but a compromised web process could read the migrator
credential and use its application-table ownership/schema-changing privileges.
The separate roles therefore limit normal database operations, but **do not
isolate migration credentials from the website**. The migrator is not a database
administrator; nevertheless its privileges can materially damage application
data and schema.

This compromise is accepted for the dedicated staging database only, not as a
production credential policy. Revisit separate migration execution before
production or if staging begins holding valuable/sensitive data. Never substitute
the Supabase admin or service-role API credentials. Rotate affected credentials
if exposed, and keep migrations compatible with the currently running release:
a successful migration is not automatically rolled back if deployment fails.

This decision authorizes documentation/configuration only. No secrets have been
uploaded and no Fly app, builder, Machine, or deployment has been created by this
change.

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

Production account email uses Resend with the fixed application-config sender
`ReviewProject <noreply@whatgrabsme.org>` and requires a nonblank `RESEND_API_KEY`
for boot, including release migrations. Before real delivery, the owner must
verify `whatgrabsme.org` in Resend and configure an authorized sending key; domain
verification and live delivery have not been established here. See [email setup](email.md).
Do not claim signup or confirmation delivery has been verified. TURN provider, credentials rotation,
transport support, usage caps and cost remain undecided. `CONFERENCE_ICE_CONFIG`
expects a server-side file; no TURN secrets are baked into the image and no file
mount is provisioned. Do not claim cross-network mesh reliability without these
choices and browser testing. No credentials are included in this change.
