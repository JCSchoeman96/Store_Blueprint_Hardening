# DevCore database settings implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Configure Store development and test Ecto connections to consume the workstation's project-scoped dev-core PostgreSQL settings.

**Architecture:** `.devcore/project.conf` owns the allocated database roles and names. Separate DevCore profiles render each environment's host, port, role, database, and password to ignored files. `config/dev.exs` and the ordinary workstation branch of `config/test.exs` consume those values, while test partition suffixes and the separate performance-smoke connection path remain intact.

**Tech Stack:** Elixir, Ecto SQL, PostgreSQL, `devcore-project` v1.0.0.

---

## Starting point

- Workstream: `platform/task-workstation-infra-contract`
- Worktree: `/home/jcschoeman96/projects/current/Store_Blueprint_Hardening-task-workstation-infra`
- Task candidate before this plan: `e7699dc00d518bc35a3e59851feeea2ee8ae4071`
- `origin/main` at plan start: `7eff026fb7cce7b29dc5d5916f9e3895039b858a`
- Do not edit Docker/Compose files or PR #128.

## File map

| File | Responsibility |
| --- | --- |
| `config/dev.exs` | Read dev profile connection values for both Ecto repos. |
| `config/test.exs` | Read test profile values outside performance smoke; keep the performance path separate and append the test suffix. |
| `.devcore/project.conf` | Declare project-owned roles, databases, secret keys, and test `CREATEDB`. |
| `.devcore/render-map.tsv` | Render distinct `dev` and `test` env files. |
| `.devcore/env.development.local.template` | Define dev profile variable names expected by the app. |
| `.devcore/env.test.local.template` | Define test profile variable names expected by the app. |
| `.devcore/README.md` | Explain activation and profile-run commands without exposing secrets. |
| `.env.example` | List safe workstation values for other local secret managers. |
| `README.md` | Replace the old database-secret wrapper instructions with DevCore commands. |
| `docs/deployment/env-vars.md` | Document the local connection variables and profile behavior. |
| `test/store/support/database_environment_test.exs` | Existing integration check for test endpoint, role, database, and suffix. Do not change unless the existing assertions conflict with the approved design. |

## Task 1: Add the DevCore project contract

**Files:** Create the five `.devcore/` files listed above.

- [x] **Step 1: Define the project allocations.** Create `.devcore/project.conf` with:

```text
PROJECT_KEY=store_blueprint
DEV_DB_ROLE=store_blueprint_dev
DEV_DB_NAME=store_blueprint_dev
TEST_DB_ROLE=store_blueprint_test
TEST_DB_NAME=store_blueprint_test
DEV_SECRET_KEY=STORE_BLUEPRINT_DEV_DB_PASSWORD
TEST_SECRET_KEY=STORE_BLUEPRINT_TEST_DB_PASSWORD
TEST_ROLE_CREATEDB=yes
USE_REDIS=yes
REDIS_PREFIX=store_blueprint_hardening
RENDER_MAP=.devcore/render-map.tsv
```

- [x] **Step 2: Add profile-specific templates.** Create `.devcore/env.development.local.template` with:

```text
STORE_DEV_DATABASE_USERNAME={{DEV_DB_ROLE}}
STORE_DEV_DATABASE_PASSWORD={{DEV_DB_PASSWORD}}
STORE_DEV_DATABASE_HOST={{DEV_DB_HOST}}
STORE_DEV_DATABASE_PORT={{DEV_DB_PORT}}
STORE_DEV_DATABASE_NAME={{DEV_DB_NAME}}
```

Create `.devcore/env.test.local.template` with:

```text
STORE_TEST_DATABASE_USERNAME={{TEST_DB_ROLE}}
STORE_TEST_DATABASE_PASSWORD={{TEST_DB_PASSWORD}}
STORE_TEST_DATABASE_HOST={{TEST_DB_HOST}}
STORE_TEST_DATABASE_PORT={{TEST_DB_PORT}}
STORE_TEST_DATABASE_NAME={{TEST_DB_NAME}}
```

- [x] **Step 3: Add the profile render map.** Use literal tab separators and these rows in `.devcore/render-map.tsv`:

```text
dev	.devcore/env.development.local.template	.env.development.local	DATABASE_URL,DB_HOST,DB_PORT,DB_PASSWORD,DB_NAME
test	.devcore/env.test.local.template	.env.test.local	DATABASE_URL,DB_HOST,DB_PORT,DB_PASSWORD,DB_NAME
```

