# AGENTS.md (MANDATORY)

`origin/main` is the canonical accepted Store Blueprint runtime. Linear is the canonical hardening execution queue.

Technical requirements in this file apply to implementation. Historical governance, workstream registries, and branch SHA pins provide provenance and context; they do not grant or withhold permission to begin ordinary implementation when prerequisites are accepted on `main`.

---

## Sequential hardening workflow (MANDATORY)

Default local development uses one Git worktree, one active Linear implementation issue, and one short-lived issue branch at a time. Do not create additional worktrees unless the human explicitly authorizes parallel work for a specific reason.

Use this normal lifecycle:

`Backlog` → `Todo` → `In Progress` → `In Review` → `Done`

Exceptional state: `Blocked`.

Linear is the canonical execution queue. GitHub Issues may be used when independently useful or technically required; do not require a mirror for every Linear issue, dependency, or blocker. Do not create process issues to authorize work, refresh pins, or record that a prerequisite merged.

### Starting an issue

Before implementation, confirm the issue and acceptance criteria in Linear and verify that its concrete prerequisites are accepted on `main`.

In the normal repository worktree:

```bash
git fetch origin
git switch main
git pull --ff-only
git status --short
git switch -c <issue-branch>
```

Every issue branch starts from the current canonical `origin/main`. Record its exact base SHA as review evidence. No separate governance PR or task-base assignment is required.

Recommended branch names include `jc-229-<short-description>` and `jc-230-<short-description>`.

### Dependencies and architecture questions

When a prerequisite implementation is accepted on `main`, the dependent issue may proceed. Verify that the relevant capability exists at implementation start. Do not require re-admission, authority refresh, task-base governance, or branch-pin updates.

If implementation reveals genuine semantic ambiguity, stop only the affected portion, state the decision that is needed, and document it in the smallest appropriate durable place, such as the Linear issue, implementation PR, tests, code, or an ADR when the decision is substantial and reusable. Do not automatically create a separate governance issue or PR.

### Implementation review and merge

Implementation PRs target `main`. Before recommending merge, review the exact base SHA, head SHA, diff, changed files, issue acceptance criteria, lifecycle behavior, database invariants, concurrency, retry/replay, crash/recovery where relevant, tests, CI, and security/performance where relevant. Performance-sensitive changes include the “Performance & Scaling Review” described below.

Human merge is required. Do not enable automatic merging solely because the workflow is sequential.

After human merge:

```bash
git switch main
git fetch origin
git pull --ff-only
git status --short
```

Verify that local `main` equals `origin/main` and the worktree is clean. Mark the completed Linear issue `Done`, then select the next issue.

---

## Project (MUST NOT DRIFT)
- Stack: Elixir, Phoenix, LiveView, Alpine.js, Tailwind, **Ash 3.x**
- OTP: `Store` / `:store`
- Single-tenant: **NO `tenant_id`**, NO tenant routing, NO marketplace
- UI: **Mishka Chelekom components only**
- Frontend skill rules: `.agents/skills/frontend-design/SKILL.md`

---

## Technical references

Use current code, tests, accepted changes on `main`, and relevant technical documentation to understand behavior and constraints. Historical governance documents, `docs/agent_rules/active_workstreams.md`, and old branch SHA pins are provenance only; they are not execution gates and cannot override current Git state or Linear acceptance criteria.

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
- PR notes MUST include “Performance & Scaling Review”:
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

## Validation and session close

- Run the checks required by the issue and affected code. For implementation changes, include relevant tests and repository CI checks; do not weaken or skip a required check because a change appears small.
- Keep PRs focused and reviewable. Document meaningful behavior or architecture decisions in the issue, PR, tests, code, or an ADR when warranted.
- Before ending work, report the current branch, its PR/CI/review status, validation performed, and any remaining blocker.
