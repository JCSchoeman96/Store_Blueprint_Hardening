If a rule is not in AGENTS.md or docs/agent_rules/, it is not a rule.

# Project
- Strict Ash 3.x project with Elixir, Phoenix, LiveView, Alpine.js and Tailwind
- Use Mishka Chelekom components:
  - UI components must come from Mishka Chelekom generation, not random custom component sprawl.

## Codex Skills (MANDATORY)
- Frontend UI work MUST follow:
  - `.agents/skills/frontend-design/SKILL.md`

## Store Blueprint Non-Negotiables (MUST NOT DRIFT)
- App namespace / OTP: `Store` / `:store`
- Single-tenant only: NO `tenant_id`, NO tenant routing, NO marketplace
- Ash **3.x only**
- Naming: `snake_case` everywhere; error codes `SCREAMING_SNAKE_CASE`
- Money: integer minor units only + currency (no floats)
- IDs:
  - UUIDv7 PKs
  - Deterministic UUID Binary Sort Law for hashing/tie-break/lock ordering
  - BAN UUID string sorting in those contexts
  - Polyglot IDs: internal UUIDv7, external prefixed ids, customer `order_ref`

## Beads (MANDATORY task tracking — HARD MODE)
Beads (`bd`) is the only task system. No markdown TODOs, no “mental tracking”.

### Golden rule (MUST)
- NO WORK WITHOUT A BEAD.
- Before changing code/docs/config/tests, you MUST have an open, claimed bead.

### Required Beads fields (MUST)
Every newly created bead MUST include:
- `--description` (what + why)
- `--acceptance` (how we know it's done / gates)
- `--labels` (at least phase + area)
- `--priority` (P0–P4)
- `--parent` (phase bead or epic bead)

### Session start (EVERY SESSION, MUST)
1) `bd prime --json` (if available) then `bd ready --json`
2) Claim exactly one ready bead: `bd update <id> --claim`
3) If nothing is ready: create one immediately, then claim it.

### Creating beads (MUST)
- Use structured creation (example):
  - `bd create --title "Phase 01: implement uuid_v7 + binary_uuid_sort" --type task --priority P0 --parent "<phase_id>" --labels phase-01,id-laws --description "..." --acceptance "..."`

### Dependencies + blockers (MUST)
- Dependencies MUST be explicit and correct:
  - `bd dep add <blocked_id> <blocker_id>`  (blocked DEPENDS ON blocker)
  - or: `bd dep <blocker_id> --blocks <blocked_id>`
- If you discover a blocker:
  1) create a blocker bead (P0 unless clearly minor)
  2) link it as a dependency
  3) stop/pivot (don’t work inside a blocked bead)

### Notes updates (MUST, non-interactive)
- DO NOT use `bd edit`.
- Update via `bd update ...` flags.
- Notes MUST contain:
  - GOAL / PLAN / DONE / NEXT / BLOCKERS / COMMANDS RUN / GATES

### Closure (MUST)
- Close with a real resolution:
  - `bd close <id> --reason "<outcome + files changed + gates run>" --suggest-next`
- A bead is not done until:
  - `bd sync` succeeds AND `git push` succeeds.

### End of session (MANDATORY)
- `bd sync`
- `git pull --rebase`
- `git push`
- `git status` must be clean + up to date

### Dependency hygiene (MUST)
- On phase fanout (creating child beads), run: `bd dep cycles`
- Fix any cycles before claiming work.

## Rule sources (authoritative)
- AGENTS.md (this file)
- docs/agent_rules/ (permanent rules)
- docs/governance/ (hard invariants + test/CI gates)
- docs/phases/ (build order)
- docs/agent_notes/phase_XX_docs.md (phase evidence + links + decisions)

## Docs-first phase notes (MANDATORY)
- The agent MUST create + maintain:
  - `docs/agent_notes/phase_00_docs.md`
  - `docs/agent_notes/phase_01_docs.md`
  - `docs/agent_notes/phase_02_docs.md`
  - `docs/agent_notes/phase_03_docs.md`
- Each file MUST include:
  - links consulted (Hexdocs + web search)
  - what docs recommend now
  - decisions taken (pins)
  - performance review (hot/warm/cold, indexes, TTL, invalidation, PubSub)
- No phase work starts until the phase note file is updated.

## Enforcement gates (MUST)
- Web layer: no direct Repo usage under `lib/store_web/**`
- Side effects quarantine: no HTTP + no Oban enqueue in web (except webhook enqueue-only)
- Outbound HTTP only via `Store.Support.HTTP.ReqClient`
- Immutable snapshots: OrderLineItem/OrderAdjustment create+read only
- Checkout interlocks: checkout_key + payment_intent_key idempotency
- Pricing determinism: pinned stacking/rounding/allocation (no penny leaks)
- Inventory: reservations + TTL + no oversell (default)
- Refunds: step-up protected + idempotent + refundable bound

## Project guidelines

- NEVER weaken tests to get a green pass
- MUST: Test must always be strict and airtight, never weaken just to get a pass, rather change and get code better.

- Strict Ash 3.x project with Elixir, Phoenix, LiveView, Alpine.js
- Run `mix check` before closing a bead (or before final push if no code changed).
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps

## Alpine.js scope (MUST)
- Alpine.js is allowed for micro-interactions only (dropdowns, tabs, focus, toggles).
- MUST NOT duplicate server state or implement business logic client-side.
- LiveView remains source of truth.



