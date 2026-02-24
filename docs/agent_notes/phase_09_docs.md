# Phase 09 — Immutable snapshots

## GOAL

Implement immutable order snapshot evidence so historical order line items and adjustments are audit-stable and cannot be mutated after creation.

## LINKS CONSULTED

- Project docs:
  - `docs/phases/phase_09_immutable_snapshots.md`
  - `docs/governance/immutable_snapshots.md`
  - `docs/governance/enforcement_gates.md`
  - `docs/governance/policy_matrix.md`
- Official docs:
  - https://hexdocs.pm/ash/actions.html
  - https://hexdocs.pm/ash/policies.html
  - https://hexdocs.pm/ash/read-actions.html

## PLAN

- Add `Store.Orders.OrderLineItem` and `Store.Orders.OrderAdjustment` resources with create/read only action surfaces.
- Add deterministic ordering invariants:
  - `order_line_items.line_no` with unique `(order_id, line_no)`.
  - `order_adjustments.sequence_no` with unique `(order_id, sequence_no)`.
- Enforce customer row visibility via parent order ownership.
- Ensure admin/support read scope is available through role-aware read path.
- Add governance tests that fail loudly on immutable-surface drift.
- Add truthful read-immutability test proving read paths return stored evidence values (no read-time recomputation).

## DONE

- Created Phase 09 bead tree and dependency fanout:
  - `store_blueprint-7yf.3` (parent)
  - `store_blueprint-7yf.3.1` docs + phase notes alignment
  - `store_blueprint-7yf.3.2` immutable snapshot resources + DB invariants
  - `store_blueprint-7yf.3.3` row-visibility policies via parent order
  - `store_blueprint-7yf.3.4` immutable snapshot governance gates
  - `store_blueprint-7yf.3.5` snapshot read immutability test (no recompute)
  - `store_blueprint-7yf.3.6` gates verification + closure evidence
- Added dependencies and verified no cycles.
- Added immutable snapshot resources:
  - `lib/store/orders/order_line_item.ex`
  - `lib/store/orders/order_adjustment.ex`
- Added migration with deterministic ordering invariants and indexes:
  - `priv/repo/migrations/20260224140000_phase_09_immutable_snapshots.exs`
  - `line_no` + unique `(order_id, line_no)` on `order_line_items`
  - `sequence_no` + unique `(order_id, sequence_no)` on `order_adjustments`
  - `order_id` indexes on both tables
- Updated `lib/store/orders/domain.ex` to register both snapshot resources.
- Implemented row-visibility read behavior:
  - customer reads are scoped to parent orders owned by the actor
  - admin/support roles can read across orders
- Added governance tests:
  - `test/store/governance/immutable_snapshots_test.exs`
  - asserts no update/destroy actions
  - asserts customer scoped visibility
  - asserts admin/support broad read
  - asserts ordering uniqueness behavior
- Added truthful read-immutability test:
  - `test/store/governance/snapshot_read_immutability_test.exs`
  - verifies stored snapshot evidence values are returned unchanged across reads/state transition
- Updated docs to reflect truthful Phase 09 scope and defer real product-price-change stability gate until pricing/catalog phases exist.

## NEXT

- Run full `mix check` and verify all Phase 09 gates in the normal check pipeline.
- Close Phase 09 child beads and parent bead with command/gate evidence.

## BLOCKERS

- None currently.

## GATES

- Snapshot resources expose create/read only action surfaces.
- Governance tests fail on immutable-surface drift.
- Read-immutability test proves values are stored evidence, not read-time recomputation.
- Deterministic ordering invariants are enforced with DB uniqueness constraints.

## PERFORMANCE/SCALING REVIEW

- Hot path:
  - read filtering on snapshot tables by `order_id`.
- Warm path:
  - support/admin reads spanning multiple orders.
- Cold path:
  - historical audit and evidence inspection.
- Indexes:
  - `order_line_items_order_id_index`
  - `order_adjustments_order_id_index`
  - unique `(order_id, line_no)` and `(order_id, sequence_no)` constraints
- TTL/invalidation/PubSub:
  - no TTL, cache invalidation, or PubSub fanout changes in Phase 09.

## COMMANDS RUN

- `bd prime --json`
- `bd ready --json`
- `bd create ...` for `store_blueprint-7yf.3` and children
- `bd dep add ...`
- `bd dep cycles`
- `bd update store_blueprint-7yf.3.1 --claim`
- `mix compile`
- `mix test test/store/governance/immutable_snapshots_test.exs`
- `mix test test/store/governance/immutable_snapshots_test.exs test/store/governance/snapshot_read_immutability_test.exs`
