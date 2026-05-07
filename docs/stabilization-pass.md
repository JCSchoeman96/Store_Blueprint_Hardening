# Recommended execution model

Do **not** start with the README. That sounds logical, but it creates merge conflicts and forces the README writer to guess before the source docs exist.

Best flow:

```text id="66q8am"
Phase 0: Coordination / branch ownership
Phase 1: Source-of-truth extraction
Phase 2A–2D: Parallel workstreams
Phase 3A–3C: Targeted fixes after audits
Phase 4: README integration
Phase 5: Final verification and merge cleanup
Phase 6: Future facade refactor planning / not implementation
```

The README is currently Phoenix boilerplate, so it should become the final integration layer, not the first task. 

---

# Dependency graph

```text id="3v0o1v"
Phase 0
  ↓
Phase 1
  ↓
 ┌───────────────────────────────┬───────────────────────────────┬───────────────────────────────┬───────────────────────────────┐
 ↓                               ↓                               ↓                               ↓
Phase 2A                         Phase 2B                         Phase 2C                         Phase 2D
Architecture docs                Deployment/runtime               Payment readiness                Admin security audit
  ↓                               ↓                               ↓                               ↓
Phase 3C                         Phase 3A + 3B                    Phase 3 optional                 Phase 3D if needed
Facade split plan                Docker/version fixes             Provider guard docs              Admin gate implementation
  └───────────────┬───────────────┴───────────────┬───────────────┴───────────────┬───────────────┘
                  ↓                               ↓                               ↓
                         Phase 4: README integration
                                  ↓
                         Phase 5: Final verification
                                  ↓
                         Phase 6: Future refactor tickets
```

---

# Phase 0 — Coordination and file ownership

## Goal

Prevent agents from touching the same files and creating conflicts.

## Run mode

**Serial. One lead agent.**

## Files touched

Preferably none, unless creating a tracking issue/bead.

## Output

Branch/workstream ownership plan.

## Blockers

None.

## Success

Each agent knows exactly which files it may edit.

### TOON prompt

| Field     | Content                                                                                                                                                                                                                                                               |
| --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Create a workstream ownership plan for the Store Blueprint stabilization pass.                                                                                                                                                                                        |
| Objective | Prevent merge conflicts between parallel coding agents by assigning file ownership and merge order before implementation begins.                                                                                                                                      |
| Output    | A short coordination note listing branches, owned files, blocked files, merge order, and required gates.                                                                                                                                                              |
| Note      | Do not modify application code. Use `main` as target branch. Respect `AGENTS.md`, especially Ash 3.x, single-tenant design, no `tenant_id`, web adapter-only rules, integer minor-unit money, and UUIDv7 rules. Performance review: no runtime changes in this phase. |

### Phase 0 coordination note (completed)

**Canonical coordination branch:** `coord/phase-0-ownership-plan`  
**Target branch for integration:** `main`

#### Workstream ownership map

| Workstream | Branch | Owned files | Blocked files |
| --- | --- | --- | --- |
| WS0 Coordination (lead) | `coord/phase-0-ownership-plan` | `docs/agent_notes/**`, `docs/phases/**`, coordination docs only | `lib/**`, `config/**`, `priv/**`, `assets/**`, `test/**` |
| WS1 Domain Core | `stabilize/ws1-domain-core` | `lib/store/**` | `lib/store_web/**`, `assets/**` |
| WS2 Web Adapter Boundary | `stabilize/ws2-web-adapter` | `lib/store_web/**` | `lib/store/**` (except agreed facade call-site handoff) |
| WS3 Data/Infra/Runtime | `stabilize/ws3-data-infra` | `priv/**`, `config/**`, `mix.exs`, `mix.lock`, `docker-compose.yml`, `Dockerfile`, `rel/**` | `lib/store_web/**` (unless coordinated) |
| WS4 Verification/Gates | `stabilize/ws4-tests-gates` | `test/**`, optional check tasks under `lib/mix/tasks/**` | Runtime feature code outside tests unless transferred by owner |

#### Merge order (to reduce conflicts)

1. `stabilize/ws1-domain-core`
2. `stabilize/ws3-data-infra`
3. `stabilize/ws2-web-adapter`
4. `stabilize/ws4-tests-gates`
5. `coord/phase-0-ownership-plan` follow-up doc updates

