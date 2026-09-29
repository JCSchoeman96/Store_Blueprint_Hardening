# Repair Postgres and Check Gates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the repository’s configured Postgres test service and remove the dependency-audit and Mix ETS failures that prevent the required check gates from completing.

**Architecture:** First validate the host/container/configuration boundary and make the repository-configured Postgres and Redis instances reachable on `localhost:5433` and `localhost:6379`. Then isolate `mix deps.audit` from the `mix check` alias, identify vulnerable locked dependencies and compatibility constraints, and update only the dependency declarations/lock entries required for patched versions. The patched AshAuthentication release also requires its existing Google strategy to persist provider identities, so the related resource/action wiring and generated database migration are included to keep a clean warnings-as-errors and migration-alignment gate. The final verification runs the actual database-backed tests and full `mix check` without changing subscription-commerce behaviour.

**Tech Stack:** Elixir 1.19.5, OTP 28, Mix, Phoenix/Ash, Ecto/PostgreSQL 16, Docker Compose, `mix_audit`, GitHub Actions.

---

### Task 1: Reproduce and isolate the environment failures

**Files:**
- Inspect: `config/test.exs`, `docker-compose.yml`, `mix.exs`, `mix.lock`, `.github/workflows/ci.yml`

- [x] **Step 1: Confirm the repository state and required bead.**

Run `git status -sb`, `bd status`, and `bd show store_blueprint-7yf.17`. The working tree must start clean apart from this plan, and the repair bead must be claimed.

- [x] **Step 2: Trace the configured database boundary.**

Compare `config/test.exs` with `docker-compose.yml`, then run `ss -ltnp`, `docker ps -a`, and `docker inspect dev-postgres`. The expected diagnosis is a stopped `dev-postgres` container while tests target `localhost:5433`.

- [x] **Step 3: Reproduce each check failure independently.**

Run `mix deps.audit`, `mix compile --warnings-as-errors`, `mix test test/store/governance/state_machines_test.exs`, and `mix check` separately. Record whether the audit exits non-zero and whether the `Mix.State` ETS error occurs only after the audit task or also in an isolated Mix task.

### Task 2: Restore the configured Postgres and Redis services

**Files:**
- Inspect: `docker-compose.yml`, `config/test.exs`, `config/dev.exs`
- Modify only if the verified repository configuration and service mapping disagree.

- [x] **Step 1: Start the existing configured database and rate-limit containers.**

Run `docker start dev-postgres`, `docker start store-redis`, then `pg_isready -h localhost -p 5433 -U postgres` and `docker exec store-redis redis-cli ping`. Expected result: both containers are running, PostgreSQL accepts connections on the configured host port, and Redis returns `PONG` for the test profile’s default rate-limit backend.

- [x] **Step 2: Create and migrate the test database through the project tasks.**

Run `MIX_ENV=test mix ash_postgres.create` followed by `MIX_ENV=test mix ash_postgres.migrate`. Expected result: `store_test` is created and all repository migrations apply without changing migration files.

- [x] **Step 3: Prove a representative DB-backed test can start.**

Run `MIX_ENV=test mix test test/store/governance/state_machines_test.exs`. Expected result: the suite reaches test execution rather than failing during repository startup with `localhost:5433` connection refused.

### Task 3: Repair dependency-audit and Mix task execution

**Files:**
- Inspect/modify: `mix.exs`, `mix.lock`, `lib/store/accounts/user.ex`, `lib/store/accounts/domain.ex`, `lib/store/accounts/user_identity.ex`
- Generated: `priv/repo/migrations/20260827133218_phase_32_auth_identity_extensions_1.exs`, `priv/repo/migrations/20260827133219_phase_32_auth_identity.exs`, `priv/resource_snapshots/repo/user_identities/20260827133220.json`
- Inspect: `.github/workflows/ci.yml`, `.github/workflows/nightly-hardening.yml`

- [x] **Step 1: Map every advisory to the declaring dependency.**

Run `mix deps.audit`, `mix deps.tree`, and `mix hex.outdated`. For each advisory, identify the direct declaration in `mix.exs`, the locked version in `mix.lock`, the patched version, and whether the patched version satisfies the current dependency constraints. The audit exposed a real AshAuthentication compatibility requirement: the patched release warns/errors on the existing email-only OAuth configuration unless a durable provider-identity resource and `IdentityChange` are wired.

- [x] **Step 2: Form and test one dependency hypothesis at a time.**

Use the advisory’s first patched version as the hypothesis. Update the smallest direct constraint in `mix.exs`, run `mix deps.get`, rerun `mix deps.audit`, and compile. If a transitive dependency requires a coordinated update, record that dependency edge before changing the lockfile. Update the AshAuthentication boundary using its prescribed identity resource/action change and generated migration rather than suppressing its security warning.

- [x] **Step 3: Isolate the Mix ETS failure.**

Run `mix deps.audit` alone, `mix run -e 'IO.puts("mix-state-ok")'`, and the check alias with the audit task temporarily excluded only in a disposable command invocation. The fix must address the task/process boundary or compatible tool version identified by the reproduction; it must not hide advisories by adding an ignore rule.

- [x] **Step 4: Keep CI and local check semantics aligned.**

Compare the repaired local `mix check` sequence with `.github/workflows/ci.yml`, which runs `mix deps.audit` and `mix check` separately. Preserve the explicit CI audit and make the local alias complete without relying on a stale or corrupted Mix process state.

### Task 4: Full verification and handoff

**Files:**
- Verify: `mix.exs`, `mix.lock`, `config/test.exs`, `docker-compose.yml`, `.github/workflows/ci.yml`, `lib/store/accounts/user.ex`, `lib/store/accounts/user_identity.ex`, `priv/repo/migrations/20260827133219_phase_32_auth_identity.exs`

- [x] **Step 1: Run the full database-backed check sequence.**

Run `MIX_ENV=test mix ash_postgres.create`, `MIX_ENV=test mix ash_postgres.migrate`, `MIX_ENV=test mix test --max-failures 1`, `mix deps.audit`, and `mix check`. Expected result: the database connects, the audit reports no unaddressed advisories, the identity migration is applied, and `mix check` exits zero.

- [x] **Step 2: Run the repository’s static and focused gates.**

Run `mix format --check-formatted`, `mix compile --warnings-as-errors`, the focused lifecycle/concurrency/payment test set, and `mix check.types`. Expected result: each command reaches its normal gate and any remaining failure is unrelated to the repaired environment and explicitly recorded.

- [x] **Step 3: Verify scope and repository synchronization.**

Run `git diff --check`, `git diff --name-only`, `git diff -- lib/store priv/repo test`, `git pull --rebase`, `git push`, and `git status -sb`. Confirm that the only application changes are the security-compatible Google identity resource/action wiring and generated migration, alongside dependency/build-gate changes, and that the branch is clean against its remote.

- [x] **Step 4: Close the bead with evidence.**

Run `bd status`, close `store_blueprint-7yf.17` with GOAL / PLAN / DONE / NEXT / BLOCKERS / COMMANDS RUN / GATES, and synchronize the active Beads database using the repository’s configured Dolt mode.
