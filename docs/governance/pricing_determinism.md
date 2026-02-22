# Governance: Pricing Determinism & Discount Stacking (Authoritative)
Pricing must be deterministic, repeatable, and auditable. This document pins the rules so client projects cannot drift.

## 1) Money model (MUST)
- All money values are stored as integer **minor units** (e.g., cents).
- Currency is explicit (ISO code string).
- No floats anywhere in pricing, discounts, tax, shipping totals.

## 2) Determinism (MUST)
Given the same inputs (cart lines, quantities, customer eligibility, coupon codes, time), the system MUST produce:
- identical line totals
- identical order totals
- identical discount breakdowns
- identical applied promotion set (after tie-breaks)

No reliance on unordered map iteration. If rule evaluation produces sets/lists, they MUST be canonicalized.

## 3) Canonicalization rules (MUST)
Whenever hashing/signing or ordering for tie-breaks in pricing:
- UUID lists MUST follow Binary UUID Sort Law (raw16 lexicographic).
- When ordering by non-UUID identifiers:
  - normalize to a canonical byte representation
  - use deterministic ascending order

Applied discount list MUST be ordered deterministically for storage and UI:
1) primary key (uuid) sorted by binary sort
2) if no uuid, stable code string uppercase sorted by bytes

## 4) Rounding & allocation rules (MUST)
### 4.1 Rounding
- All computed monetary results must be integers.
- When dividing or allocating, use:
  - **round half up** at the smallest possible point (minor unit)
  - never bankers rounding unless explicitly opted-in

### 4.2 Allocation (discount distribution across line items)
If an order-level discount is applied:
- Allocate across eligible line items proportionally by pre-discount line totals.
- Resolve remainder pennies deterministically:
  1) sort eligible line item ids by UUID binary sort
  2) distribute +1 minor unit to earliest items until remainder is zero

This prevents “penny leaks” and makes totals sum exactly.

## 5) Discount stacking policy (MUST)
You must declare a stacking model. This blueprint pins a conservative default:

### 5.1 Discount types
- coupon: code-based discount
- promotion: rule-based discount (auto)
- manual_adjustment: admin-only additive correction (rare)

### 5.2 Default stacking rules (MUST)
- At most **one coupon** may apply per order (unless pack overrides).
- Promotions may be:
  - **exclusive** (cannot stack with other promotions)
  - **combinable** (may stack with combinable promotions)
- If multiple exclusive promotions match, select ONE using deterministic tie-break:
  1) highest absolute discount amount (computed deterministically)
  2) if tie: lowest UUID (binary sort)
  3) if still tie: earliest created_at (if available), else stable fallback

### 5.3 Coupon + promotion interaction (default)
- Coupon may stack with combinable promotions only.
- Coupon does not stack with exclusive promotions unless explicitly configured.

## 6) Time & eligibility (MUST)
- Pricing evaluation MUST accept an explicit `as_of` timestamp input.
- Coupon validity and promotion windows are evaluated against `as_of`, not `DateTime.utc_now()` scattered in code.
- Customer eligibility must be explicit input (actor roles, flags).

## 7) Evidence storage (MUST)
Orders must store:
- snapshot unit prices
- snapshot totals
- list of applied discounts/promotions with deterministic ordering
- discount allocation per line item (if applicable)

No recomputing history.

## 8) Error semantics (MUST)
- INVALID_COUPON: invalid/expired/ineligible coupon
- VALIDATION_ERROR: insufficient/invalid inputs
- FORBIDDEN: attempting to apply admin-only adjustments without role

## 9) Test gates (MUST)
1) Determinism: running pricing evaluation N times yields identical results.
2) Allocation: discounts allocate without penny leak (sum matches exactly).
3) Tie-breaks: identical discount outcomes select the same promotion consistently.
4) Stacking: exclusive vs combinable enforced as pinned above.
5) Canonical ordering: applied discounts stored in deterministic order.

## 10) Drift protocol (MUST)
If a client wants different stacking rules or rounding:
- Update this doc first
- Add/adjust test gates
- Then change implementation

No doc update = no behavior change.