#### Required gates for every workstream

- Respect `AGENTS.md` invariants: Ash 3.x, single-tenant, no `tenant_id`, adapter-only web boundary, integer minor-unit money, UUIDv7 laws.
- No `Ash.Query` in `lib/store_web/**`; no direct `Ash.*`/`Repo.*` calls in web.
- Controllers/LiveViews/Workers call domain facades only (`Store.<Domain>.*`).
- No runtime performance behavior changes in Phase 0; this phase is coordination-only.
- Rebase on `origin/main` before merge; no cross-workstream file edits without explicit ownership transfer.

---

# Phase 1 — Source-of-truth extraction

## Goal

Create a short internal fact base that all parallel agents use.

This prevents one agent saying “PayFast ready” while another says “PayFast scaffold only.”

## Run mode

**Serial. One lead agent. Short phase.**

## Files touched

```text id="ayx0v1"
docs/stabilization/source-of-truth.md
```

## Inputs to inspect

```text id="k94fbn"
AGENTS.md
README.md
mix.exs
.tool-versions
Dockerfile
config/runtime.exs
config/config.exs
lib/store_web/router.ex
lib/store_web/live_user_auth.ex
docs/agent_notes/subscription_payments_evaluation.md
```

The `AGENTS.md` file is the strongest rule source and explicitly defines the stack, single-tenant constraint, Ash 3.x, web boundary rules, payment/webhook rules, and performance review expectations. 

## Blockers

None.

## Success

A single source doc exists that later agents can cite.

### TOON prompt

| Field     | Content                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Create `docs/stabilization/source-of-truth.md` summarizing the current repo facts needed for stabilization.                                                                                                                                                                                                                                                                                                                                                     |
| Objective | Give all parallel agents a shared factual baseline so docs, deployment fixes, payment readiness, and security audit do not contradict each other.                                                                                                                                                                                                                                                                                                               |
| Output    | New `docs/stabilization/source-of-truth.md` with sections for stack, domains, runtime env contract, Docker/release model, admin route protection evidence, payment provider status, CI gates, and known risks.                                                                                                                                                                                                                                                  |
| Note      | Read actual repo files; do not guess. State that README is currently boilerplate. State that admin routes currently show `live_user_required` at router level and require deeper proof. State that Stripe is implemented while other providers are scaffold-only unless code proves otherwise. Performance review: include hot/warm/cold architecture assumptions, Redis/ETS/Cachex usage, Oban queues, PgBouncer transaction mode, and telemetry expectations. |

### Phase 1 source-of-truth note (completed)

- Canonical baseline file created: `docs/stabilization/source-of-truth.md`
- This file is now the shared factual reference for all parallel streams (2A-2D and follow-on phases).
- Agents should cite this baseline when asserting stack/runtime/payment/admin-auth facts.

---

# Phase 2A — Architecture documentation workstream

## Goal

Document domain boundaries and future facade split plan.

## Run mode

**Parallel after Phase 1.**

## Safe to run with

```text id="d4dpt0"
Phase 2B
Phase 2C
Phase 2D
```

## Must not edit

```text id="m6ecb3"
README.md
Dockerfile
mix.exs
config/**
lib/**
test/**
```

## Files owned

```text id="smtjxp"
docs/architecture/domain-map.md
docs/architecture/facade-split-plan.md
```

## Blockers

Requires Phase 1 source-of-truth doc.

## Success

Architecture docs exist and do not change behavior.

### Phase 2A progress update (2026-05-07)

- Completed architecture/governance contradiction audit against `AGENTS.md` and `docs/stabilization/source-of-truth.md`.
- Clarified in `docs/governance/payment_provider_capabilities.md` that capability matrices are contract envelopes, not implementation-readiness claims; Stripe remains the only implementation-ready provider absent new code evidence.
- Corrected runtime env var naming drift in `docs/phases/phase_28_production_readiness_release_checklist.md` to canonical `STORE_*` contract values from `runtime.exs` baseline.
- Corrected internal consistency wording in `docs/stabilization/source-of-truth.md` admin auth risk language to reflect existing Phase 2D role-gate evidence while keeping further per-surface audit work explicit.

### TOON prompt 2A.1

