# Governance: Immutable Snapshots (Authoritative)
Orders are evidence. Once created, line items and adjustments become immutable snapshots.

## 1) Scope (MUST)
These resources are snapshot evidence and MUST be immutable after creation:
- Orders.OrderLineItem
- Orders.OrderAdjustment
Optionally (recommended):
- Orders.OrderSnapshot (if you store a JSON blob)

## 2) Rules (MUST)
1) Snapshot resources MUST expose **create** and **read** actions only.
2) Snapshot resources MUST NOT expose update or destroy actions.
3) Policies MUST deny any mutation other than create.
4) If a correction is needed, it MUST be represented as:
   - a new OrderAdjustment (e.g., manual_credit/manual_debit) OR
   - a refund flow that produces new evidence (Payments + Order status transition)
   Never by editing historical snapshots.

## 3) Order-level mutability boundaries (MUST)
Orders.Order itself may transition state (pending_payment -> paid -> refunded), but:
- snapshot totals must remain stable once paid (no recomputation)
- any new adjustments must be additive evidence (e.g., refund adjustment record)

## 3.1) Denormalized snapshot evidence (Phase 10+ MUST)
To keep snapshots self-contained for audits and support workflows, line-item snapshots should carry denormalized evidence fields once catalog/pricing resources are available. At minimum, pin:
- `sku_snapshot` (or stable variant/sku code)
- `product_title_snapshot`
- `variant_title_snapshot` (if variants exist)
- optional descriptors needed for deterministic customer-facing rendering and historical evidence

Do not rely on joining mutable catalog records to reconstruct historical line-item evidence.

## 4) DB hardening (SHOULD)
Add database guards (optional but recommended):
- trigger to reject UPDATE/DELETE on order_line_items and order_adjustments
- or DB permissions that disallow UPDATE/DELETE except via migrations/DB admin

If DB hardening is not used, Ash action absence MUST be the mechanical enforcement.

## 5) Enforcement gates (MUST)
- Add a test gate that asserts snapshot resources do not define update/destroy actions.
- Add a Phase 09 test proving snapshot read paths return stored evidence values and do not recompute totals.
- Add a "product price change does not mutate historical totals" gate once catalog/pricing resources and pricing evaluation actions exist (Phase 10+ dependency).

## 6) Error semantics (MUST)
Attempting to mutate snapshots must fail with:
- FORBIDDEN (policy) OR
- VALIDATION_ERROR (if blocked by a validation)
Do not return generic errors without stable codes.

## 7) Drift protocol (MUST)
If a project wants mutable order lines, it’s not the same blueprint.
Fork the blueprint and update this doc + tests. No silent exceptions.
