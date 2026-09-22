# S0 baseline reconciliation implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Produce a reviewable S0 candidate that reconciles the accepted `origin/main` runtime baseline with the frozen S0 InventoryAdmission baseline without granting S0 implementation authority or changing canonical governance.

**Architecture:** Start from `origin/hardening/s0-baseline` in a dedicated integration worktree, merge the exact `origin/main` SHA, and resolve only mechanical/runtime/documentation conflicts. Treat InventoryAdmission semantics, PostgreSQL reservation authority, Redis coordination, `K_v = 1`, migrations, SUBS truth, and generic PLATFORM infrastructure as protected boundaries. Record both source SHAs, validation evidence, and unresolved activation decisions for independent review.

**Tech Stack:** Elixir, Phoenix, Ash 3.x, PostgreSQL, Redis, Mix, ExUnit, Dialyzer, Credo, Sobelow, and repository governance documents.

---

### Task 1: Capture reconciliation inputs and protected boundaries

**Files:**
- Modify: `docs/agent_notes/phase_00_docs.md` with the reconciliation record and validation evidence.
- Modify: this plan only if source facts change during verification.

- [x] **Step 1: Record exact source SHAs.**

Run:

```bash
git fetch origin
git rev-parse origin/main
git rev-parse origin/hardening/s0-baseline
git merge-base origin/main origin/hardening/s0-baseline
git status -sb
```

Expected source SHAs are `59dd41100593b207907c3a7ab4d77755cd80f929` and `9b0b26a68399149abdde7c96529fbc1951e22cac`; the worktree must be clean before the merge.

- [x] **Step 2: Classify pre-merge overlap.**

Run:

```bash
BASE=$(git merge-base origin/main origin/hardening/s0-baseline)
git diff --name-status "$BASE"..origin/main > /tmp/s0-main-file-set.txt
git diff --name-status "$BASE"..origin/hardening/s0-baseline > /tmp/s0-branch-file-set.txt
comm -12 <(cut -f2 /tmp/s0-main-file-set.txt | sort) <(cut -f2 /tmp/s0-branch-file-set.txt | sort)
```

Use the overlap list to anticipate conflicts. Do not edit files yet.

- [x] **Step 3: Confirm protected S0 boundaries.**

Run:

```bash
rg -n "K_v|PostgreSQL|Redis|reservation|migration|IA-03|BOOTSTRAPPED|implementation authority" docs/hardening lib/store/orders/inventory_admission test/store/orders
```

The merge must preserve the existing InventoryAdmission lifecycle and tests. Any semantic contradiction requires a stop and review instead of a conflict workaround.

### Task 2: Merge canonical main into the bounded integration branch

**Files:**
- Modify: files reported by Git as merge conflicts, limited to accepted `origin/main` changes and the existing S0 baseline.
- Do not modify: `lib/store/orders/inventory_admission/**`, its existing tests, migrations, SUBS commercial resources, or generic PLATFORM Redis infrastructure unless a conflict proves an unavoidable contradiction and review authorizes reopening the boundary.

- [x] **Step 1: Create the merge commit from exact refs.**

Run:

```bash
git merge --no-ff --no-edit origin/main
```

Expected result is either a clean merge or a conflict list. If Git reports a conflict in InventoryAdmission behavior, a migration, SUBS commercial truth, or generic PLATFORM infrastructure, stop before resolving it and record the path for review.

- [x] **Step 2: Resolve only mechanical conflicts.**

For each conflict, inspect both sides with:

```bash
git checkout --conflict=diff3 -- <path>
git diff --cc -- <path>
```

Keep canonical `main` for shared runtime and governance inputs, keep S0 for frozen InventoryAdmission documents and implementation, and combine non-overlapping tests or docs without changing behavior. Remove all conflict markers, then stage only reviewed files:

```bash
git add <reviewed-paths>
git diff --cached --check
git status --short
```

- [x] **Step 3: Verify no forbidden migration or IA authority change.**

Run:

```bash
git diff --name-status HEAD^1 HEAD -- priv/repo/migrations docs/hardening lib/store/orders/inventory_admission
git diff HEAD^1 HEAD -- lib/store/orders/inventory_admission docs/hardening/s0_inventory_reservation_admission_architecture.md
```

