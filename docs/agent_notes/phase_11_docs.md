# Phase 11 - Inventory reservations

## GOAL

Implement strict no-oversell inventory reservations with atomic multi-item reserve, TTL expiry release, and replay-safe paid consume semantics.

## LINKS CONSULTED

- Project docs:
  - `docs/phases/phase_11_inventory_reservations.md`
  - `docs/governance/inventory_reservations.md`
  - `docs/governance/enforcement_gates.md`
  - `docs/governance/checkout_interlocks.md`
- External references:
  - https://hexdocs.pm/ecto/Ecto.Repo.html#transaction/2
  - https://hexdocs.pm/ecto/Ecto.Query.html#lock/3
  - https://www.postgresql.org/docs/current/explicit-locking.html
  - https://www.postgresql.org/docs/current/sql-select.html
  - https://hexdocs.pm/oban/periodic_jobs.html
  - https://hexdocs.pm/oban/unique_jobs.html

## WHAT DOCS RECOMMEND NOW

- Reservations must be concurrency-safe, idempotent, and expiring.
- Availability must be server-side and derived as `stock_on_hand - reserved_count`.
- Reserve and consume flows must be replay-safe and deterministic under concurrency.
- Expiry cleanup should run in workers with bounded, lock-safe batches.

## DECISIONS TAKEN (PINS)

- Minimal foundation this phase:
  - add `Store.Catalog` with `Catalog.InventoryItem`
  - add `Store.Orders.InventoryReservation`
- Reservation identity is unique on `(order_id, variant_id)` with deterministic key:
  - `reservation_key = "order:<order_id>:sku:<variant_id>"`
- Reserve semantics are set-to-desired quantity per order+variant:
  - `delta = desired_qty - existing_qty`
  - `delta > 0` requires `available >= delta`, then increment `reserved_count` by `delta`
  - `delta < 0` decrements `reserved_count` by `abs(delta)`
  - `delta == 0` is NOOP
- Multi-item reserve is all-or-nothing (single transaction rollback on any failure).
- Lock acquisition order is pinned:
  - lock inventory rows first in deterministic variant UUID raw16 order
  - apply reservation changes in the same order
- Lifecycle transitions:
  - `active -> consumed` allowed once; replay NOOP
  - `active -> expired` allowed only when expired; replay NOOP
  - `active -> cancelled` allowed; replay NOOP
  - `expired -> consumed` forbidden
  - `consumed -> expired/cancelled` forbidden

## PLAN

1. Add catalog domain + inventory item resource and reservation resource with migration/indexes.
2. Implement reserve flow with deterministic lock order, delta idempotency, and error mapping.
3. Implement consume flow for paid orders with exactly-once counter behavior.
4. Implement expiry worker with periodic schedule, uniqueness window, and skip-locked batches.
5. Add governance tests for concurrency/idempotency/quantity adjustment/expiry/consume/forbidden transitions.
6. Run `mix check` and close Phase 11 beads with gate evidence.

## DONE

- Created Phase 11 parent/child bead fanout (`store_blueprint-7yf.6.*`).
- Added dependency chain and verified no cycles (`bd dep cycles`).
- Added `Store.Catalog` domain and `Store.Catalog.InventoryItem` resource.
- Added `Store.Orders.InventoryReservation` resource + pinned state enum.
- Added migration `20260224201500_phase_11_inventory_reservations.exs` with:
  - inventory table + unique `variant_id`
  - reservation table + unique `(order_id, variant_id)` + unique `reservation_key`
  - active expiry and state indexes
- Added reservation service module `Store.Orders.InventoryReservations` and `Store.Orders` wrappers:
  - `reserve_inventory/3`
  - `consume_reservations_for_order/2`
  - `expire_reservations/2`
- Added expiry worker + scheduling:
  - `Store.Workers.ExpireInventoryReservationsWorker`
  - Oban queue `:inventory`
  - Cron every minute and uniqueness period (`55s`) to reduce overlap.
- Updated governance/uniqueness docs and manifest:
  - `docs/governance/inventory_reservations.md`
  - `Store.Support.Governance.UniquenessRegistry`
- Added governance and worker tests:
  - `test/store/governance/inventory_reservations_test.exs`
  - `test/store/workers/expire_inventory_reservations_worker_test.exs`
- Full `mix check` is passing after implementation/refactor.

## NEXT

- Close remaining Phase 11 beads with final evidence and sync/push protocol.

## BLOCKERS

- None currently.

## COMMANDS RUN

- `bd prime --json`
- `bd ready --json`
- `bd create ...` for `store_blueprint-7yf.6` and child beads
- `bd dep add ...`
- `bd dep cycles`
- `bd update store_blueprint-7yf.6.2 --claim`
- `mix format`
- `mix compile --warnings-as-errors`
- `mix test test/store/governance/inventory_reservations_test.exs`
- `mix test test/store/governance/inventory_reservations_test.exs test/store/workers/expire_inventory_reservations_worker_test.exs`
- `mix check`

## GATES

- `mix check` latest run:
  - custom gates: all pass (`req_usage`, `web_no_http`, `web_no_oban_enqueue`, `no_repo_in_web`, `moduledoc`, `docs_notes`)
  - tests: `119 tests, 0 failures`
  - credo: no issues
  - docs: generated successfully
- Phase 11 acceptance scenarios are enforced via governance tests:
  - concurrent last-unit reserve single winner
  - retry idempotency
  - quantity delta adjustment
  - expiry release exactly once
  - consume replay exactly once
  - expired reservation not consumable

## PERFORMANCE REVIEW

- Hot path:
  - reserve flow under checkout concurrency for overlapping variants.
- Warm path:
  - consume flow on paid transitions.
- Cold path:
  - expiry cleanup scans.
- Indexes:
  - unique inventory key on `variant_id`
  - unique reservation identity on `(order_id, variant_id)` / `reservation_key`
  - active+expiry lookup indexes for worker batch scans
- TTL:
  - reservation TTL default 15 minutes.
- Invalidation:
  - no cache layer in this phase baseline.
- PubSub:
  - no new PubSub fanout in this phase baseline.
