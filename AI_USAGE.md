# AI-Assisted Development Log

This project was built with [Claude Code](https://claude.com/claude-code) against the PRD in
`PRD-IncentivePay-Portfolio-App.md`. This is a running log of real prompts and decisions from that
build, kept honest rather than polished - including the parts where the first draft was wrong.

## Initial scope

**Prompt (paraphrased):** "Build an app from this PRD. Hold the Docker runs since I haven't installed it
yet, and ask if you need any required information."

**Decision:** Rather than asking clarification questions up front for a PRD this detailed and opinionated
(it already locks in the stack, the day-by-day plan, and the cut order), Claude Code made the reasonable
default calls itself - Maven over Gradle (the environment's Gradle 7.4.2 predates JDK 21 support), a single
multi-module repo, `com.incentivepay` as the group ID - and flagged them as it went rather than blocking on
each one. Docker-dependent steps (running `docker-compose up`, Testcontainers integration tests, the k6
load test) were written but not executed, per the instruction.

## Mid-build pivot: monorepo to 5 repos

**Prompt:** "push to git for each service and frontend, create their repo for every one of them. And put
comprehensive readme to setup and run it."

The original PRD assumed a single public repo (Section 0: "Decisions carried over... repo is public on
GitHub from day one"). This explicit instruction overrides that. Splitting a working multi-module Maven
reactor into standalone repos is a real, somewhat consequential restructuring - not a one-line change - so
rather than guessing at the shape (where do docker-compose/k8s/the PRD itself live? does each service's build
become fully independent, or does it lean on a published shared artifact?), Claude Code asked three targeted
questions before touching anything: repo layout (5th "platform" repo vs. folding infra into one service repo
vs. dropping shared infra entirely), how each Maven build should become standalone (duplicate the parent POM
config vs. publish a shared artifact to GitHub Packages), and naming/visibility. All three had a clearly
better default for a portfolio piece, which is exactly why they were offered as the recommended option in a
multiple-choice question rather than left fully open-ended.

**Fix, once confirmed:** each Java service's `pom.xml` was rewritten to inherit `spring-boot-starter-parent`
directly (simpler than expected - it turned out to already manage the compiler `-parameters` flag and a
modern Surefire version, both of which the original monorepo's parent POM had needed manual pinning for; see
"Maven defaults" below). Re-ran `mvn test` in each freshly-split repo before pushing anything, rather than
assuming the split hadn't broken something.

## Where a first draft was wrong

### 1. Keycloak's issuer claim breaks under Docker Compose networking

**What happened:** The first pass at `application.yml` used `spring.security.oauth2.resourceserver.jwt.issuer-uri`
pointed at `http://keycloak:8080/realms/incentivepay` (the address `incentive-api` can actually reach inside
the Docker network). That looked right until working through how a browser gets a token: Keycloak's
`KC_HOSTNAME=localhost` means tokens carry `iss=http://localhost:8081/realms/incentivepay` (the
host-reachable address), because that's what the browser talks to. Spring's `issuer-uri` config requires the
configured value and the token's `iss` claim to match *exactly* - so every token issued to the frontend would
have failed backend validation with an issuer mismatch, only visible once you'd actually try to log in through
docker-compose.

**How it was caught:** Reasoning through the actual request path end-to-end (browser → Keycloak → token →
backend) before wiring docker-compose, rather than after. No test caught this one - it's a networking/config
interaction that a unit test wouldn't touch, and there's no running Docker in this environment to catch it at
runtime either.

**Fix:** Switched both `incentive-api` and `ledger-service` to `jwk-set-uri` instead of `issuer-uri`. That
only requires a *reachable* key-fetch endpoint and doesn't enforce the `iss` claim, which decouples "how to
fetch the signing keys" (internal Docker DNS) from "what hostname issued this token" (the browser-facing one).
Documented in both `application.yml` files and the README so the next person doesn't hit the same wall.

### 2. `docker-compose.yml`'s frontend `environment:` block silently does nothing

**What happened:** The first `docker-compose.yml` set `VITE_API_BASE_URL` etc. under the frontend service's
`environment:` key, the same way every backend service gets its config. That's a no-op for a static Vite
build: `import.meta.env.VITE_*` values are inlined into the JS bundle at `npm run build` time, inside the
Docker build stage - by the time the container actually runs, setting environment variables on the running
nginx container changes nothing, because the bundle is already frozen.

**How it was caught:** Rereading the Dockerfile's build stage against the compose file's runtime config while
writing the README's docker-compose walkthrough - the mismatch (build-time var needs, runtime var supplied)
was only obvious once both files were read side by side.

**Fix:** Moved the `VITE_*` values to `build.args` in `docker-compose.yml`, and added matching `ARG`/`ENV`
pairs in `frontend/Dockerfile` before the `RUN npm run build` line, with a comment explaining why.

### 3. Redundant/wrong-grain unique constraints on JPA entities

**What happened:** `IncentiveEvent` and `LedgerEntry` were first written with both `@Column(unique = true)`
on the field *and* a `@Table(uniqueConstraints = @UniqueConstraint(columnNames = "externalEventId"))` -
using the **Java field name**, not the snake_case physical column name Hibernate's naming strategy actually
generates (`external_event_id`). Harmless under `ddl-auto: validate` (Hibernate's schema validator checks
column existence/type, not constraint definitions), but wrong and confusing, and would have mattered the
moment anyone switched to `ddl-auto: create` for a quick local check.

**How it was caught:** Writing the Flyway migration SQL by hand forced enumerating every column's real
physical name, which surfaced the mismatch immediately.

**Fix:** Removed the redundant `@Table`-level constraint entirely (the `@Column(unique = true)` already
covers it) and made the Flyway migration the single source of truth for schema, with `ddl-auto: validate`
just double-checking the entities agree with it.

### 4. Maven defaults quietly broke JUnit 5 discovery and `@PathVariable` binding

**What happened:** Not an AI-reasoning mistake so much as an environment trap the PRD doesn't call out but
that would've cost real time: without pinning `maven-compiler-plugin` and `maven-surefire-plugin` versions in
the parent POM, this Maven 3.8.5 install falls back to decade-old defaults - `maven-surefire-plugin:2.12.4`,
which doesn't discover JUnit 5 (Jupiter) tests at all (silently ran "0 tests", not a build failure), and a
compiler plugin invocation that dropped debug parameter names, which breaks Spring MVC's `@PathVariable`
resolution by name at runtime.

**How it was caught:** Running the test suite after writing the first batch of unit tests - `mvn test`
reported "Tests run: 0" instead of failing outright, which is exactly the kind of green-looking false
negative worth being suspicious of. The `@PathVariable` issue showed up as a very literal 400 error
(`"Ensure that the compiler uses the '-parameters' flag"`) in the RBAC slice test.

**Fix:** Pinned `maven-compiler-plugin:3.13.0` (with `<parameters>true</parameters>`) and
`maven-surefire-plugin:3.2.5` in `pluginManagement` in the root POM.

## What this says about reviewing AI output

None of the four issues above were caught by "the AI double-checking itself" in isolation - they were caught
by the same habits that catch a human's mistakes: running the tests, reading two files side by side instead
of trusting each one independently, and tracing a request through the whole system instead of just the file
being edited. The PRD's own instinct here (Section 10: log a "got this wrong" story, don't just log the
prompts that went well) is doing real work - it's the difference between a changelog and an actual account of
how the thing got built.