| Field     | Content                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Create `docs/architecture/domain-map.md` documenting the Store Blueprint domain model.                                                                                                                                                                                                                                                                                                                                                                                           |
| Objective | Give future agents a reliable map of Ash domains, responsibilities, external systems, stateful boundaries, and allowed call paths.                                                                                                                                                                                                                                                                                                                                               |
| Output    | New `docs/architecture/domain-map.md`.                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| Note      | Use the configured Ash domains from `config/config.exs`. Cover Accounts, Admin, Catalog, Carts, Checkout, Orders, Payments, Pricing, Shipping, Fulfillment, Digital, Entitlements, Subscriptions, Comms, Tools, and support/operations modules. Do not add tenant/marketplace concepts. Performance review: classify each domain hot/warm/cold; identify Redis/ETS/Cachex candidates, DB index sensitivity, Oban involvement, PubSub/telemetry usage, and peak-path query risks. |

### TOON prompt 2A.2

| Field     | Content                                                                                                                                                                                                                                                                                                                                                                                      |
| --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Create `docs/architecture/facade-split-plan.md` for oversized domain facade refactoring.                                                                                                                                                                                                                                                                                                     |
| Objective | Prepare safe future refactoring of large facades without changing behavior now.                                                                                                                                                                                                                                                                                                              |
| Output    | New `docs/architecture/facade-split-plan.md` covering `Store.Checkout`, `Store.Orders`, and `Store.Payments`.                                                                                                                                                                                                                                                                                |
| Note      | Planning only. Do not move code. Propose modules such as `Store.Checkout.StartFromCart`, `Store.Checkout.FinalizeTotals`, `Store.Checkout.ShippingSelection`, `Store.Orders.InventorySweep`, and `Store.Payments.ProviderSetup`. Preserve public facade APIs. Performance review: preserve transaction boundaries, lock ordering, idempotency, telemetry, Oban uniqueness, and query counts. |

---

# Phase 2B — Deployment/runtime workstream

## Goal

Create deployment docs, env contract, `.env.example`, and prepare Docker/version fixes.

## Run mode

**Parallel after Phase 1.**

## Safe to run with

```text id="5t96x6"
Phase 2A
Phase 2C, only if Phase 2C does not edit env docs
Phase 2D
```

## Must not edit

```text id="zef65l"
README.md
docs/payments/provider-readiness.md unless coordinating with Phase 2C
lib/store_web/**
test/**
```

## Files owned

```text id="fx0ssx"
docs/deployment/env-vars.md
docs/deployment/docker-release.md
.env.example
Dockerfile
mix.exs
```

## Blockers

Requires Phase 1 source-of-truth doc.

## Success

Deployment becomes repeatable and Docker/version risks are fixed or documented.

### Phase 2B progress update (2026-05-07)

- Added runtime env contract documentation in `docs/deployment/env-vars.md`, sourced directly from `config/runtime.exs` and release/runtime artifacts.
- Added Docker/release operations guide in `docs/deployment/docker-release.md` with release commands, health checks, and PgBouncer transaction-mode notes.
- Aligned Docker build ordering in `Dockerfile` to compile before assets deploy (`mix compile` then `mix assets.deploy`).
- Deferred `.env.example` and `mix.exs` updates in this pass to stay within current 2B lane ownership constraints provided in the stabilization assignment.

### TOON prompt 2B.1

| Field     | Content                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Create `docs/deployment/env-vars.md` documenting the runtime environment variable contract.                                                                                                                                                                                                                                                                                                                                                                      |
| Objective | Prevent production boot failures caused by undocumented runtime config requirements.                                                                                                                                                                                                                                                                                                                                                                             |
| Output    | New `docs/deployment/env-vars.md`.                                                                                                                                                                                                                                                                                                                                                                                                                               |
| Note      | Source from `config/runtime.exs`. Separate required, optional, and conditionally required variables. Include Phoenix, DB, PgBouncer, Redis, OAuth, Sentry, CSP, payments, shipping, digital storage, comms, rate limiting, and operations. Do not include real secrets. Performance review: document `STORE_DB_POOL_MODE=transaction`, `POOL_SIZE`, Redis key prefix, Redis backend, payment HTTP pool/timeouts, Oban/DirectRepo split, and rate-limit settings. |

### TOON prompt 2B.2