- [x] **Step 4: Document the project contract.** In `.devcore/README.md`, state that `devcore-project plan` previews allocations, `devcore-project activate` provisions only the declared project roles/databases, and `devcore-project run dev|test -- ...` loads the corresponding ignored profile file. State that this repo does not start or stop the shared Docker services.

- [x] **Step 5: Check the contract.** Run `devcore-project plan` from the worktree root. Confirm it reports DEV `store_blueprint_dev` at `127.0.0.1:55432` and TEST `store_blueprint_test` at `127.0.0.1:55433`, with test `CREATEDB=yes`. It must not print secret values.

## Task 2: Read DevCore profile values in dev config

**Files:** Modify `config/dev.exs` only.

- [x] **Step 1: Add typed connection values.** Replace the repeated hard-coded database fields with this shared configuration list:

```elixir
dev_database_config = [
  username: System.get_env("STORE_DEV_DATABASE_USERNAME", "store_blueprint_dev"),
  password: System.get_env("STORE_DEV_DATABASE_PASSWORD"),
  hostname: System.get_env("STORE_DEV_DATABASE_HOST", "127.0.0.1"),
  port: System.get_env("STORE_DEV_DATABASE_PORT", "55432") |> String.to_integer(),
  database: System.get_env("STORE_DEV_DATABASE_NAME", "store_blueprint_dev")
]
```

Use `Keyword.fetch!/2` for those five keys in both `Store.Repo` and `Store.DirectRepo`. Preserve their current pool sizes and `stacktrace: true`. Keep both repos on the direct PostgreSQL DEV endpoint.

- [x] **Step 2: Format and inspect dev config.** Run `mix format --check-formatted config/dev.exs` and inspect the resulting config to confirm both repos use the same profile values.

## Task 3: Read test profile values without changing CI or smoke routing

**Files:** Modify `config/test.exs` only.

- [x] **Step 1: Change the non-performance connection settings.** Keep the existing performance-smoke branch unchanged. In the ordinary branch, use:

```elixir
[
  username: System.get_env("STORE_TEST_DATABASE_USERNAME", "store_blueprint_test"),
  password: System.get_env("STORE_TEST_DATABASE_PASSWORD"),
  hostname: System.get_env("STORE_TEST_DATABASE_HOST", "127.0.0.1"),
  port:
    System.get_env("STORE_TEST_DATABASE_PORT", System.get_env("STORE_DB_PORT", "55433"))
    |> String.to_integer()
]
```

The `STORE_DB_PORT` fallback preserves the existing CI service mapping. Keep performance-smoke host, port, username, password, Redis, and database safety handling on their current `STORE_PERF_*` path, including `Store.Config.PerformanceDatabaseSafety.validate!/5` and its required `STORE_PERF_DATABASE_NAME` input.

- [x] **Step 2: Build the test database name from the profile base.** Replace the hard-coded base name with:

```elixir
test_database_name =
  "#{System.get_env("STORE_TEST_DATABASE_NAME", "store_blueprint_test")}#{test_db_suffix}"
```

Use `test_database_name` for both `Store.Repo` and `Store.DirectRepo`. In performance-smoke mode, set it to the already-validated `performance_database_name`; otherwise use the DevCore base name plus the suffix. Keep `test_db_suffix` sourced from `STORE_TEST_DB_SUFFIX` and then `MIX_TEST_PARTITION`. The performance-smoke host, port, credentials, Redis, and database safety selection remain on the existing `STORE_PERF_*` path.

- [x] **Step 3: Run the existing database environment test.** After DevCore has rendered the TEST profile, run:

```bash
STORE_TEST_DB_SUFFIX=devcore_config \
devcore-project run test -- mix test test/store/support/database_environment_test.exs
```

Expected result: the test passes against `store_blueprint_testdevcore_config` on `127.0.0.1:55433` as `store_blueprint_test`. The test role creates the suffixed database because the project contract grants it `CREATEDB`.

## Task 4: Update local setup documentation

**Files:** Modify `.env.example`, `README.md`, and `docs/deployment/env-vars.md`.

- [x] **Step 1: Keep the env example secret-free.** List the DevCore-provided variable names and safe defaults for usernames, hosts, ports, and database names. Leave both password values empty. Do not add secret values or `DATABASE_URL`.

