# IncentivePay

[![CI](https://github.com/radithyama/incentivepay-platform/actions/workflows/ci.yml/badge.svg)](https://github.com/radithyama/incentivepay-platform/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A rules engine that calculates, routes for approval, and disburses employee bonuses and partner
commissions - role-gated, HMAC-signed, and event-driven, the same way a real payment platform would need to
be. Built against [`PRD-IncentivePay-Portfolio-App.md`](PRD-IncentivePay-Portfolio-App.md) as a portfolio
piece for a Payment Platform / Incentive Platform engineering role.

**Live:** [incentivepay.radithyama.app](https://incentivepay.radithyama.app) - log in as `approver-demo` /
`incentivepay-demo` (or any of the five demo users, see "Keycloak setup" below), or request a new account from
the login screen (a `user-admin` has to approve it before it works - see "Self-registration" below).
Deployed on Google Cloud Compute Engine (`e2-medium`) behind Caddy for automatic HTTPS, with a CD pipeline
that redeploys on every push to `main`; see [`docker-compose.prod.yml`](docker-compose.prod.yml),
[`deploy/`](deploy/), and "CD pipeline" below.

**What it demonstrates, concretely:**
- Rules-based business logic (Strategy pattern for FLAT/PERCENTAGE/TIERED calculation), not just CRUD
- A real approval/authorization workflow with RBAC (five Keycloak roles behave differently, and it's tested)
- The security patterns a payment platform needs (OAuth2 + HMAC-signed mutations) applied to a disbursement
  engine instead of a payment simulator
- The Spring Batch + audit-logging pattern from bulk-processing pipeline work, on a bulk incentive import

This is the **platform repo**: it holds the pieces that tie the other four together (docker-compose, Keycloak
realm, Kubernetes manifests) and the project-wide docs. Each deployable unit is its own repo:

| Repo | What it is |
|---|---|
| [`incentivepay-incentive-api`](https://github.com/radithyama/incentivepay-incentive-api) | Rules engine, approval workflow, disbursement processing, Spring Batch bulk import |
| [`incentivepay-ledger-service`](https://github.com/radithyama/incentivepay-ledger-service) | Consumes `disbursement.completed`, append-only reconciliation ledger |
| [`incentivepay-notification-service`](https://github.com/radithyama/incentivepay-notification-service) | Consumes `disbursement.completed`, simulated payout notice, retry/backoff/DLQ |
| [`incentivepay-frontend`](https://github.com/radithyama/incentivepay-frontend) | React + Vite + TypeScript ops dashboard |

## Architecture

```
   CSV Upload ──▶ Spring Batch Job ──▶ IncentiveEvent ──▶ Rule Engine (Strategy) ──▶ Disbursement
                                                                                          │
                                                          PENDING_APPROVAL ──approve──▶ APPROVED
                                                                                          │
                                                                              (simulated payment rail call)
                                                                                          │
                                                                                      DISBURSED
                                                                                          │
                                                                        Kafka: disbursement.completed
                                                                 ┌────────────────────────┴───────────────────────┐
                                                          ledger-service                                  notification-service
                                                       (append-only, per participant)                (retry/backoff, DLQ)

Cross-cutting: Keycloak (OAuth2 + roles) | HMAC signing on mutating endpoints | React ops dashboard
```

Three Spring Boot services, one React dashboard, each with its own Postgres database where applicable;
Kafka-compatible messaging is via Redpanda.

## Status (honest)

This was built in one sitting with Claude Code, initially **without Docker installed in the build
environment** - so the core services were written and unit/slice-tested per-repo before ever running as a
whole. The full stack has since been deployed end-to-end to a real GCP Compute Engine VM (see "Live" above),
which surfaced two real bugs that only show up under actual deployment (a Keycloak required-action quirk and
a redirect-URI mismatch) - see `AI_USAGE.md` for the full account of both, including how they were caught and
fixed.

Not yet done: Testcontainers integration tests and a k6 load test against the bulk-import endpoint - both
possible now that a real Postgres/Kafka/Keycloak stack exists, just not written yet. See
[`BACKLOG.md`](BACKLOG.md) for the itemized list.

Observability (OpenTelemetry/Jaeger/Grafana) is not implemented - cut per the PRD's explicit priority order
(Section 11). `infra/k8s/` manifests are written as code but not deployed to a live cluster (the live
deployment above uses plain Compute Engine + Docker Compose, not Kubernetes) - per the PRD's non-goals
(Section 3).

Approvals-queue screenshot: not yet captured. TODO.

## Quickstart

Requires Docker and Docker Compose, and all 5 repos cloned as **sibling directories**:

```bash
mkdir incentivepay && cd incentivepay
git clone https://github.com/radithyama/incentivepay-platform.git
git clone https://github.com/radithyama/incentivepay-incentive-api.git
git clone https://github.com/radithyama/incentivepay-ledger-service.git
git clone https://github.com/radithyama/incentivepay-notification-service.git
git clone https://github.com/radithyama/incentivepay-frontend.git

cd incentivepay-platform
docker-compose up --build
```

This starts two Postgres instances, Redpanda, Keycloak (pre-loaded with the `incentivepay` realm from
`infra/keycloak/realm-export.json`), all three Spring Boot services (built from the sibling repos via
relative `build.context` paths), and the frontend.

- Dashboard: http://localhost:5173
- `incentive-api`: http://localhost:8080
- `ledger-service`: http://localhost:8082
- Keycloak admin console: http://localhost:8081 (`admin` / `admin`)

First boot takes a minute or two - Keycloak needs to come up and import the realm before the backend
services can validate tokens, and Flyway needs each Postgres instance to be ready before migrating.

Each service repo also has its own standalone `docker-compose.yml` if you just want to run one service in
isolation (e.g. to work on `incentive-api` alone) - see that repo's README.

## Live deployment (GCP Compute Engine)

The instance running at [incentivepay.radithyama.app](https://incentivepay.radithyama.app):

- Single `e2-medium` Compute Engine VM (Ubuntu 22.04), static external IP, `asia-southeast2-a`
- [`deploy/gce-startup.sh`](deploy/gce-startup.sh) as the instance startup script: installs Docker, adds a
  4GB swapfile (this stack is memory-hungry for a 4GB-RAM instance size), clones all 5 repos, and brings the
  stack up via [`docker-compose.prod.yml`](docker-compose.prod.yml) - a production overlay on top of the dev
  compose file (`restart: unless-stopped`, DB/Kafka/notification-service never exposed publicly, real
  generated secrets instead of the dev defaults)
- [`deploy/Caddyfile`](deploy/Caddyfile): Caddy reverse-proxies each subdomain to its container over the
  internal Docker network and handles automatic HTTPS (Let's Encrypt) - it's the only thing with ports 80/443
  published to the internet; every app service's own port is rebound to `127.0.0.1`
- DNS is on Vercel (`radithyama.app`'s registrar/DNS host), pointed at the VM's static IP via one apex A
  record (`incentivepay`) and one wildcard (`*.incentivepay`) covering `api.`, `ledger.`, `auth.`, and `www.`
- Secrets (`HMAC_SECRET`, `KEYCLOAK_ADMIN_PASSWORD`) are generated once and passed as GCE instance metadata,
  written to a gitignored `.env.prod` on first boot - never committed; see `.env.prod.example`

This is intentionally a single small VM, not Kubernetes - `infra/k8s/` exists as written-but-undeployed code
per the PRD's stated scope (Section 3), and this deployment predates any decision to actually stand up a
cluster for it.

## CD pipeline

Every push to `main` in any of the 5 repos redeploys automatically, no manual step:

1. That repo's own CI job runs (`mvn verify` or `npm run build`)
2. On success, a `deploy` job SSHes into the VM as a **restricted `deploy` user** and runs
   [`deploy/deploy.sh`](deploy/deploy.sh) with one argument (which service changed)
3. `deploy.sh` `git pull`s just that service's repo and runs
   `docker compose -f docker-compose.yml -f docker-compose.prod.yml --env-file .env.prod up -d --build <service>`
   - Docker Compose only actually recreates the container if something meaningfully changed, so a
     no-op-content push doesn't cause a restart
   - Pushing to `incentivepay-platform` itself runs the same command without a service argument (rebuilds
     the whole stack), since that's where `docker-compose.yml`/`Caddyfile`/`realm-export.json` live

The `deploy` user's sudo access is scoped to exactly five whitelisted commands (`/etc/sudoers.d/deploy`) -
`deploy.sh <incentive-api|ledger-service|notification-service|frontend|platform>` and nothing else, not even
plain `sudo whoami`. A leaked deploy key can redeploy known-good code from GitHub; it can't run arbitrary
commands as root. The SSH keypair is dedicated to this one purpose (not reused elsewhere) and stored as a
GitHub Actions secret (`DEPLOY_SSH_KEY`) in each of the 5 repos, alongside a pinned host key
(`DEPLOY_VM_HOST_KEY`) so the workflow verifies it's actually talking to the right VM rather than skipping
host-key checking.

## Keycloak setup

The realm `incentivepay` is imported automatically from `infra/keycloak/realm-export.json` on first
`docker-compose up`. It defines five realm roles and one demo user per role, all with password
`incentivepay-demo`:

| Username | Role | Can do |
|---|---|---|
| `admin-demo` | `incentive-admin` | Manage rules and participants, run bulk imports |
| `approver-demo` | `approver` | Approve/reject pending disbursements |
| `financeops-demo` | `finance-ops` | View the ledger (read-only beyond that in this build) |
| `viewer-demo` | `viewer` | Read-only everywhere |
| `useradmin-demo` | `user-admin` | Approve new account requests, assign roles - nothing else |

`user-admin` is split out from `incentive-admin` on purpose: the role that shapes payout rules and the role
that grants system access are different concerns, and bundling them into one super-admin is the kind of
separation-of-duties gap a real access review would flag. `incentive-admin` has zero access to
`/v1/admin/**`; `user-admin` has zero access to rules, participants, events, or the ledger.

The dashboard's login redirects to Keycloak's standard Authorization Code + PKCE flow - log in as whichever
demo user you want to test as.

To get a raw token for `curl`/Postman testing (password/direct-access grant, which the `incentivepay-client`
client has enabled for exactly this purpose):

```bash
curl -s -X POST http://localhost:8081/realms/incentivepay/protocol/openid-connect/token \
  -d grant_type=password \
  -d client_id=incentivepay-client \
  -d username=approver-demo \
  -d password=incentivepay-demo \
  | jq -r .access_token
```

Swap `username` for any of the five demo users to test the other roles. The one test worth running by hand:
grab a `viewer-demo` token and `POST` to `/v1/disbursements/{id}/approve` - it should 403, not 200 (see
`incentivepay-incentive-api`'s `DisbursementControllerAuthorizationTest` for the automated version).

### Custom login theme

The Keycloak login page you land on when you click "Log in" isn't the stock Keycloak look - it's a CSS-only
theme (`deploy/keycloak-theme/incentivepay`, mounted read-only into the Keycloak container and set as the
realm's `loginTheme`) that reskins Keycloak's own hosted page rather than replacing the login flow with a
custom one. That was a deliberate tradeoff: a fully custom embedded login form would mean this app's frontend
handling raw passwords directly (the OAuth2 "resource owner password credentials" grant, considered legacy in
OAuth 2.1) and losing MFA/password-reset for free. The redirect-based flow keeps all of that working; only the
CSS changed.

### Self-registration + admin approval

New users don't get instant access. `POST /v1/auth/register` (no auth required) creates a Keycloak user that
is **disabled and has no role** - just a `requestedRole` attribute recording what they asked for. Nothing
happens until a `user-admin` reviews it on the **Pending approvals** tab and either approves (assigns a
role - not necessarily the one requested - and enables the account) or rejects (deletes it). This is backed
by a dedicated Keycloak service account (`incentivepay-admin-service`, `incentive-api`'s
`KeycloakAdminClient`) holding only the two `realm-management` client roles it actually needs
(`manage-users`, `view-realm`) - not full admin access.

### Why `jwk-set-uri`, not `issuer-uri`

Both backend services validate JWTs against `jwk-set-uri`, not the more common `issuer-uri`. That's
deliberate: in docker-compose, the backends reach Keycloak internally at `http://keycloak:8080`, but Keycloak
issues tokens with `iss=http://localhost:8081` (`KC_HOSTNAME=localhost`, so browser redirects and discovery
URLs stay host-reachable). `issuer-uri` requires those two to match exactly; `jwk-set-uri` only needs a
reachable key-fetch endpoint, which sidesteps the whole problem. This is documented in more detail (including
how it was caught) in `incentivepay-incentive-api`'s `AI_USAGE.md`.

### HMAC request signing

Every mutating endpoint (`POST`/`PUT`/`PATCH`/`DELETE`) on `incentive-api` requires two headers on top of the
bearer token:

- `X-Timestamp`: epoch seconds, must be within 300s of server time
- `X-Signature`: hex `HMAC-SHA256("METHOD\nPATH\nTIMESTAMP\nBODY", secret)`, timing-safe compared

The shared secret is `HMAC_SECRET` (default `dev-only-shared-secret-change-me` - change it for anything
beyond local demo use). The frontend computes this client-side via the Web Crypto API - a known
simplification, since a browser has no safe place to hold a shared secret. A real deployment would put this
behind a backend-for-frontend that signs server-side, or restrict HMAC-signed mutations to server-to-server
integrations only. Multipart CSV uploads are exempt from signing entirely (see `HmacSignatureFilter` in
`incentivepay-incentive-api`) since a whole-body-hash scheme doesn't fit a large file payload well.

## Repo layout (this repo)

```
infra/
  keycloak/realm-export.json   Source of truth for roles/demo users
  k8s/                          Deployment/Service manifests (written, not deployed)
docker-compose.yml              Full stack, references sibling repos as build contexts
PRD-IncentivePay-Portfolio-App.md
BACKLOG.md                      Sprint tickets, done vs. not done
AI_USAGE.md                     Real prompts + a few "the first draft was wrong" stories
```

## License

MIT - see [LICENSE](LICENSE). Each of the 5 repos carries its own copy.
