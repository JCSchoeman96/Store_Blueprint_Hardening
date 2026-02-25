If a rule is not in AGENTS.md or docs/agent_rules/, it is not a rule.

# Project
- Strict Ash 3.x project using Elixir, Phoenix, LiveView, Alpine.js, and Tailwind.
- UI must use Mishka Chelekom components:
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
  - error codes: `SCREAMING_SNAKE_CASE`
- Money: integer minor units only + explicit currency (no floats)
- IDs:
  - UUIDv7 PKs
  - Deterministic UUID Binary Sort Law for hashing / tie-breaks / lock ordering
  - BAN UUID string sorting in those contexts
  - Polyglot IDs: internal UUIDv7, external prefixed ids, customer `order_ref`

# Beads (MANDATORY task tracking — HARD MODE)
Beads (`bd`) is the only task system. No markdown TODOs and no “mental tracking”.

## Golden rule (MUST)
- NO WORK WITHOUT A BEAD.
- Before changing code/docs/config/tests, you MUST have an open, claimed bead.

## Required bead fields (MUST)
Every newly created bead MUST include:
- `--description` (what + why)
- `--acceptance` (how we know it's done / gates)
- `--labels` (at least phase + area)
- `--priority` (P0–P4)
- `--parent` (phase bead or epic bead)

## Session start (EVERY SESSION, MUST)
1) `bd status`
2) `bd ready` (use `--json` only if it works)
3) Claim exactly one bead: `bd update <id> --claim`
4) If nothing is ready:
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
- On phase fanout (creating child beads), run: `bd dep cycles`
- Fix any cycles before claiming work.

## Beads safety (MUST)
- Never run `bd doctor --fix` without prompting and a stated plan.
  - It can repair/reinitialize stores and cause data loss if misused.

# Remote Sync Authority (MANDATORY)
- Authoritative remote sync is Git:
  - `git pull --rebase`
  - `git push`
  - `git status -sb` must show `main...origin/main`
- Do not require `bd dolt push/pull` unless a Dolt remote store has been explicitly configured.

# Closure Protocol (MUST)
- Close with a real resolution:
  - `bd close <id> --reason "<outcome + files changed + gates run>" --suggest-next`
- A bead is not done until:
  - `git pull --rebase` succeeds
  - `git push` succeeds
  - `git status -sb` shows `main...origin/main`
- Beads audit persistence:
  - `bd export --format jsonl --output .beads/issues.jsonl --force`
  - `bd export --events --force`
  - commit/push only if those files changed
  - Confirm custom gates pass: mix check (includes web_no_http, web_no_oban_enqueue, no_repo_in_web, req_usage).

# End of session (MANDATORY)
- `bd export --format jsonl --output .beads/issues.jsonl --force`
- `bd export --events --force`
- `git pull --rebase`
- `git push`
- `git status -sb`

### Beads audit persistence (MUST)
- Preferred (if available):
  - `bd export --format jsonl --output .beads/issues.jsonl --force`
  - `bd export --events --force`
- If `bd export` is not available in the installed bd CLI:
  - Use `bd sync` as the fallback exporter
  - Ensure `.beads/issues.jsonl` and `.beads/events.jsonl` are updated
- Commit/push only if those files changed.

### Tooling Safety
- - If a required Beads command is missing, record the output of `bd version` + `bd help` in the closure bead notes and proceed with the documented fallback.

# Rule sources (authoritative)
- AGENTS.md (this file)
- docs/agent_rules/ (permanent rules)
- docs/governance/ (hard invariants + test/CI gates)
- docs/phases/ (build order)
- docs/agent_notes/phase_XX_docs.md (phase evidence + links + decisions)

# Docs-first phase notes (MANDATORY)
- For every phase `XX`, the agent MUST create + maintain:
  - `docs/agent_notes/phase_XX_docs.md`
- Each phase note MUST include:
  - links consulted (Hexdocs + web search)
  - what docs recommend now
  - decisions taken (pins)
  - performance review (hot/warm/cold, indexes, TTL, invalidation, PubSub)
- No phase work starts until the phase note file is updated.

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