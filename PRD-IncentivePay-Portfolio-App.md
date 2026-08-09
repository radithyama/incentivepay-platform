# Product Requirements Document
## IncentivePay — Employee & Partner Incentive Disbursement Platform
**A portfolio project built for: Software Engineer – Payment Platform (Java), Rakuten TPD — Incentive Platform Department**

*Replaces the earlier SecurePay (QRIS simulator) concept. Scoped to a 3-day build with Claude Code, kept as a public, long-term GitHub portfolio piece.*

---

## 0. Why this business case

The JD sits you in the **Incentive Platform Department**, which "develops payment and incentive platforms." A generic payment simulator proves you can build payment APIs; it doesn't prove you understand *incentive* systems — the rules engines, approval workflows, and disbursement logic that sit on top of a payment rail rather than being one. IncentivePay is built to prove both halves at once: it's a rules-driven engine that decides **who gets paid, how much, and under what approval**, then hands off to a simulated payment rail using the same signed-request security model a real one would need.

It also gives you a direct callback to a specific CV bullet that the earlier concept didn't touch: your BNI experience *"hardened Spring Batch processing pipelines with audit logging, integrity checks, and compliance-aligned monitoring."* This PRD builds that exact pattern in for bulk incentive processing (Section 6.1).

**Decisions carried over from the earlier PRD** (not re-asked, assumed unless you say otherwise): repo is public on GitHub from day one and meant to keep growing after the interview; Keycloak setup is documented in the README.

**Decisions locked in for this version:**
- Business case: **employee/partner incentive disbursement** (commissions, bonuses, referral payouts) — not consumer cashback.
- Build window: **3 days**, tighter than the earlier 3–4 day estimate, so scope is trimmed harder and the "if time runs out" cut order is explicit (Section 11).
- Stack: kept the same core (Java/Spring Boot, Keycloak OAuth2, HMAC signing, Kafka, Docker), but **added** role-based access control and Spring Batch — both because the domain genuinely needs them, not just to pad the stack.

---

## 1. Purpose

This is a **live demo artifact** for a technical interview and, afterward, a permanent public portfolio piece. Every feature exists to give a concrete, walk-through-able answer to "tell me about a time you..." questions, and specifically to demonstrate: rules-based business logic (not just CRUD), an approval/authorization workflow with real RBAC, and the same secure, event-driven, audit-grade patterns your CV already claims for payment systems — applied to a different problem so it reads as genuine understanding, not a copy-pasted demo.

**Working name:** IncentivePay
**One-liner:** A rules engine that calculates, routes for approval, and disburses employee bonuses and partner commissions — role-gated, signed, and event-driven, the same way a real payment platform would need to be.

---

## 2. Goals & Success Criteria

| Goal | Success looks like |
|---|---|
| Prove hands-on Java/Spring Boot + business-rules design | Interviewer can trace one incentive event through calculation → approval → disbursement → ledger |
| Show RBAC / authorization design, not just authentication | Three distinct Keycloak roles behave visibly differently in the demo (admin vs. approver vs. viewer) |
| Directly mirror a CV bullet (Spring Batch, audit logging) | A live bulk-import demo: upload a CSV of sales events, watch it process as an auditable batch job |
| Show secure-by-design habits (mirrors CV) | OAuth2 (Keycloak) + HMAC signing on every mutating endpoint |
| Demonstrate AI-assisted engineering (JD preferred qual) | A short `AI_USAGE.md` log of real Claude Code prompts/decisions during the build |
| Be demoable in ~10 minutes | One scripted end-to-end flow: bulk import → approval queue → approve → disbursed → ledger entry |
| Survive past the interview as a real portfolio piece | Public repo, MIT license, CI badge, clean commit history |

---

## 3. Non-Goals (deliberately out of scope)

