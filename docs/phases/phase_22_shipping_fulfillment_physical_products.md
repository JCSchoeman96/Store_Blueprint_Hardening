# Phase 22 — Shipping & Fulfillment (Physical Products)

## Goal

Turn the blueprint into a **real, end-to-end physical-goods store** by adding:

- deterministic **shipping configuration + rate quoting**
- checkout-time **shipping selection + snapshotting**
- post-payment **fulfillment workflow** (pack → ship → deliver) with replay safety

This phase **does not** add carrier integrations (CourierGuy, etc.) yet — it creates the internal spine so carriers are a Phase 23+ plug-in.

---

## Outcomes (Definition of Done)

1. Admin can manage:
   - shipping zones (where we ship)
   - shipping methods (how we ship)
   - shipping rate rules (what it costs)
2. Checkout can:
   - quote shipping options deterministically
   - accept a chosen option
   - snapshot shipping into the Order (so later rule changes do not alter past orders)
3. After payment is confirmed (via the existing interlock flow), the system can:
   - create a fulfillment record exactly once
   - progress fulfillment state via admin actions
4. Customer can view fulfillment/shipment status for their own orders.

---

## Scope

### In scope
- Flat-rate / table-rate shipping (zone + method + rules)
- Address capture (shipping address, basic validation)
- Deterministic shipping quote + rounding
- Fulfillment + shipment state machines
- Admin CRUD via **AshPhoenix.Form** (Phase 16 pattern)
- Replay-safe fulfillment creation via worker/interlock (Phase 14 pattern)

### Explicitly out of scope (Phase 23+)
- Carrier API integrations (real-time rates, label buying)
- Multi-package splitting / dimensional weight
- International duties & customs
- Returns/RMAs beyond refund semantics already in Phase 12

---

## Domain Map

### New domains
- `Store.Shipping` — configuration + quoting
- `Store.Fulfillment` — post-payment operations

> Keep Orders/Payments unchanged. Shipping/Fulfillment must plug into the existing checkout interlocks without introducing product-type branching inside Orders.

---

## Resources

### Store.Shipping

#### `Store.Shipping.ShippingZone`
Represents a geographic zone used for quoting (e.g., “Gauteng”, “National”, “Local Pickup”).

**Key fields**
- `name` (string, unique)
- `country_code` (string, ISO 3166-1 alpha-2; default “ZA”)
- `rules_json` (map) — minimal v1: list of allowed provinces/postcode prefixes

**Actions**
- `create`, `update`, `archive` (no hard delete)
- `read` (admin)
- `read_public` (optional, only needed if you expose zone names)

**Indexes**
- unique index on `name`

#### `Store.Shipping.ShippingMethod`
Represents a selectable method (e.g., “Door-to-Door”, “PUDO Locker”, “Collection”).

**Key fields**
- `code` (string, unique, stable identifier)
- `name` (string)
- `is_active` (boolean)
- `sort_order` (integer)
- `requires_address` (boolean) (e.g., “Collection” = false)

**Actions**
- `create`, `update`, `activate`, `deactivate`
- `read_admin`

**Indexes**
- unique index on `code`
- index on `is_active`

#### `Store.Shipping.ShippingRateRule`
Represents a rate rule for a (zone, method). Keep v1 simple and deterministic.

**Key fields**
- `shipping_zone_id` (uuid)
- `shipping_method_id` (uuid)
- `min_weight_grams` (integer, >= 0)
- `max_weight_grams` (integer, >= min)
- `price_cents` (integer, >= 0)
- `currency_code` (string, ISO 4217, default “ZAR”)
- `is_active` (boolean)
- `effective_from` / `effective_to` (optional for future)

**Invariants**
- For a given (zone, method), active rules must not overlap weight ranges.

**Actions**
- `create`, `update`, `deactivate`
- `read_admin`

**Indexes**
- index on `(shipping_zone_id, shipping_method_id, is_active)`
- index on `(shipping_zone_id, is_active)`

#### Quoting surface (do not expose raw Ash.Query in web)
Introduce a domain facade function:

- `Store.Shipping.quote_options(actor, %Store.Shipping.QuoteRequest{}) :: {:ok, [QuoteOption.t()]}`

Where `QuoteRequest` includes:
- destination (country/province/postcode)
- cart/order draft weight in grams
- currency code

And `QuoteOption` includes:
- `method_code`
- `label`
- `amount_cents`
- `currency_code`
- `quote_hash` (deterministic hash of the option fields + rules version)