| Field     | Content                                                                                                                                                                                                                                                       |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Create `.env.example` with safe placeholder values for production-like local boot.                                                                                                                                                                            |
| Objective | Give developers and deployment scripts a concrete env template.                                                                                                                                                                                               |
| Output    | New `.env.example`.                                                                                                                                                                                                                                           |
| Note      | Use placeholders only. Include minimal defaults and commented provider-specific sections. Do not leak secrets. Performance review: include PgBouncer mode, pool size, Redis connection variables, rate limit backend, payment timeout defaults, and CSP mode. |

### TOON prompt 2B.3

| Field     | Content                                                                                                                                                                                                                                                                                                                             |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Create `docs/deployment/docker-release.md` documenting Docker build, release boot, migrations, preflight, and health checks.                                                                                                                                                                                                        |
| Objective | Make production release operation repeatable.                                                                                                                                                                                                                                                                                       |
| Output    | New `docs/deployment/docker-release.md`.                                                                                                                                                                                                                                                                                            |
| Note      | Include build command, env file usage, release migration command, `Store.Release.preflight`, health endpoints, Nginx/Cloudflare notes, and common failures. Performance review: document DB via PgBouncer, DirectRepo for Oban/migrations, Redis requirement, Oban queues, no peak-path large DB scans, and telemetry expectations. |

### TOON prompt 2B.4

| Field     | Content                                                                                                                                                                                                                                                                  |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Task      | Audit and fix Dockerfile compile/assets/release ordering if needed.                                                                                                                                                                                                      |
| Objective | Prevent release build failures caused by assets being built before generated LiveView colocated assets are available.                                                                                                                                                    |
| Output    | Updated `Dockerfile` and corresponding note in `docs/deployment/docker-release.md`.                                                                                                                                                                                      |
| Note      | Prefer `mix compile` before `mix assets.deploy` unless the current order is proven safe. Keep Docker layers cache-friendly. Do not change runtime behavior. Performance review: no runtime data path changes; preserve small final image and reproducible release build. |

### TOON prompt 2B.5

| Field     | Content                                                                                                                                                                                                                                             |
| --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Align `mix.exs` Elixir requirement with `.tool-versions`.                                                                                                                                                                                           |
| Objective | Remove ambiguity between the declared Elixir compatibility and the pinned operational toolchain.                                                                                                                                                    |
| Output    | Updated `mix.exs` or documented reason for preserving a broad version range.                                                                                                                                                                        |
| Note      | `.tool-versions` pins Elixir/OTP; `mix.exs` should not misleadingly allow unsupported versions. Do not update dependency versions in this task. Performance review: no runtime path changes; version alignment improves CI/release reproducibility. |

---

# Phase 2C — Payment provider readiness workstream

## Goal

Document payment truth clearly.

## Run mode

**Parallel after Phase 1.**

## Safe to run with

```text id="7zaxlu"
Phase 2A
Phase 2D
Phase 2B only if env docs ownership is coordinated
```

## Must not edit

```text id="9qmrw5"
README.md
Dockerfile
mix.exs
lib/**
test/**
```

## Files owned

```text id="tsvtec"
docs/payments/provider-readiness.md
```

Optional file after Phase 2B or by coordination:

```text id="de6fgi"
docs/deployment/env-vars.md
```

## Blockers

Requires Phase 1 source-of-truth doc.

## Success

Payment status is impossible to misunderstand.

## Phase 2C progress update (2026-05-07)

- Completed: added `docs/payments/provider-readiness.md` as the Phase 2C canonical provider matrix.
- Completed: reconciled payment readiness wording in `docs/agent_notes/subscription_payments_evaluation.md` and `docs/stabilization/source-of-truth.md`.
- Enforced truth: Stripe is implementation-complete; PayFast/Paystack/Yoco/Peach remain scaffold-only until direct adapter + webhook proof exists.
- Boundary reaffirmed: webhook controllers stay ingress-only and must not perform domain state transitions.
- Handoff pending: Phase 2B should reference this matrix when documenting `STORE_PAYMENTS_ENABLED_PROVIDERS` safety guidance.

### TOON prompt 2C.1

