# IncentivePay

[![CI](https://github.com/radithyama/incentivepay-platform/actions/workflows/ci.yml/badge.svg)](https://github.com/radithyama/incentivepay-platform/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A rules engine that calculates, routes for approval, and disburses employee bonuses and partner
commissions - role-gated, HMAC-signed, and event-driven, the same way a real payment platform would need to
be. Built against [`PRD-IncentivePay-Portfolio-App.md`](PRD-IncentivePay-Portfolio-App.md) as a portfolio
piece for a Payment Platform / Incentive Platform engineering role.

**What it demonstrates, concretely:**
- Rules-based business logic (Strategy pattern for FLAT/PERCENTAGE/TIERED calculation), not just CRUD
- A real approval/authorization workflow with RBAC (four Keycloak roles behave differently, and it's tested)
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

This was built in one sitting with Claude Code, **without Docker installed in the build environment** - so
everything is written and unit/slice-tested per-repo, but the full docker-compose stack across all 5 repos
has not actually been run end-to-end yet. See each repo's `AI_USAGE.md`/README for specifics, and
[`BACKLOG.md`](BACKLOG.md) here for the itemized list of what's done vs. what still needs a real Docker run
(Testcontainers integration tests, the k6 load test, a first end-to-end docker-compose pass).

Observability (OpenTelemetry/Jaeger/Grafana) is not implemented - cut per the PRD's explicit priority order
(Section 11). `infra/k8s/` manifests are written as code but not deployed to a live cluster - per the PRD's
non-goals (Section 3).

Approvals-queue screenshot: not yet captured, since that needs the stack actually running. TODO once Docker
is available.

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

## Keycloak setup

The realm `incentivepay` is imported automatically from `infra/keycloak/realm-export.json` on first
`docker-compose up`. It defines four realm roles and one demo user per role, all with password
`incentivepay-demo`:

| Username | Role | Can do |
|---|---|---|
| `admin-demo` | `incentive-admin` | Manage rules and participants, run bulk imports |
| `approver-demo` | `approver` | Approve/reject pending disbursements |
| `financeops-demo` | `finance-ops` | View the ledger (read-only beyond that in this build) |
| `viewer-demo` | `viewer` | Read-only everywhere |

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

Swap `username` for any of the four demo users to test the other roles. The one test worth running by hand:
grab a `viewer-demo` token and `POST` to `/v1/disbursements/{id}/approve` - it should 403, not 200 (see
`incentivepay-incentive-api`'s `DisbursementControllerAuthorizationTest` for the automated version).

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
