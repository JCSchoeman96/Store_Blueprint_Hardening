If a rule is not in AGENTS.md or docs/agent_rules/, it is not a rule.

# Project
- Strict Ash 3.x project using Elixir, Phoenix, LiveView, Alpine.js, and Tailwind.
- UI must use Mishka Chelekom components only:
  - UI components must come from Mishka Chelekom generation (no random custom component sprawl).

## Codex Skills (MANDATORY)
- Frontend UI work MUST follow:
  - `.agents/skills/frontend-design/SKILL.md`

## Store Blueprint Non-Negotiables (MUST NOT DRIFT)
- App namespace / OTP: `Store` / `:store`
- Single-tenant only: NO `tenant_id`, NO tenant routing, NO marketplace
- Ash 3.x only (no Ash 2.x patterns)
- Naming:
  - `snake_case` everywhere
  - stable error codes: `SCREAMING_SNAKE_CASE` (registry-backed)
- Money: integer minor units only + explicit currency (no floats)
- IDs:
  - UUIDv7 PKs
  - Deterministic UUID Binary Sort Law for hashing / tie-breaks / lock ordering
  - BAN UUID string sorting in those contexts
  - Polyglot IDs: internal UUIDv7, external prefixed ids, customer `order_ref`

# Rule Sources (Authoritative)
- AGENTS.md (this file)
- docs/agent_rules/ (permanent rules)
- docs/governance/ (hard invariants + gates)
- docs/phases/ (build order)
- docs/agent_notes/phase_XX_docs.md (phase evidence + links + decisions)

# Beads (MANDATORY task tracking — HARD MODE)
Beads (`bd`) is the only task system. No markdown TODOs and no “mental tracking”.

## Golden rule (MUST)
- NO WORK WITHOUT A BEAD.
- Before changing code/docs/config/tests, you MUST have an open, claimed bead.

## Required bead fields (MUST)
Every newly created bead MUST include:
- `--description` (what + why)
- `--acceptance` (how we know it’s done / gates)
- `--labels` (at least phase + area)
- `--priority` (P0–P4)
- `--parent` (phase bead or epic bead)

## Session start (EVERY SESSION, MUST)
1) Confirm Beads DB is reachable:
   - `bd dolt test`
2) `bd status`
3) `bd ready` (use `--json` only if it works reliably)
4) Claim exactly one bead:
   - `bd update <id> --claim`
5) If nothing is ready:
   - create a bead immediately
   - then claim it

## Creating beads (MUST)
Use structured creation (example):
- `bd create --title "Phase 01: implement uuid_v7 + binary_uuid_sort" --type task --priority P0 --parent "<phase_id>" --labels phase-01,id-laws --description "..." --acceptance "..."`

## Dependencies + blockers (MUST)
- Dependencies MUST be explicit and correct:
  - `bd dep add <blocked_id> <blocker_id>` (blocked DEPENDS ON blocker)
- If you discover a blocker:
  1) create a blocker bead (P0 unless clearly minor)
  2) link it as a dependency
  3) stop/pivot (don’t work inside a blocked bead)

## Notes updates (MUST)
- Prefer non-interactive updates via `bd update ...` flags.
- Notes MUST contain:
  - GOAL / PLAN / DONE / NEXT / BLOCKERS / COMMANDS RUN / GATES
- `bd edit` is allowed only when notes are long and formatting matters. Do not lose required sections.

## Dependency hygiene (MUST)
- On phase fanout (creating child beads), run:
  - `bd dep cycles`
- Fix any cycles before claiming work.

## Beads safety (MUST)
- Never run `bd doctor --fix` without prompting and a stated plan.
  - It can repair/reinitialize stores and cause data loss if misused.

# Beads Storage + Sync (v0.56.1 Dolt server-mode)
Beads uses a Dolt-backed database. JSONL export/sync is NOT the workflow.

## Where the Beads DB lives (local)
- Local Dolt repo (the Beads database):
  - `.beads/dolt/beads_store_blueprint/`

## Dolt server is REQUIRED for bd commands (MANDATORY)
Beads connects to a running Dolt SQL server (server-mode).

### Service (systemd user service)
- Service name: `dolt-beads.service`
- It should be enabled and running.