> The web layer must only transform params → `QuoteRequest`. No inline filters/loads.

---

### Store.Fulfillment

#### `Store.Fulfillment.FulfillmentOrder`
Operational record created after payment success.

**Key fields**
- `order_id` (uuid, unique) — exactly one fulfillment per order (v1)
- `state` (atom): `:pending` | `:packed` | `:shipped` | `:delivered` | `:canceled`
- `shipping_method_code` (string)
- `shipping_address_snapshot` (map) — immutable snapshot from checkout
- `notes` (string, optional)

**Actions**
- `create_from_paid_order` (internal-only; called from worker)
- `mark_packed`
- `mark_shipped` (requires tracking ref)
- `mark_delivered`
- `cancel` (admin-only)

**State machine rules**
- `pending -> packed -> shipped -> delivered`
- `pending -> canceled`
- `packed -> canceled` (optional, but avoid after shipped)

**Policies**
- Only admin can transition states
- Customer can `read` fulfillment for their own orders

**Indexes**
- unique index on `order_id`
- index on `state`

#### `Store.Fulfillment.Shipment`
Optional in v1, but recommended to avoid future churn.

**Key fields**
- `fulfillment_order_id` (uuid)
- `carrier` (string, optional)
- `tracking_ref` (string, optional, unique when present)
- `state` (atom): `:created` | `:in_transit` | `:delivered` | `:canceled`

**Actions**
- `create_for_fulfillment`
- `set_tracking_ref`
- `mark_in_transit`
- `mark_delivered`
- `cancel`

> If you want minimal v1, you can embed `tracking_ref` on `FulfillmentOrder` instead and add `Shipment` in Phase 23. But adding it now makes carrier integrations cleaner later.

---

## Checkout Integration (Snapshot Discipline)

### Shipping selection at checkout
During checkout, once the user chooses a quote option:

1. Persist the chosen option into the Order as a **snapshot**:
   - create an `OrderAdjustment` of type `:shipping`
   - store:
     - `amount_cents`
     - `currency_code`
     - `shipping_method_code`
     - `quote_hash`
     - `shipping_address_snapshot`
2. Totals must remain deterministic:
   - shipping amount becomes part of the order total snapshot
   - later changes to shipping rules **must not** affect existing orders

### Fulfillment creation timing
Fulfillment must only be created after the payment success interlock marks the order paid.

- Worker path: `ProcessWebhookReceiptWorker` (or equivalent) triggers:
  - `Store.Fulfillment.ensure_fulfillment_for_paid_order(order_id)` (idempotent)
- Must be replay-safe (unique index on `fulfillment_orders.order_id` + reuse semantics).

---

## Admin UI (AshPhoenix.Forms)

Implement admin CRUD for:
- zones
- methods
- rate rules

and an admin fulfillment queue:
- list paid orders with no fulfillment yet (via domain surface)
- list fulfillments by state
- transition actions via AshPhoenix.Form submit (no direct Ash calls in LiveView)

---

## Tests (Minimum)

### Shipping
- **Deterministic quoting**
  - same request → same options + same `quote_hash` ordering
- **No overlapping active rules**
  - create overlapping ranges must be rejected
- **Snapshot integrity**
  - changing rules does not alter existing order shipping adjustment

### Fulfillment
- **Paid-only creation**
  - cannot create fulfillment for unpaid order
- **Idempotent creation**
  - calling ensure twice results in one record
- **State machine**
  - invalid transitions fail with explicit error codes

---

## Performance & Scaling Review

Even single-tenant stores see spikes.

- Hot data: cache active shipping rules in ETS/Cachex (TTL 30–300s)
- Warm data: Redis optional if you anticipate high read concurrency
- Cold data: Postgres is source of truth
- Invalidation triggers:
  - admin updates shipping zones/methods/rules → bust cache keys
- Avoid DB chatter:
  - quote flow should be one read (rules) + pure compute, not multiple joins per request

---

## Governance Impact

No new global governance docs are required **if you follow existing laws**:
- web remains adapter-only
- checkout snapshots are immutable
- side effects run in workers

However, this phase does introduce one implicit invariant you must keep:
- **Shipping amount must be snapshotted into `OrderAdjustment` at checkout** (no “recompute later”).

If you later add carrier APIs, add a governance doc for outbound carrier IO quarantine (Phase 23+).