- Actually moving money — disbursement calls a **simulated** payment rail, same "simulator" boundary as before.
- Full payroll/tax compliance (W-2 vs 1099 handling, withholding calculations) — the domain distinction between `EMPLOYEE` and `PARTNER` participants is modeled, but tax logic is explicitly not.
- General HR features (onboarding, org charts, performance reviews) — this is a disbursement engine, not an HR platform.
- Consumer-facing anything — this is an internal/B2B tool, so the frontend is an ops dashboard, not a polished consumer app.
- A live, running Kubernetes deployment and a full Grafana/Jaeger stack — written and documented as stretch goals (Section 11), same as before.

---

## 4. JD → Feature Alignment Matrix

| JD Requirement | App Feature | Target |
|---|---|---|
| Java, Spring Boot, Spring Framework, SQL | Core service in Spring Boot 3 + PostgreSQL, layered architecture | Day 1 |
| Software architecture & design patterns | **Strategy pattern** for incentive rule types (flat / percentage / tiered); **state machine** for disbursement lifecycle | Day 1 |
| Secure coding practices | Keycloak OAuth2 + role claims, HMAC-SHA256 request signing, timing-safe comparison, input validation | Day 1 |
| RESTful APIs & microservices | `incentive-api`, `ledger-service`, `notification-service` over REST + Kafka | Day 1–2 |
| Git & Agile methodology | Trunk-based history, conventional commits, `BACKLOG.md` as sprint tickets | Day 1 |
| Performance tuning & optimization | Load test + tuning pass on the **bulk import** path (the realistic bottleneck: a quarter-end run processing thousands of events at once) | Day 3 |
| Basic front-end (HTML/CSS/JS) | React ops dashboard: rule management, approvals queue, participant ledger view | Day 3 |
| Testing frameworks & performance testing | JUnit5 + Mockito, Testcontainers, k6 | Continuous |
| AI-assisted dev tools / LLM prompt engineering | `AI_USAGE.md` — real prompts, real corrections | Continuous |
| Large-scale payment systems experience | Direct callback: **Spring Batch bulk-import job with audit logging and integrity checks**, matching the CV's BNI bullet verbatim | Day 3 |
| Docker, Kubernetes, cloud (AWS) | `docker-compose.yml` (required); `k8s/` manifests written (required); live deployment (stretch/post-interview) | Day 3 / Post-interview |
| Distributed tracing & monitoring | OpenTelemetry/Jaeger/Prometheus/Grafana (stretch — first thing cut if Day 3 runs short) | Stretch |
| Open-source contributions | Public repo, README, MIT license, CI badge | Day 3 |

---

## 5. User Stories (as "interviewer personas")

1. **As the interviewer skimming the repo**, I want a README with an architecture diagram and a "run it locally" path, so I can evaluate without a live demo.
2. **As the interviewer watching the demo**, I want to see the *same event* trigger different outcomes depending on amount (auto-approved vs. routed to an approver), so I trust the candidate designed a real authorization model, not a toy.
3. **As the interviewer asking about scale**, I want to see a bulk CSV import processed as an auditable batch job — with a record of what succeeded, what failed, and why — so the "compliance-aligned monitoring" language on the CV has a receipt.
4. **As the interviewer curious about AI tool usage**, I want one concrete example of a prompt that produced wrong or insecure code and how it was caught.
5. **As a stranger finding this on GitHub later**, I want it to look like a maintained project, not an abandoned interview exercise.

---

## 6. Core Features (MVP scope)

### 6.1 Bulk Incentive Import (`incentive-api`, Spring Batch)
- CSV upload (`participantId`, `ruleId`, `eventType`, `amount`/`saleValue`, `externalEventId`)
- Spring Batch job: chunk-oriented processing, per-row validation, a job execution audit record (rows processed / skipped / failed, with reasons)
- Idempotent on `externalEventId` — re-uploading the same file, or re-running a failed job, never double-creates disbursements
- This is the slice that most directly answers "tell me about your Spring Batch experience"