### Service checks (safe)
- `systemctl --user status dolt-beads.service --no-pager`
- `bd dolt test`

### Start/stop (only when needed)
- Start: `systemctl --user start dolt-beads.service`
- Stop: `systemctl --user stop dolt-beads.service`
- Restart: `systemctl --user restart dolt-beads.service`

### Do you need to run enable/daemon-reload every session?
NO.
- `systemctl --user daemon-reload` only after editing the service file.
- `systemctl --user enable --now dolt-beads.service` is one-time setup.

## Beads remote sync (file remote configured)
Beads DB remote is a Dolt remote (not Git).
- Dolt remote `origin` is configured as:
  - `file://$HOME/beads_remotes/store_blueprint_beads_remote`

### Push Beads DB to remote (ONLY when you want to sync/backup)
1) Stop the service (avoid lock contention):
   - `systemctl --user stop dolt-beads.service`
2) Push:
   - `cd .beads/dolt/beads_store_blueprint`
   - `dolt push origin main`
3) Start the service:
   - `systemctl --user start dolt-beads.service`

### Pull Beads DB from remote (on second PC or after restore)
1) Stop the service:
   - `systemctl --user stop dolt-beads.service`
2) Pull:
   - `cd .beads/dolt/beads_store_blueprint`
   - `dolt pull origin main`
3) Start the service:
   - `systemctl --user start dolt-beads.service`

### Important
- Do NOT commit `.beads/dolt/**` into the Store_Blueprint Git repo.
- If you need Git-based backup, use a tarball snapshot outside the repo (optional).

# Git Remote Sync Authority (Code Repo) (MANDATORY)
Authoritative remote sync for application code is Git:
- `git pull --rebase`
- `git push`
- `git status -sb` must show: `main...origin/main`

# Closure Protocol (MUST)
Close with a real resolution:
- `bd close <id> --reason "<outcome + files changed + gates run>" --suggest-next`

A bead is not done until:
1) Gates:
   - `mix check` passes
2) Code remote sync:
   - `git pull --rebase` succeeds
   - `git push` succeeds
   - `git status -sb` shows `main...origin/main`
3) Beads DB is healthy:
   - `bd dolt test` succeeds
   - (optional, when you want backup/sync) push Beads DB remote:
     - stop service → `dolt push origin main` → start service

# End of session (MANDATORY)
1) `mix check` (if any code/docs/tests changed)
2) `git pull --rebase`
3) `git push`
4) `git status -sb`
5) `bd status`
6) Optional (recommended daily): Beads DB remote backup
   - stop service → `dolt push origin main` → start service

# Docs-first phase notes (MANDATORY)
For every phase `XX`, the agent MUST create + maintain:
- `docs/agent_notes/phase_XX_docs.md`

Each phase note MUST include:
- links consulted (Hexdocs + web search)
- what docs recommend now
- decisions taken (pins)
- performance review (hot/warm/cold, indexes, TTL, invalidation, PubSub)

No phase work starts until the phase note file is updated.

# Enforcement gates (MUST)
- Web layer: no direct Repo usage under `lib/store_web/**`
- Side effects quarantine: no HTTP + no Oban enqueue in web (except webhook enqueue-only)
- Outbound HTTP only via `Store.Support.HTTP.ReqClient` (Req usage must be through the wrapper)
- Immutable snapshots: OrderLineItem/OrderAdjustment create + read only
- Checkout interlocks: checkout_key + payment_intent_key idempotency
- Pricing determinism: pinned stacking/rounding/allocation (no penny leaks)
- Inventory: reservations + TTL + no oversell (default)
- Refunds: step-up protected + idempotent + refundable bound

# Project guidelines (MUST)
- NEVER weaken tests to get a green pass.
- Fix code to satisfy strict tests, do not “vibe your way” to green.
- Run `mix check` before closing a bead (or before final push if no code changed).
- HTTP client policy:
  - Use `Req` only, via `Store.Support.HTTP.ReqClient`
  - Avoid `:httpoison`, `:tesla`, and `:httpc`

# Alpine.js scope (MUST)
- Alpine.js is allowed for micro-interactions only (dropdowns, tabs, focus, toggles).
- MUST NOT duplicate server state or implement business logic client-side.
- LiveView remains the source of truth.