| Field     | Content                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Task      | Create `docs/payments/provider-readiness.md` with a payment provider capability matrix.                                                                                                                                                                                                                                                                                                                                                                |
| Objective | Prevent accidental production enablement of scaffolded payment providers.                                                                                                                                                                                                                                                                                                                                                                              |
| Output    | New `docs/payments/provider-readiness.md`.                                                                                                                                                                                                                                                                                                                                                                                                             |
| Note      | Use existing code and `docs/agent_notes/subscription_payments_evaluation.md`. Mark Stripe as implemented only where code proves it. Mark PayFast, Paystack, Yoco, and Peach as scaffold-only unless implementation proves otherwise. Performance review: include webhook verification, canonical normalization, idempotent receipt persistence, Oban worker processing, provider HTTP timeout settings, retry/backoff expectations, and rate limiting. |

### TOON prompt 2C.2

| Field     | Content                                                                                                                                                                                                                |
| --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Add provider enablement warnings to deployment documentation after `docs/deployment/env-vars.md` exists.                                                                                                               |
| Objective | Make `STORE_PAYMENTS_ENABLED_PROVIDERS` safe to use operationally.                                                                                                                                                     |
| Output    | Updated `docs/deployment/env-vars.md` payment section, or a short follow-up note if Phase 2B is not merged yet.                                                                                                        |
| Note      | Do not modify runtime config in this task. Document that incomplete providers must remain disabled. Performance review: provider enablement must not introduce boot-time outbound network checks or slow startup work. |

---

# Phase 2D — Admin authorization audit workstream

## Goal

Prove whether admin routes are admin-only or just login-only.

## Run mode

**Parallel after Phase 1.**

## Safe to run with

```text id="f9hw4y"
Phase 2A
Phase 2B
Phase 2C
```

## Must not edit initially

```text id="0hr7lm"
README.md
Dockerfile
mix.exs
docs/deployment/**
docs/payments/**
```

## Files owned

```text id="9m6ws1"
docs/security/admin-authorization-audit.md
test/store_web/**
```

Only after audit proves a gap:

```text id="gxdpcv"
lib/store_web/live_user_auth.ex
lib/store_web/router.ex
possibly account/admin policy files
```

## Blockers

Requires Phase 1 source-of-truth doc.

## Success

There is written proof and tests for anonymous, logged-in non-admin, and admin access.

### TOON prompt 2D.1

| Field     | Content                                                                                                                                                                                                                                                                                                                                                                     |
| --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Audit current `/admin/**` authorization and create `docs/security/admin-authorization-audit.md`.                                                                                                                                                                                                                                                                            |
| Objective | Determine whether admin routes require an admin role/permission or merely any authenticated user.                                                                                                                                                                                                                                                                           |
| Output    | New `docs/security/admin-authorization-audit.md` with evidence from router, LiveUserAuth, LiveViews, Ash policies, and tests.                                                                                                                                                                                                                                               |
| Note      | Current router-level evidence shows admin routes use `live_user_required`; `LiveUserAuth.live_user_required` only checks for `current_user`. Do not conclude vulnerability until deeper LiveView/domain policy checks are inspected. Performance review: recommended admin checks must avoid repeated DB lookups per render and must not create N+1 authorization behavior. |

### TOON prompt 2D.2

| Field     | Content                                                                                                                                                                                                                                                    |
| --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Add admin access tests for anonymous, authenticated non-admin, and admin users.                                                                                                                                                                            |
| Objective | Convert admin route protection from assumption into enforceable test coverage.                                                                                                                                                                             |
| Output    | New or updated tests under `test/store_web/**`.                                                                                                                                                                                                            |
| Note      | Use existing fixtures/factories. If no admin role model exists, document the gap and create a blocker instead of inventing a sloppy role field. Performance review: tests should validate authorization without adding slow setup or unnecessary DB churn. |

### Phase 2D progress update (2026-05-07)

- Evidence chain completed across router, `LiveUserAuth`, admin LiveViews, subscriptions facade/policies, and existing LiveView tests.
- Concrete gap confirmed: subscriptions admin LiveViews lacked explicit mount-level role gating, relying on downstream policy denial.
- Minimal fix applied: role gate added to `StoreWeb.Admin.Subscriptions.IndexLive` and `StoreWeb.Admin.Subscriptions.ShowLive` (allow roles: `:super_admin`, `:admin`, `:support`).
- Targeted regression coverage added for authenticated non-admin redirect on `/admin/subscriptions` and `/admin/subscriptions/:id`.
- Audit report created at `docs/security/admin-authorization-audit.md`.

