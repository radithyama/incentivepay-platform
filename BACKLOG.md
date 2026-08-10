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
      backed by a new `incentivepay-admin-service` Keycloak service account (realm-management `manage-users` +
      `view-realm` - the second one only found by testing the approve flow live: `manage-users` covers
      creating/enabling users and assigning role mappings, but reading a realm role's representation
      (`GET /roles/{name}`, needed to resolve the role before assigning it) needs `view-realm` separately)
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
- [ ] **Second manual one-time step required on a fresh deployment**: the realm's User Profile config
      defaults to stripping any attribute not explicitly declared in its schema (`unmanagedAttributePolicy`
      unset = disabled) - so `requestedRole`, a custom attribute `KeycloakAdminClient` sets on new
      registrations, silently never got saved. Fixed live via
      `PUT /admin/realms/incentivepay/users/profile` with `"unmanagedAttributePolicy": "ENABLED"`. Not (yet)
      encoded in `realm-export.json` - Keycloak represents User Profile config as a realm *component*
      (`declarative-user-profile` provider), and hand-writing that structure correctly in the export JSON
      wasn't worth the risk of getting subtly wrong; a fresh deployment needs this same one-time `PUT` before
      the "requested role" ever shows up correctly in the approvals queue (the approve/reject flow itself
      works fine either way - this only affects the role the admin panel pre-selects).

## CD pipeline

- [x] Restricted `deploy` Linux user on the VM, sudo access scoped to exactly 5 whitelisted commands
      (`deploy/deploy.sh <service>`, one sudoers line per service - not a wildcard) via `/etc/sudoers.d/deploy`
- [x] Dedicated SSH keypair (not reused elsewhere), private key stored as a GitHub Actions secret
      (`DEPLOY_SSH_KEY`) in all 5 repos, VM host key pinned (`DEPLOY_VM_HOST_KEY`) rather than skipping
      host-key verification
- [x] `deploy` job added to every repo's `ci.yml`, gated on the test/build job passing and on `main` -
      verified for real (not just "the workflow succeeded"): confirmed the GitHub Actions run's own logs
      show it actually SSHing in, pulling the new commit, and rebuilding, and separately confirmed the
      restricted user genuinely can't run anything else (`sudo whoami`, argument injection, and an unlisted
      service name were all tested and correctly rejected)

## CD pipeline gaps found in use

- **No deploy lock across repos**: `deploy.sh` runs `docker compose up -d --build` against the whole
  stack, not just the one changed service. Pushing to two or more repos within the same few seconds
  (e.g. `incentive-api` and `frontend` together) triggers two concurrent GitHub Actions "Deploy to VM"
  jobs on the same VM, and they race recreating shared containers - one job's `up` renames/recreates a
  container out from under the other, which then fails with a Docker "Conflict: container name already
  in use" error and a non-zero exit. Confirmed live (2026-08-09): both jobs still landed their actual
  work correctly (new images built, containers swapped to the new build) since exactly one side of each
  race won, but the failed CI run is misleading - it reads as "deploy broken" when the deploy actually
  succeeded. Worth a proper fix (a lock file/mutex in `deploy.sh`, or scoping `up` to just the changed
  service) before pushing to multiple repos back-to-back is trusted at face value from CI status alone;
  until then, verify via `docker ps` / a live health check rather than the workflow's green check.
- **Bind-mounted config changes didn't reach the running containers**: `caddy` and `keycloak` are
  configured almost entirely via bind-mounted files (`Caddyfile`; the login theme and, on a fresh volume,
  `realm-export.json`), not environment variables or image contents. `docker compose up -d` only recreates
  a container when it detects the *resolved service definition* changed (image, env, the volume list) -
  it has no visibility into a bind-mounted file's *contents* changing on disk, so a config-only edit
  (e.g. adding security headers to the `Caddyfile`) silently kept the old file loaded in the already-running
  container. Confirmed live (2026-08-10): the `caddy` container was 19+ hours old and had never picked up
  several Caddyfile edits made across that window, despite each one going through a normal `platform`
  deploy and even an explicit `caddy reload` (which reloads Caddy's *already-mounted*, still-stale file -
  it can't discover a change it was never told about). Fixed by having the `platform` deploy path always
  `--force-recreate caddy keycloak` after `up -d --build`, so bind-mounted config is guaranteed fresh every
  time regardless of whether Compose thinks anything else changed. The general lesson: verify config-only
  infra changes by checking the *running container's* view of the file (`docker exec <c> cat <path>` or a
  live header/response check), not just "the deploy job succeeded" or "the host file has the new content."

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
