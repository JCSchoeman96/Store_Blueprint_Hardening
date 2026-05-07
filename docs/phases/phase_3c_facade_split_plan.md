# Phase 3C Facade Split Plan (Planning Only)

## Purpose

Define a future-facing, implementation-ready split strategy for oversized facade surfaces while preserving current behavior, public APIs, and stabilization governance constraints.

This document does not authorize runtime code movement in this phase.

## Scope

- Target facades:
  - `Store.Checkout.*`
  - `Store.Orders.*`
  - `Store.Payments.*`
- Planning outputs only:
  - ownership map
  - split topology
  - ordered extraction slices
  - acceptance criteria
  - risk and rollback triggers

## Non-goals

- No edits to `lib/**`, `config/**`, `priv/**`, or `test/**` in Phase 3C.
- No public API renames at controller/LiveView/worker call sites.
- No changes to policy semantics, runtime env contracts, or release behavior.

## Baseline Invariants (Must Preserve)

1. Web boundary invariants
   - `lib/store_web/**` remains adapter-only.
   - No `Ash.Query`, no direct `Ash.*`, no `Repo.*`, no outbound HTTP in web.
2. Domain entrypoint invariants
   - Web and workers keep calling top-level domain surfaces (`Store.Checkout.*`, `Store.Orders.*`, `Store.Payments.*`).
3. Data and transaction invariants
   - Existing transaction boundaries and lock ordering are preserved.
4. Idempotency/interlock invariants
   - Checkout/payment apply-once and uniqueness constraints remain intact.
5. Operational invariants
   - Query-count budgets and hot-path telemetry do not regress.

## Current Surface Inventory (Planning Baseline)

The inventory step for future implementation must enumerate each current exported function and classify it by responsibility. Initial target responsibility groups:

- Checkout groups
  - cart start/resume flows
  - totals/finalization flows
  - shipping selection/confirmation flows
- Orders groups
  - inventory reservation/sweep flows
  - order state transition orchestration
- Payments groups
  - provider setup/capability resolution
  - intent creation/application/result handling

## Target Topology (Without Public API Breakage)

Top-level facades remain stable for all callers. Internal decomposition is introduced behind wrapper functions.

Proposed internal split topology:

- `Store.Checkout`
  - `Store.Checkout.StartFromCart`
  - `Store.Checkout.FinalizeTotals`
  - `Store.Checkout.ShippingSelection`
- `Store.Orders`
  - `Store.Orders.InventorySweep`
  - `Store.Orders.StateTransitions`
- `Store.Payments`
  - `Store.Payments.ProviderSetup`
  - `Store.Payments.IntentLifecycle`

Wrapper rule:
- Existing public function names remain exported at the current top-level module.
- Wrappers delegate to extracted internal sub-facade modules.

## Ordered Refactor Slices (Future Work Tickets)

Each ticket must be small, independently mergeable, and acceptance-testable.

1. Slice 1: Inventory and call-path map freeze
   - Produce a signed-off matrix: `public_function -> target_submodule -> preserved_wrapper`.
   - Validate no unauthorized new web entrypoints are introduced.
2. Slice 2: Checkout split extraction
   - Extract one checkout concern at a time (`StartFromCart`, then `FinalizeTotals`, then `ShippingSelection`).
   - Preserve transaction and lock behavior on finalize path.
3. Slice 3: Orders inventory extraction
   - Extract `InventorySweep` behavior.
   - Preserve reservation semantics and rollback guarantees.
4. Slice 4: Payments setup extraction
   - Extract provider setup/capability logic.
   - Preserve idempotent intent and apply-once boundaries.
5. Slice 5: Final surface harmonization
   - Confirm wrapper parity, telemetry parity, and gate compliance across all moved internals.

## Ticket Acceptance Template (Mandatory for Each Future Slice)

- API parity
  - Top-level facade function signatures unchanged for callers.
- Gate parity
  - `check.web_no_ash_query`
  - `check.web_no_direct_ash_calls`
  - `check.no_repo_in_web`
  - `check.surface_naming`
- Behavior parity
  - No semantic drift in transitions, idempotency, or authorization boundaries.
- Performance parity
  - Query-count and latency budgets not worse than current baseline.
- Observability parity
  - Telemetry event names and critical metadata preserved.

## Stop-the-line Conditions (Future Execution)

- Any public facade signature change required to continue extraction.
- Any web-boundary gate regression.
- Any evidence of transaction/lock ordering drift.
- Any hot-path query-count regression beyond budget.
- Any checkout/payment idempotency/interlock failure.

## Migration Strategy Summary

- One module concern per PR.
- Preserve wrappers until all internal parity checks pass.
- Land extraction slices in dependency order (Checkout -> Orders -> Payments only where coupling requires it; otherwise isolate).
- Use immediate rollback to previous wrapper-only state when a stop-the-line condition appears.

## Evidence References

- `AGENTS.md`
- `docs/stabilization/source-of-truth.md`
- `docs/stabilization-pass.md`
- `docs/governance/enforcement_gates.md`
- `docs/governance/side_effects_quarantine.md`
- `docs/governance/policy_matrix.md`
- `docs/phases/phase_28_production_readiness_release_checklist.md`
- `docs/phases/phase_29_performance_architecture_optimizations.md`
- `docs/agent_notes/phase_14_docs.md`
- `docs/agent_notes/phase_15_docs.md`
- `docs/agent_notes/phase_29_docs.md`
- `docs/agent_notes/phase_30_docs.md`