---

# Phase 3A — Docker/version fixes merge

## Goal

Merge deployment code/config changes from Phase 2B.

## Run mode

**Serial or same agent as Phase 2B.**

## Blockers

Requires Phase 2B.

## Files touched

```text id="mob458"
Dockerfile
mix.exs
docs/deployment/docker-release.md
```

## Success

Docker build order and Elixir version contract are no longer ambiguous.

### TOON prompt

| Field     | Content                                                                                                                                                                                                                                                       |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Finalize and verify Dockerfile and Elixir version contract changes.                                                                                                                                                                                           |
| Objective | Ensure build and runtime versions are deterministic before README integration.                                                                                                                                                                                |
| Output    | Finalized `Dockerfile`, `mix.exs`, and deployment doc updates.                                                                                                                                                                                                |
| Note      | Do not change dependencies. Do not change application behavior. Run `mix format` and `mix check` if code/config changed. Performance review: preserve release image size, build cache behavior, PgBouncer compatibility, and production runtime env contract. |

---

# Phase 3B — Deployment docs polish

## Goal

Make deployment docs internally consistent after payment docs and Docker fixes.

## Run mode

**Serial after Phase 2B and Phase 2C.**

## Blockers

```text id="d4bz63"
Phase 2B
Phase 2C
```

## Files touched

```text id="6qza3o"
docs/deployment/env-vars.md
docs/deployment/docker-release.md
.env.example
```

## Success

Env docs, `.env.example`, Docker docs, and provider readiness all agree.

### Phase 3B progress update (2026-05-07)

- Completed contradiction audit between deployment/operations docs and runtime/release evidence (`config/runtime.exs`, `rel/env.sh.eex`, `Dockerfile`, `railway.toml`, `pgbouncer/pgbouncer.ini`, `lib/store/operations/health.ex`).
- Corrected `docs/deployment/docker-release.md` to remove `PHX_HOST` from minimum required env vars and classify it as defaulted.
- Corrected `docs/operations/production_runbook.md` to classify env vars as required/optional/conditional, including Stripe-provider and clustering-only requirements.
- Clarified Railway DNS fallback nuance: runtime supports both Railway domain env vars; release env script auto-exports only from `RAILWAY_PRIVATE_DOMAIN`.

### TOON prompt

| Field     | Content                                                                                                                                                                                         |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Reconcile deployment docs with payment provider readiness and Docker/version changes.                                                                                                           |
| Objective | Ensure `.env.example`, env-var docs, and Docker release docs do not contradict each other.                                                                                                      |
| Output    | Updated `docs/deployment/env-vars.md`, `docs/deployment/docker-release.md`, and `.env.example` if needed.                                                                                       |
| Note      | Keep provider readiness accurate. Do not mark scaffold providers production-ready. Performance review: confirm docs cover DB pool mode, Redis, Oban, provider HTTP timeouts, and rate limiting. |

---

# Phase 3C — Architecture/facade planning merge

## Goal

Finalize architecture docs.

## Run mode

**Serial or same agent as Phase 2A.**

## Blockers

Requires Phase 2A.

## Files touched

```text id="r9k4h4"
docs/architecture/domain-map.md
docs/architecture/facade-split-plan.md
```

## Success

Future facade splitting has boundaries and acceptance criteria, but no implementation yet.

### TOON prompt

| Field     | Content                                                                                                                                                                            |
| --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Finalize architecture docs and facade split acceptance criteria.                                                                                                                   |
| Objective | Make future refactoring safe without doing the refactor now.                                                                                                                       |
| Output    | Finalized `docs/architecture/domain-map.md` and `docs/architecture/facade-split-plan.md`.                                                                                          |
| Note      | No code movement. Keep public facade APIs stable in the plan. Performance review: document transaction/lock/telemetry/query-count preservation as mandatory future refactor gates. |

---

# Phase 3D — Admin gate implementation, conditional

## Goal

Fix admin authorization only if audit proves a real gap.

## Run mode

**Serial after Phase 2D. Do not run speculatively.**

## Blockers

```text id="6c8mk6"
Phase 2D audit completed
Phase 2D tests prove missing or weak authorization
```

## Files possibly touched