### 6.2 Incentive Rules Engine
- `IncentiveRule`: type (`FLAT`, `PERCENTAGE`, `TIERED`), applies-to (`EMPLOYEE`, `PARTNER`, or both), effective date range
- Strategy pattern: one calculation strategy per rule type, so adding a new rule type later doesn't touch existing ones
- An `IncentiveEvent` (from bulk import or a single manual entry) is evaluated against the applicable rule to produce a computed `Disbursement`

### 6.3 Approval Workflow (RBAC)
- Keycloak roles: `incentive-admin` (manage rules), `approver` (approve/reject disbursements), `finance-ops` (process approved disbursements, view ledger), `viewer` (read-only)
- Disbursements below a configurable threshold auto-approve; above it, they sit `PENDING_APPROVAL` until an `approver` acts
- `POST /v1/disbursements/{id}/approve` and `/reject` — role-gated, HMAC-signed, reason required on reject

### 6.4 Disbursement Processing (`incentive-api`)
- On approval, a processing step simulates handing off to a payment rail (a stubbed internal call, signed the same way a real one would be), then marks `DISBURSED` and publishes `disbursement.completed` to Kafka

### 6.5 Ledger Service (`ledger-service`)
- Consumes `disbursement.completed`, append-only ledger, dedupes on delivery
- `GET /v1/ledger/{participantId}` — "how much has this person been paid, and for what" — the reconciliation view

