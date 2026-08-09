# Backlog

Sprint tickets for the 3-day build (see `PRD-IncentivePay-Portfolio-App.md` Section 11). Trunk-based,
conventional commits. Checked items are done; unchecked items are the honest state of what's left.

## Day 1 - Domain, rules engine, security

- [x] Repo scaffold: initially a multi-module Maven build, later split into 5 standalone repos (see below), Java 21
- [x] `Participant`, `IncentiveRule` (+ `RuleTier`), `IncentiveEvent`, `Disbursement` entities
- [x] Strategy pattern rule calculators: `FlatRuleStrategy`, `PercentageRuleStrategy`, `TieredRuleStrategy`
- [x] `DisbursementStateMachine` - single source of truth for legal status transitions
- [x] Keycloak OAuth2 resource server + realm-role-to-authority mapping (`KeycloakRealmRoleConverter`)
- [x] HMAC-SHA256 request signing filter, timing-safe comparison, replay window via clock-skew check
- [x] Unit tests: rule strategies (incl. tiered boundary cases), state machine transitions
- [x] Authorization slice test: viewer hitting an approver-only endpoint gets 403

## Day 2 - Approval workflow + event chain

- [x] `POST /v1/disbursements/{id}/approve` and `/reject` (role-gated, HMAC-signed, reason required on reject)
- [x] Auto-approve threshold routing (`ApprovalProperties`)
- [x] Simulated payment rail call (`PaymentRailClient`) + `disbursement.completed` Kafka event
- [x] `ledger-service`: consumer, append-only table, dedupe on `disbursementId`, reconciliation endpoint
- [x] `notification-service`: consumer, simulated payout notice, non-blocking retry + backoff + DLT

## Day 3 - Batch import, frontend, infra, ship

- [x] Spring Batch CSV bulk-import job (chunk-oriented, per-row validation, `ImportRowAudit` trail)
- [x] Idempotent on `externalEventId` (checked in the writer, also enforced by a DB unique constraint)
- [x] React dashboard: approvals queue, bulk import, rules, ledger lookup, role badge
- [x] `docker-compose.yml`, per-service `Dockerfile`s, Keycloak realm export
- [x] `k8s/` manifests (written as code; not deployed - Section 3 non-goal)
- [x] README, `AI_USAGE.md`, LICENSE, CI badge
- [x] GitHub Actions CI (backend `mvn verify`, frontend `npm run build`)
- [ ] k6 load test on the bulk import endpoint - not yet written. Now possible against the live deployment
      (see below) or a local stack; just hasn't been done yet.
- [ ] Testcontainers integration tests (real Postgres/Kafka/Keycloak) - written as unit/slice tests instead
      for the original build session since Docker wasn't installed; still not backfilled.

## Deployed to GCP Compute Engine

- [x] `e2-medium` VM, static IP, `asia-southeast2-a`, provisioned via `gcloud` - Compute Engine API enabled,
      billing confirmed on the target project first
- [x] `deploy/gce-startup.sh` - idempotent instance startup script: Docker install, 4GB swapfile, clone all 5
      repos, bring up `docker-compose.prod.yml`
- [x] `docker-compose.prod.yml` - production overlay (`restart: unless-stopped`, secrets via env vars, ports
      rebound to `127.0.0.1`) using the Compose Spec `!override` merge tag, deliberately - Compose's default
      merge behavior *concatenates* list fields like `ports` across files rather than replacing them, which
      would have left Postgres/Kafka reachable from the internet even with a "127.0.0.1-only" override
- [x] Caddy reverse proxy (`deploy/Caddyfile`) for automatic HTTPS across all 5 subdomains on
      `radithyama.app` (user's existing domain, DNS on Vercel) - `www` redirects to the apex
- [x] Two bugs only visible once actually deployed with a real domain, found and fixed live via the Keycloak
      admin API, then fixed at the source: demo users missing `firstName`/`lastName` (Keycloak 25's
      `VERIFY_PROFILE` required action), and the OAuth client's `redirectUris` only allowing `localhost`. Full
      account in `AI_USAGE.md`.
- [x] Temporary firewall rule (opened for phase-1 direct-IP verification before DNS was live) removed once
      Caddy + HTTPS were confirmed working

## Split into 5 repos

Built first as a single monorepo (one multi-module Maven reactor + frontend + infra), then split at the
user's request into `incentivepay-incentive-api`, `incentivepay-ledger-service`,
`incentivepay-notification-service`, `incentivepay-frontend`, and this platform repo. Splitting meant:

- [x] Each Java service's `pom.xml` rewritten to inherit `spring-boot-starter-parent` directly instead of a
      shared internal parent POM - fully standalone, independently cloneable/buildable
- [x] Re-verified `mvn test` green in each service after the split (same 34/2/2 tests, no regressions)
- [x] Each service repo also got its own standalone `docker-compose.yml` (own Postgres/Kafka/Keycloak where
      needed) so it's runnable without checking out the other 4 repos
- [x] `incentive-api` and `ledger-service` each carry their own copy of `keycloak/realm-export.json` (needed
      for their standalone compose files) - small, deliberate duplication; this platform repo's copy under
      `infra/keycloak/` remains the source of truth referenced by the full-stack `docker-compose.yml`
- [x] Per-repo CI workflow (`mvn verify` for the 3 Java repos, `npm run build` for frontend, YAML validation
      for this repo)

## UI overhaul, self-registration + approval, Keycloak login theme

- [x] CSS-only Keycloak login theme (`deploy/keycloak-theme`), reskinning the hosted login page rather than
      replacing the OAuth2 redirect flow
- [x] Self-registration (`POST /v1/auth/register`, public) + admin approval queue (`/v1/admin/pending-registrations`),
      backed by a new `incentivepay-admin-service` Keycloak service account (realm-management `manage-users`
      role only)
- [x] Frontend: Tailwind CSS, sidebar shell, unauthenticated landing page (login/register), Pending Approvals
      admin panel, restyled the 4 existing panels
- [x] Keycloak data now persisted (`keycloak-data` volume) - previously every config-driven container
      recreation silently wiped all realm data, since `start-dev`'s embedded H2 lived in container-local storage
- [ ] **Known gap, not yet resolved**: the service account's `manage-users` client-role mapping, declared in
      `realm-export.json`, does not reliably survive a fresh `--import-realm` (confirmed once - the client and
      its service-account user both import correctly, but the role mapping between them doesn't). Fixed live via
      the Admin API on this deployment; a fresh deployment elsewhere would need the same one-time fix
      (`AI_USAGE.md` has the full diagnosis). Worth a proper fix (a startup script step, or filing upstream)
      before this is relied on unattended.

## Known cuts / simplifications (see README for the full explanation of each)

- Frontend HMAC signing uses a build-time secret shipped to the browser - fine for a demo, not for
  production (a real deployment would sign server-side via a BFF).
- Multipart CSV upload is exempt from HMAC signing (see `HmacSignatureFilter`).
- Bulk import runs synchronously in the HTTP request; a very large file would want async + polling.
- `spring.batch.jdbc.initialize-schema: always` is a dev convenience, not how you'd run this against a
  real environment (Batch's own schema would be a migration too).

## Post-interview roadmap (PRD Section 15)

- [ ] Deploy to a local `kind`/`minikube` cluster from the existing `k8s/` manifests
- [ ] OpenTelemetry/Jaeger/Grafana observability stack
- [ ] More tiered-rule boundary tests (this is where rules engines actually break)
- [ ] `CONTRIBUTING.md` + issue templates
- [ ] Write-up on the RBAC + approval-workflow design