```text id="84fezc"
lib/store_web/live_user_auth.ex
lib/store_web/router.ex
lib/store/accounts/**
lib/store/admin/**
test/store_web/**
docs/security/admin-authorization-audit.md
```

## Success

Non-admin authenticated users cannot access `/admin/**`; admin users can.

### TOON prompt

| Field     | Content                                                                                                                                                                                                                                                                                                                                                                  |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Task      | Implement a dedicated admin authorization gate if the audit proves admin routes are login-only.                                                                                                                                                                                                                                                                          |
| Objective | Ensure `/admin/**` is protected by admin permission/role, not merely authentication.                                                                                                                                                                                                                                                                                     |
| Output    | Updated auth/router/policy files and passing admin access tests.                                                                                                                                                                                                                                                                                                         |
| Note      | Only implement if tests/audit prove a gap. Prefer a clear `:live_admin_required` mount or equivalent policy-backed check. Do not hard-code emails. Do not add tenant logic. Keep web adapter-only. Performance review: avoid repeated DB role lookups per render; cache in assigns/session where safe; preserve audit logging/telemetry if existing patterns support it. |

---

# Phase 4 — README integration

## Goal

Create the final front door after all source docs exist.

## Run mode

**Serial. One agent only.**

## Blockers

```text id="8du6jw"
Phase 2A complete
Phase 2B complete
Phase 2C complete
Phase 2D complete
Phase 3A complete
Phase 3B complete
Phase 3C complete
Phase 3D complete only if needed
```

## Files touched

```text id="16i12m"
README.md
```

## Must not edit

```text id="uxhhph"
Dockerfile
mix.exs
lib/**
test/**
```

## Success

The README links to all deeper docs and accurately summarizes current status.

### TOON prompt

| Field     | Content                                                                                                                                                                                                                                                                                                               |
| --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Replace `README.md` with the final Store Blueprint project front door.                                                                                                                                                                                                                                                |
| Objective | Make the repo understandable and navigable after stabilization docs and audits are complete.                                                                                                                                                                                                                          |
| Output    | Updated `README.md` with overview, stack, current capabilities, non-goals, local setup, deployment links, architecture links, payment readiness summary, admin security status, quality gates, and coding-agent rules summary.                                                                                        |
| Note      | This must be an integration pass, not a new source of truth. Link to docs instead of duplicating everything. Be blunt about scaffold-only providers and partial subscription capabilities. Performance review: README must mention hot paths, Redis/ETS/Cachex, Oban, PgBouncer, telemetry, and `mix check`/CI gates. |

---

# Phase 5 — Final verification and merge cleanup

## Goal

Ensure all branches agree and quality gates pass.

## Run mode

**Serial. One lead agent.**

## Blockers

All previous phases merged or intentionally skipped.

## Files touched

Only small doc fixes if needed.

## Required commands

```bash id="lp0yb2"
mix format --check-formatted
mix compile --warnings-as-errors
mix check
mix test
mix check.types
```

If Docker is available:

```bash id="mgktnd"
docker build -t store-blueprint:stabilization .
```

## Success

Clean final branch, no doc contradictions, no test failures.

### TOON prompt

| Field     | Content                                                                                                                                                                                                                                                                          |
| --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Run final stabilization verification and resolve any doc/config inconsistencies.                                                                                                                                                                                                 |
| Objective | Ensure the stabilization pass is merge-ready and does not regress code quality, tests, deployment docs, or architecture rules.                                                                                                                                                   |
| Output    | Final verification note with commands run, results, unresolved blockers, and files changed.                                                                                                                                                                                      |
| Note      | Do not add new features. Fix only inconsistencies or broken gates caused by this stabilization work. Performance review: confirm no runtime hot-path behavior changed unexpectedly; Docker/build changes must not weaken PgBouncer, Redis, Oban, telemetry, or release behavior. |

---

# Phase 6 — Future facade refactor tickets

## Goal

Convert facade split plan into future work, but do not implement yet.

## Run mode

**After Phase 5. Optional.**

## Files touched

```text id="m34l46"
docs/architecture/facade-split-plan.md
possibly issue tracker/beads only
```

## Success

Future refactors are queued safely.

### TOON prompt

