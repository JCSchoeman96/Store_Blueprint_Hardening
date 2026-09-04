# AGENTS.md (MANDATORY)

If a rule is not in **AGENTS.md** or **docs/agent_rules/**, it is not a rule.

---

## Workflow
- ALWAYS create or update a PR, so that the work and implementation or info can be checked and reviewed

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

# Beads (MANDATORY — HARD MODE)
- NO WORK WITHOUT A BEAD (code/docs/config/tests)
- Use normal bd create (no --sandbox) for parent/children.

## Session start (EVERY SESSION)
1) `bd dolt test`
2) `bd status`
3) `bd ready`
4) `bd update <id> --claim` (claim exactly one)
5) If nothing ready: create bead then claim

## Bead requirements
- Must include: `--description`, `--acceptance`, `--labels` (phase+area), `--priority` (P0–P4), `--parent`

## Dependencies/blockers
- `bd dep add <blocked_id> <blocker_id>` (blocked DEPENDS ON blocker)
- If blocked: create blocker bead, link dep, stop/pivot

## Notes format (MUST)
- GOAL / PLAN / DONE / NEXT / BLOCKERS / COMMANDS RUN / GATES

## Tree
- Use: `bd show <id>`
- Do not rely on: `bd list --parent`, `bd children --json`, `bd query` (unless proven)

---

## Beads Storage + Sync (v0.56.1 Dolt server-mode)
- DB path: `.beads/dolt/beads_store_blueprint/`
- Service: `dolt-beads.service` (systemd user)
- Safe checks:
  - `systemctl --user status dolt-beads.service --no-pager`
  - `bd dolt test`
- Never run two Dolt SQL servers against same repo

### Remotes
- `origin` (DoltHub `jc_s/store_blueprint`) is authoritative
- `local_backup` = `file://$HOME/beads_remotes/store_blueprint_beads_remote`

### Push (REQUIRED for phase close)
1) `systemctl --user stop dolt-beads.service`
2) `cd .beads/dolt/beads_store_blueprint && dolt push origin main`
3) `systemctl --user start dolt-beads.service`

### Pull
1) stop service
2) `dolt pull origin main`
3) start service

- If `bd dolt push/pull` fails: use native `dolt push/pull`
- Do NOT commit `.beads/dolt/**` to Git

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