If a migration appears, or the diff changes `K_v`, Redis/PostgreSQL authority, durable reservation semantics, or lifecycle guards, stop and reopen the applicable architecture authority.

### Task 3: Document the reconciled candidate and review scope

**Files:**
- Modify: `docs/agent_notes/phase_00_docs.md` with source SHAs, candidate SHA, review scope, and performance review.
- Do not modify: canonical lifecycle state on this branch.

- [x] **Step 1: Record source and candidate SHAs.**

Run:

```bash
git rev-parse HEAD^1
git rev-parse HEAD^2
git rev-parse HEAD
git show --stat --oneline --decorate HEAD
```

The note must identify both source SHAs, the merge base, the candidate SHA, and that S0 remains `BOOTSTRAPPED` pending independent acceptance.

- [x] **Step 2: Add the required performance review.**

Cover hot paths affected by the merge, DB query count and N+1 risk, indexes, cache/TTL/invalidation impact, Oban uniqueness or idempotency impact, and telemetry/logging. State `no change` when applicable and link to the governing performance documents.

- [x] **Step 3: Commit the reconciliation record.**

Run:

```bash
git add docs/agent_notes/phase_00_docs.md
git commit -m "docs(s0): record baseline reconciliation candidate"
```

### Task 4: Validate the exact candidate head

**Files:**
- No source changes are allowed while validation runs.

- [x] **Step 1: Run repository checks.**

Run:

```bash
mix check
```

Record the full exit status and failures. Do not claim activation readiness if this command fails.

- [x] **Step 2: Run InventoryAdmission tests and type checks.**

Run:

```bash
mix test test/store/orders/inventory_admission_state_test.exs test/store/orders/inventory_admission_redis_test.exs
mix dialyzer --format short
```

These commands must pass on the exact candidate SHA. Historical CI evidence from earlier heads is not sufficient.

- [x] **Step 3: Check the final diff for forbidden changes.**

Run:

```bash
git diff --check origin/hardening/s0-baseline...HEAD
git diff --name-status origin/hardening/s0-baseline...HEAD
git status -sb
```

The result must show a clean worktree and no unauthorized migrations, IA semantic changes, SUBS commercial changes, or generic PLATFORM ownership changes.

- [x] **Step 4: Resolve the strict test-environment type gate.**

The first CI run reported unsuppressed Dialyzer findings in the S0-only checkout
diagnostic helper because canonical `main` now runs `mix check.types` under
`MIX_ENV=test`. Reproduce that failure before changing code, then keep the fix
bounded to the helper: use the canonical `File.stream!/3` contract, make ETS
side-effect returns explicit, remove unreachable fallback/error branches, and
narrow the affected contracts to their inferred error shapes. Do not add broad
ignore entries or touch InventoryAdmission behavior.

Validation after the fix:

```bash
MIX_ENV=test mix check.types
mix test test/store/perf/checkout_diagnostic_test.exs \
  test/store/perf/observer_contract_test.exs \
  test/store/perf/performance_smoke_test.exs \
  test/store/orders/inventory_admission_state_test.exs \
  test/store/orders/inventory_admission_redis_test.exs
mix check
mix dialyzer --format short
```

All commands must pass on the exact code candidate before publication.

### Task 5: Prepare independent activation review without self-activating S0

**Files:**
- Modify: the reconciliation note only if validation produces new evidence.

- [x] **Step 1: Publish the bounded branch and open or update its PR.**

Run:

```bash
git push -u origin integration/s0-baseline-reconciliation
gh pr create --base main --head integration/s0-baseline-reconciliation --title "chore(s0): reconcile activation baseline" --body-file docs/superpowers/plans/2026-09-22-s0-baseline-reconciliation.md
```

If a PR already exists, update it instead of creating a duplicate.

- [x] **Step 2: State the activation boundary.**

The PR must say that it proposes a reconciled candidate and validation evidence only. It must not claim that S0 is activated, accept a development base, authorize IA-03, or edit canonical `main` governance. Those actions require independent review and explicit human acceptance.

- [x] **Step 3: Stop at the review handoff.**

After publishing the candidate and evidence, stop. Do not merge the PR, change `hardening/s0-baseline`, start IA-03, or alter canonical lifecycle state in this workstream.