| Field     | Content                                                                                                                                                                                                                                                                                                                      |
| --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Create future implementation tickets/beads from `docs/architecture/facade-split-plan.md`.                                                                                                                                                                                                                                    |
| Objective | Prepare incremental facade refactoring without mixing it into the stabilization pass.                                                                                                                                                                                                                                        |
| Output    | Beads/issues for each future facade split task, each with acceptance criteria and dependencies.                                                                                                                                                                                                                              |
| Note      | Do not move code. Each future ticket must cover exactly one module extraction and must preserve public API, transaction boundaries, telemetry, idempotency, and tests. Performance review: every future refactor ticket must include query-count risk, lock-order risk, cache invalidation risk, and telemetry preservation. |

---

# Parallel execution matrix

| Phase                         |         Can run parallel? | Parallel with            | Must wait for               | Conflict risk |
| ----------------------------- | ------------------------: | ------------------------ | --------------------------- | ------------- |
| Phase 0                       |                        No | None                     | None                        | Low           |
| Phase 1                       |                        No | None                     | Phase 0                     | Low           |
| Phase 2A Architecture         |                       Yes | 2B, 2C, 2D               | Phase 1                     | Low           |
| Phase 2B Deployment           |                       Yes | 2A, 2D                   | Phase 1                     | Medium        |
| Phase 2C Payments             |                       Yes | 2A, 2D                   | Phase 1                     | Low           |
| Phase 2D Admin audit          |                       Yes | 2A, 2B, 2C               | Phase 1                     | Medium        |
| Phase 3A Docker/version       | No, preferably same as 2B | None                     | 2B                          | Medium        |
| Phase 3B Deployment polish    |                        No | None                     | 2B + 2C                     | Medium        |
| Phase 3C Architecture polish  |                       Yes | 3A/3B if no README edits | 2A                          | Low           |
| Phase 3D Admin implementation |                        No | None                     | 2D                          | High          |
| Phase 4 README                |                        No | None                     | 2A–2D + 3A–3C + optional 3D | High          |
| Phase 5 Verification          |                        No | None                     | Phase 4                     | Medium        |
| Phase 6 Future tickets        |   Yes, after verification | None needed              | Phase 5                     | Low           |

---

# Best branch layout

```text id="9cg2r7"
stabilization/source-of-truth
stabilization/architecture-docs
stabilization/deployment-runtime
stabilization/payment-readiness
stabilization/admin-auth-audit
stabilization/admin-auth-gate          # only if needed
stabilization/readme-integration
stabilization/final-verification
```

---

# Best merge order

```text id="lmdtas"
1. stabilization/source-of-truth
2. stabilization/architecture-docs
3. stabilization/payment-readiness
4. stabilization/deployment-runtime
5. stabilization/admin-auth-audit
6. stabilization/admin-auth-gate, only if required
7. stabilization/readme-integration
8. stabilization/final-verification
```

Reason: docs with isolated files merge first; deployment/config next; security implementation only if needed; README last.

---

# What not to parallelize

Do **not** parallelize these:

```text id="dh7284"
README.md edits
Dockerfile edits
mix.exs edits
admin router/auth edits
docs/deployment/env-vars.md edits by multiple agents
```

Those are high-conflict files.

---

# Recommended practical run

## Wave 1 — Serial setup

```text id="l2tpj0"
Phase 0
Phase 1
```

## Wave 2 — Parallel agents

```text id="03s0s4"
Agent A: Phase 2A Architecture
Agent B: Phase 2B Deployment/runtime
Agent C: Phase 2C Payment readiness
Agent D: Phase 2D Admin audit
```

## Wave 3 — Conditional/final targeted fixes

```text id="u2q3j9"
Agent B: Phase 3A + 3B
Agent A: Phase 3C
Agent D: Phase 3D only if audit proves a gap
```

## Wave 4 — Serial integration

```text id="ec23sh"
Phase 4 README integration
Phase 5 Final verification
```

## Wave 5 — Future planning

```text id="ycjmol"
Phase 6 Future facade refactor tickets
```

---

# Final recommendation

Use this order:

```text id="6x8pyl"
Phase 0 → Phase 1 → [2A + 2B + 2C + 2D in parallel] → [3A/3B/3C + optional 3D] → Phase 4 → Phase 5 → Phase 6
```

That gives you maximum safe parallelism without turning the repo into a merge-conflict mess.
