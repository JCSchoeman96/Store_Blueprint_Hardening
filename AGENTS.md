# AGENTS.md (MANDATORY)

If a rule is not in **AGENTS.md** or **docs/agent_rules/**, it is not a rule.

---

## BRANCHES, WORKTREES & PARALLEL WORK AUTHORITY (MANDATORY)

Branches isolate Git history. Worktrees isolate execution. Ownership rules prevent semantic duplication.

All three controls are mandatory for parallel work.

### Permanent `main` worktree

The repository maintains one permanent local `main` worktree.

Rules:

* It MUST remain on `main`.
* It MUST track `origin/main`.
* It MUST remain clean.
* It MUST be updated by fast-forward only.
* It is read-mostly and MUST NOT be used for feature, hardening, governance, or experimental implementation.
* Use it for:

  * post-merge verification;
  * inspection of canonical `main`;
  * establishing the current `main` SHA;
  * creating workstreams whose declared authority is `main`.

`main` is synchronization, integration, release, and canonical-history authority — not a general implementation workspace.

### Authoritative parent rule

Every new workstream MUST declare its authoritative parent before work begins.

A workstream MUST branch from the exact SHA of that authority.

Do NOT assume every workstream branches from `main`.

Examples:

* dependency/security work may be authorized from `origin/main`;
* S0 hardening work may be authorized from `origin/hardening/s0-baseline`;
* integration work may combine two explicitly declared authoritative heads.

Before implementation, record:

* workstream name;
* authoritative parent ref;
* exact parent SHA;
* branch name;
* worktree path;
* owned domains/resources/files;
* explicitly excluded areas.

If the authoritative parent moves before work starts, STOP and re-evaluate the base.

### Mandatory branch + worktree

Every concurrent workstream MUST have:

1. its own dedicated Git branch; and
2. its own dedicated worktree.

No two active agents may share the same writable worktree.

Agents MUST NOT perform implementation directly on:

* `main`;
* another workstream's branch;
* another workstream's worktree.

A worktree is not a substitute for a branch, and a branch is not a substitute for a worktree.

### Ownership authority

Every active workstream MUST declare what it owns.

Ownership may include:

* domains;
* Ash resources;
* schemas/tables;
* migration lineages;
* snapshots;
* configuration;
* dependency graph;
* provider integrations;
* shared infrastructure;
* governance documents.

There MUST be only one active authority for a schema/resource/migration lineage at a time unless an explicit shared-authority decision has been recorded.

If a workstream discovers that it needs to modify something owned by another active workstream:

STOP.

Do not implement the overlap.

Request an authority decision first.

### Schema and migration rule

Parallel workstreams MUST NOT independently create or modify competing migration histories for the same resource/table.

Before creating or modifying a migration, verify:

* which workstream owns the resource;
* whether another active branch already changes the resource;
* whether the migration has been applied to any authoritative shared environment;
* whether a snapshot lineage already exists elsewhere.

If competing schema histories are discovered:

STOP and perform an explicit schema-authority/integration decision.

Never delete an already-authoritative deployed migration merely to reconcile Git history.

### Integration work

Integration is its own bounded workstream.

Significant convergence of parallel branches MUST use:

* a dedicated integration branch;
* a dedicated integration worktree;
* explicitly declared source SHAs;
* explicitly declared ownership/resolution rules.

The integration agent MUST NOT redesign either workstream while resolving conflicts.

Prefer a normal bounded merge for published long-lived branches unless an explicit authority permits another strategy.

No force push unless explicitly authorized.

After integration:

1. push the integrated branch;
2. run required validation;
3. obtain exact-head CI;
4. perform a fresh independent post-integration review;
5. only then declare the integration accepted.

The implementation author SHOULD NOT be the sole integration reviewer.

### Main-to-long-lived-branch synchronization

When `main` advances while a long-lived hardening/integration branch remains active, evaluate whether the new `main` changes affect that workstream before further implementation.

Integrate `main` first when it changes shared runtime or architectural dependencies such as:

* `mix.exs`;
* `mix.lock`;
* shared Redis infrastructure;
* HTTP/provider infrastructure;
* authentication/security foundations;
* database/schema authority;
* CI/static-analysis policy;
* shared configuration.

Do not continue building significant new work on a stale runtime/dependency baseline if a relevant `main` update has already been accepted.

### Workstream lifecycle

Use this lifecycle for meaningful parallel work:

`PLANNED`
→ `AUTHORITY_ASSIGNED`
→ `BRANCH_CREATED`
→ `WORKTREE_CREATED`
→ `OWNERSHIP_DECLARED`
→ `IMPLEMENTING`
→ `VALIDATED`
→ `PUSHED`
→ `READY_FOR_INTEGRATION`
→ `INTEGRATING`
→ `POST_INTEGRATION_REVIEW`
→ `COMPLETE`

Exceptional state:

`IMPLEMENTING`
→ `BLOCKED_AUTHORITY`
→ `STOP`

A workstream enters `BLOCKED_AUTHORITY` when ownership, schema lineage, migration history, architectural authority, or integration responsibility becomes ambiguous.

### Completion and cleanup

After a workstream is merged and independently verified on its target authority:

* mark it `MERGED → VERIFIED_ON_TARGET → REMOVED`;
* remove disposable implementation/review worktrees;
* delete local merged branches with safe `git branch -d`;
* remote feature branch deletion is optional housekeeping unless repository policy requires it.

Do not remove the permanent `main` worktree.

Do not remove an active long-lived hardening worktree until that workstream itself is formally closed.

### Required pre-work checks

Use only the minimum checks needed:

```bash
git fetch origin
git worktree list
git status
git branch -vv
git rev-parse <authoritative-ref>
```

For integration work also use:

```bash
git merge-base <ref-a> <ref-b>
git diff --name-status <merge-base>..<ref-a>
git diff --name-status <merge-base>..<ref-b>
```

Avoid unnecessary `git pull`, rebase, merge, reset, or force-push operations.

### Mandatory STOP conditions

STOP immediately if:

* the expected authoritative SHA moved;
* the target worktree is dirty;
* branch/worktree ownership is ambiguous;
* another active workstream owns the same schema/resource lineage;
* the task requires modifying another workstream's declared authority;
* competing migration or snapshot histories are discovered;
* integration requires changing frozen architecture;
* a supposedly isolated task requires substantial unrelated changes;
* a force push would be required without explicit authorization;
* the task would require implementing directly on `main`;
* later-phase work becomes necessary but is not authorized.

Report the blocker and request a new authority decision.

Do not self-authorize scope expansion.

### Core law

**Branch isolates history. Worktree isolates execution. Ownership isolates architecture.**

Parallel work requires all three.

---

## Project (MUST NOT DRIFT)
- Stack: Elixir, Phoenix, LiveView, Alpine.js, Tailwind, **Ash 3.x**
- OTP: `Store` / `:store`
- Single-tenant: **NO `tenant_id`**, NO tenant routing, NO marketplace
- UI: **Mishka Chelekom components only**
- Frontend skill rules: `.agents/skills/frontend-design/SKILL.md`

---

## Rule Sources (Authoritative)
1) `AGENTS.md`
2) `docs/agent_rules/`
3) `docs/governance/`
4) `docs/phases/`
5) `docs/agent_notes/phase_XX_docs.md`

---

## Global Laws (MUST)
- Naming: `snake_case` everywhere
- Error codes: `SCREAMING_SNAKE_CASE` (registry-backed)
- Money: **integer minor units + currency** (NO floats)
- IDs:
  - PK: **UUIDv7**
  - **Binary UUID sort law** for hashing/tie-breaks/lock ordering (BAN UUID string sort there)
  - Polyglot: internal UUIDv7, external prefixed ids, customer `order_ref` distinct

---

## Web Boundary (MUST)
- Web (`lib/store_web/**`) is adapter-only:
  - params → validate/normalize → typed struct → **domain facade** → render/response
- Web MUST NOT encode auth-meaningful query semantics
- Enforced gate (Phase 15):
  - **NO `Ash.Query`** in:
    - `lib/store_web/controllers/**`
    - `lib/store_web/live/**`
    - `lib/store_web/components/**`
  - Denies: `require Ash.Query` and `Ash.Query.`
  - Gate: `check.web_no_ash_query`
- Review-enforced (do not introduce):
  - no direct `Ash.read/create/update/destroy/load` in web
  - no `Repo.*` in web
  - no outbound HTTP in web
  - no Oban enqueue in web **except webhook enqueue-only**

---

## Webhooks (MUST)
- Controller allowed:
  - verify signature (raw body + headers)
  - normalize → canonical receipt
  - (optional) persist `WebhookReceipt`
  - enqueue **exactly one** Oban job
- Controller forbidden:
  - domain state transitions
  - outbound HTTP
- Workers: transitions via **domain facades only**, idempotent/replay-safe

---

## Payment Return/Cancel (MUST)
- Read-only: never mark paid/refund/confirm
- Never trust query params as payment proof

---

## Provider Modules (MUST)
- Allowed: build payload/redirect params, verify signature, normalize payload → canonical receipt
- Forbidden: `Repo.*`, `Ash.*`, Oban enqueue, business rules

---

## Domain Entrypoints (MUST)
- Controllers/LiveViews/Workers must call domain surfaces only:
  - `Store.Orders.*`, `Store.Payments.*`, `Store.Pricing.*`, `Store.Catalog.*`, `Store.Carts.*`,
    `Store.Checkout.*`, `Store.Shipping.*`, `Store.Fulfillment.*`, `Store.Comms.*`,
    `Store.Digital.*`, `Store.Subscriptions.*` (+ `Store.Memberships.*` / `Store.Entitlements.*` if present)
- Domain functions:
  - take `actor` (or explicit system actor)
  - take typed query/input struct (no raw params)
  - call resource actions / code interfaces (Ash is truth)

---

## Query Contracts (MUST)
- Query structs live in domain (`lib/store/**/queries/*.ex`)
- Web params modules may only coerce/validate/build typed structs (no `Ash.Query`)

---

## Notifications (Post-Commit) (MUST)
- If writes occur inside DB tx and notifications matter:
  - `return_notifications?: true` inside tx
  - collect notifications
  - `Ash.Notifier.notify/1` **after commit** via shared wrapper
- Tests keep: `config :ash, :missed_notifications, :raise`

---

## Email (MUST)
- No email in web
- Email via wrapper (`Store.Comms`/`Store.Notifications`) + Oban
- Idempotent: unique constraint (e.g. `order_id + template_kind`)
- Outbox + worker preferred/required for delivery

---

## Subscriptions (MUST)
- Renewals: Oban-only
- Idempotency: unique `renewal_key` per subscription per billing period
- Activate after first payment success (worker), not return URL

---

## Digital (MUST)
- Access via `DownloadGrant` only (no direct asset URLs)
- Signed URLs: short-lived, generated on demand
- Counters/revocations: replay-safe, worker-only

---

## One Public API Layer (MUST)
- v1: **ash_json_api only**
- no ash_graphql unless a later phase explicitly approves it

---

## Performance (Phase 29) (MUST on hot paths)
- Hot paths: storefront reads, cart, checkout, webhooks, outbox/email, digital downloads, renewals
- Bead/PR notes MUST include “Performance & Scaling Review”:
  - hot/warm/cold
  - DB query count + N+1 risk
  - indexes
  - caching (ETS/Redis), TTL, invalidation, stampede protection
  - Oban uniqueness/idempotency
  - telemetry/logging
- References:
  - `docs/governance/performance_scaling.md`
  - `docs/phases/phase_29_performance_architecture_optimizations.md`

---

## Phase Notes (Docs-first) (MUST)
- Every phase must have: `docs/agent_notes/phase_XX_docs.md`
- Must include: links consulted, decisions/pins, plan, performance review


---

## Workflow
- ALWAYS create or update a PR, so that the work and implementation or info can be checked and reviewed

---

## Git Sync Authority (Code Repo) (MANDATORY)
- `git pull --rebase`
- `git push`
- `git status -sb` must show `main...origin/main`

---

## Closure Protocol (MUST)
- `mix check` passes
- Git: `git pull --rebase` OK, `git push` OK, `git status -sb` clean vs origin
- Beads: `bd dolt test` OK
- Phase close: Beads DB push to `origin`
- Close bead:
  - `bd close <id> --reason "<outcome + files + gates>" --suggest-next`

---

## End of session (MANDATORY)
1) `mix check` (if anything changed)
2) `git pull --rebase`
3) `git push`
4) `git status -sb`
5) `bd status`
6) Optional daily: stop service → `dolt push origin main` → start service