### 6.6 Notification Service (`notification-service`)
- Consumes ledger events, simulates a payout notice to the participant, retry + backoff + dead-letter topic on repeated failure (same pattern as before — it's a good pattern, no need to reinvent it)

### 6.7 Ops Dashboard (React, thin)
- Rule management (admin), approvals queue with approve/reject (approver), CSV upload for bulk import, participant ledger lookup
- Role indicator in the UI so the RBAC story is visible, not just enforced server-side invisibly

---

## 7. Technical Architecture

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

Cross-cutting: Keycloak (OAuth2 + roles) | HMAC signing on all mutating endpoints | OpenTelemetry/Jaeger/Grafana (stretch)
```

**Stack**
- Backend: Java 21, Spring Boot 3, Spring Security (OAuth2 resource server + role checks), Spring Batch, Spring Kafka, Spring Data JPA
- DB: PostgreSQL, one per service
- Messaging: Kafka (Redpanda locally)
- Auth: Keycloak, realm exported as JSON, roles: `incentive-admin`, `approver`, `finance-ops`, `viewer`
- Frontend: React + Vite
- Infra: Docker Compose (required), `k8s/` manifests (required as code, live deployment stretch)
- Testing: JUnit5, Mockito, Testcontainers, k6

---

## 8. Non-Functional Requirements

- **Idempotency:** bulk import is safe to re-run; a duplicate `externalEventId` is skipped and logged, not double-paid.
- **Auditability:** every Spring Batch job execution is queryable — what ran, when, how many rows succeeded/failed and why. This is the direct proof point for "audit-grade" and "compliance-aligned monitoring."
- **Authorization, not just authentication:** a valid token alone isn't enough — role claims are checked per-endpoint, and this is tested, not just implemented.
- **Latency target (bulk path):** documented after a real k6 run against the import endpoint at a realistic batch size (e.g., 5,000 rows) — state the number found, don't invent one in advance.

---

## 9. Testing Strategy

| Layer | Tool | What it proves |
|---|---|---|
| Unit | JUnit5 + Mockito | Rule-calculation strategies, approval state machine transitions |
| Integration | Testcontainers (Postgres + Kafka + Keycloak) | Real batch job execution, real token validation, real event flow |
| Load | k6 | Bulk import throughput claim is backed by a report |
| Authorization (specific) | Integration tests per role | A `viewer` token hitting `/approve` gets 403, not 200 — this is worth its own explicit test, it's the whole RBAC story |

---

## 10. AI-Assisted Development Log (`AI_USAGE.md`)

Same discipline as before: log real prompts as you go, keep at least one "AI got this wrong, here's how it was caught" entry. Good candidates for this project specifically: an AI-suggested rule-calculation approach that mishandled tiered percentages at a boundary value, or a first-draft RBAC check that validated the role but not the resource ownership.

---

## 11. Build Plan — 3-Day Sprint

Tighter than the earlier 4-day plan, so the cut order matters. **Day 1–2 is non-negotiable — it's the whole secure, rules-driven core.** Day 3 is prioritized top-to-bottom; if time runs out, stop wherever you are and ship the README honestly reflecting what's done.

| Day | Focus | Deliverables |
|---|---|---|
| **Day 1** | Domain, rules engine, security | Repo scaffold, health check; `Participant`, `IncentiveRule` (Strategy pattern), `IncentiveEvent` → `Disbursement` calculation; Keycloak with 4 roles wired in; HMAC signing filter; unit + integration tests for the calculation logic and the auth/signing layers |
| **Day 2** | Approval workflow + event chain | Approve/reject endpoints (role-gated); disbursement processing → `disbursement.completed`; `ledger-service` (consume, append-only, dedupe, reconciliation endpoint); `notification-service` (consume, retry/backoff, DLQ) |
| **Day 3** | Batch import, frontend, infra, ship | *(in priority order — stop anywhere below and the project still stands)* 1) Spring Batch CSV bulk-import job with audit trail 2) React dashboard: rules, approvals queue, ledger view, CSV upload 3) `docker-compose.yml` finalized, full flow works from a clean clone 4) README + `AI_USAGE.md` + license + CI badge 5) k6 load test on bulk import 6) GitHub Actions CI 7) `k8s/` manifests (stretch) |

---

## 12. Demo Script (for the interview itself)

1. **30s:** Architecture diagram — narrate the flow: bulk import → rules engine → approval → disbursement → ledger.
2. **2 min:** Upload a small CSV of "sales events" → watch the Spring Batch job run, show the audit summary (rows processed/skipped/failed).
3. **1 min:** Open the approvals queue as an `approver` — approve one, reject one with a reason.
4. **1 min:** Switch to a `viewer` token, attempt to hit the approve endpoint directly → 403. This is the RBAC story landing concretely.
5. **1 min:** Show the ledger entry for a participant, tie it back to "audit-grade" language on the CV.
6. **1 min:** `AI_USAGE.md` — the one honest "AI got this wrong" story.

Total: ~7 minutes, room for questions.

---

## 13. Risks

| Risk | Mitigation |
|---|---|
| 3 days for this scope is genuinely tight — tighter than the earlier plan, with more added (RBAC, Spring Batch) | Day 1–2 is fixed and non-negotiable; Day 3's priority-ordered list means the project is demoable at any stopping point |
| RBAC bugs are the easiest thing to get subtly wrong under time pressure | The explicit "viewer hits /approve → 403" test in Section 9 isn't optional — it's the test that would embarrass the demo if skipped |
| Spring Batch has real setup overhead if you haven't used it recently | It's Day 3, item 1, first thing tackled with fresh time — don't leave it for the last hour |
| Repo looks abandoned after the interview | Same post-interview roadmap discipline as before (Section 15) |

---

## 14. README Requirements (public repo checklist)

- [ ] One-paragraph summary + architecture diagram
- [ ] Quickstart: `docker-compose up`
- [ ] Keycloak setup section, including how to get tokens for each of the 4 roles for manual testing
- [ ] How to run tests, how to run the k6 load test
- [ ] How the Spring Batch import works and where job-execution history is viewable
- [ ] Current status of observability/K8s (honest)
- [ ] Screenshot or short GIF of the approvals queue
- [ ] License (MIT) and CI badge

---

## 15. Post-Interview Roadmap

1. Deploy to a local `kind`/`minikube` cluster, update README status.
2. Finish observability (OpenTelemetry/Jaeger/Grafana) if Day 3 didn't get there.
3. Add tiered-rule edge case tests (boundary values are where rules engines actually break).
4. `CONTRIBUTING.md` + issue template.
5. Optional: a short write-up on the RBAC + approval-workflow design — reuses the work for visibility beyond this one interview.