- [x] **Step 2: Replace the old wrapper commands.** Document these workstation commands:

```bash
devcore-project plan
devcore-project activate
devcore-project run dev -- mix setup
devcore-project run dev -- mix phx.server
devcore-project run test -- mix test
```

Keep the existing note that Dockge owns service lifecycle. Do not edit Docker/Compose files.

- [x] **Step 3: Check documentation and ignore rules.** Confirm `.env.development.local` and `.env.test.local` match the existing `.env.*` ignore rule, and no secret values appear in tracked files.

## Task 5: Provision and validate the settings

**Files:** No additional source files.

- [x] **Step 1: Review the DevCore plan output.** Run `devcore-project plan`. If the expected project allocation is absent, run `devcore-project activate` to create/update only this project's DEV/TEST roles, databases, central password entries, and ignored profile files. Do not start or stop Docker services. If the tool reports an ownership conflict, stop without changing it.

- [x] **Step 2: Check the service contract.** Run `devcore-project doctor`. Confirm both PostgreSQL profiles authenticate and the project Redis check uses only the configured `store_blueprint_hardening` namespace.

- [x] **Step 3: Run the repository quality gate.** Run `STORE_TEST_DB_SUFFIX=devcore_config devcore-project run test -- mix check`. Expected result: the required format/static/property/test checks pass with zero failures.

- [x] **Step 4: Check patch boundaries.** Run `git diff --check` and inspect both the task-owned file changes and the integration diff. The task changes are limited to `config/dev.exs`, `config/test.exs`, `.devcore/`, `.env.example`, `README.md`, `docs/deployment/env-vars.md`, and the spec/plan/registry artifacts. Preserve Docker/Compose files from the task candidate and do not change PR #128 files.

- [x] **Step 5: Prepare the Platform task review.** Inspect the complete branch-to-target diff. The original task branch contains inherited Docker/Compose changes, so the review candidate uses a separate integration branch from current `origin/main` and applies only the owned DevCore settings and supporting documentation. The candidate contains no Docker/Compose, production, schema, or migration changes.

## Validation record

- DevCore `plan`, `activate`, and `doctor`: PASS. DEV/TEST PostgreSQL and scoped Redis endpoints authenticate.
- DEV Ecto `Store.Repo` and `Store.DirectRepo` `SELECT 1`: PASS.
- DEV setup migrations: 51 applied; latest recorded version `20260902203800`.
- `mix setup` completed dependency and database setup, then exited 1 in `mix tailwind store`: the existing `assets/css/app.css` `@plugin "../vendor/daisyui"` block rejects its options. No frontend files were changed.
- During DEV application startup, the existing telemetry poller also issued a query for `subscriptions.next_renew_at`; the current schema uses `next_renewal_at`. This current-main application defect is outside the database-settings task and remains unchanged.
- Focused test: `STORE_TEST_DB_SUFFIX=devcore_config devcore-project run test -- mix test test/store/support/database_environment_test.exs`; 8 tests, 0 failures.
- `STORE_TEST_DB_SUFFIX=devcore_config devcore-project run test -- mix check`: PASS, 3 properties, 605 tests, 0 failures.
- `git diff --check`: PASS.
- Clean integration worktree: `devcore-project doctor` PASS for both PostgreSQL databases and scoped Redis endpoints; focused database environment test PASS, 8 tests, 0 failures; full `mix check` PASS, 3 properties, 605 tests, 0 failures.
- Clean review diff from `origin/main` contains 13 files, limited to `.devcore/**`, `.env.example`, `README.md`, `config/dev.exs`, `config/test.exs`, `docs/agent_rules/active_workstreams.md`, `docs/deployment/env-vars.md`, and the DevCore spec/plan. Read-only independent review passed on candidate `a6ba0f1`; exact-head GitHub CI remains pending.
- DevCore rotated the local project DEV and TEST credentials after a diagnostic trace exposed a resolved credential; values were not printed during rotation, and `doctor` plus focused tests passed afterward.
- Main integration: task candidate `ccd4c04276ef027117c39b1a03dd8d70ffa5fe87` plus `origin/main` `7eff026fb7cce7b29dc5d5916f9e3895039b858a`; merge commit `5795ad00c7e56690b9a1b64ea8150de445c02bd6`; merge correction `bf46abdcbc6e1f2a5de549b8e03d73cef489fb81`. Docker/Compose files are unchanged from the task candidate.
