# STORE_BLUEPRINT_EXTRACTION_DECISION_V1

Version: 1.0  
Decision owner: Planning / Architecture  
Decision status: Accepted for v0.2 planning — v1.0-draft-approved-with-amendments  
Last reviewed: 2026-05-25  
Supersedes: none  
Applies to: Voelgoed v0.2 planning only  
Scope: Store_Blueprint extraction decision for Voelgoed digital ecosystem v0.2  
Mode: No code changes. No blind fork. No implementation authority.

## Not Implementation Authority

This document SHALL NOT authorize copying Store_Blueprint modules.

This document authorizes planning classification only.

Each Store_Blueprint module extraction still requires a focused extraction decision:

```text
KEEP / RENAME / REWRITE / REJECT
```

Each focused extraction decision MUST include:

```text
source assumptions
target Voelgoed assumptions
required edits
forbidden inherited behaviour
tests required
slice supported
```

No implementation agent SHALL treat this document as permission to port code.

---

## Binding Context

Store_Blueprint SHALL be treated as a reference implementation and selective extraction source.

Store_Blueprint MUST NOT be forked and expanded blindly into the broader Voelgoed ecosystem.

Voelgoed v0.2 SHALL remain limited to the Join Vriendinneklub path:

```text
VS-001A: Visitor registers account
VS-002A: Vriendinneklub offer + price exists
VS-002B: Registered user creates pending join order
VS-002C: System records payment event idempotently
VS-002D: Paid order activates membership and creates entitlement grants
VS-002E: System evaluates member access from entitlement grants
```

Voelgoed v0.2 MUST NOT include Events, Learning, Competitions, Media, Community, bundles, coupon stacking, full refunds, full shipping, full tax, organiser marketplace semantics, or broad catalog expansion.

---

## Classification Legend

- **REUSE AS-IS CONCEPTUALLY**: The rule or pattern SHALL be adopted, but module names and project namespace still require Voelgoed-specific implementation.
- **REUSE WITH CHANGES**: The Store_Blueprint concept is useful, but assumptions MUST be changed before reuse.
- **EXTRACT LATER**: The area MAY be reused after v0.2, but MUST NOT block Join Vriendinneklub.
- **DEFER / REJECT FOR v0.2**: The area SHALL NOT be included in Voelgoed v0.2, but MAY be reconsidered after a later workflow and domain grill.
- **DO NOT INHERIT BLINDLY**: The area contains useful code/patterns, but carries assumptions that could corrupt the Voelgoed domain model.
- **REWRITE FOR VOELGOED**: Store_Blueprint does not provide the correct source model; Voelgoed MUST define the resource/action from its own workflows.

---

## 1. AGENTS.md governance rules

Classification: **REUSE AS-IS CONCEPTUALLY**

### Why it matters

AGENTS.md defines the operational law that keeps coding agents from bypassing domain boundaries.

### What Store_Blueprint assumes

Store_Blueprint assumes Ash 3.x, Phoenix, LiveView, single tenancy, no marketplace semantics, domain facades, strict web boundaries, integer minor-unit money, UUIDv7 IDs, webhook ingress-only controllers, and Oban/domain-led side effects.

### What Voelgoed v0.2 needs

Voelgoed v0.2 needs the same boundary discipline for Join Vriendinneklub.

### What MUST change before reuse

- Store-specific names MUST be renamed to Voelgoed-specific names.
- Single-tenancy language MUST be reviewed against future organiser portal decisions.
- UI-specific rules such as component library choices MUST be revalidated.

### What MUST NOT be inherited

- Voelgoed MUST NOT inherit Store-specific no-marketplace assumptions as permanent law until organiser ownership is decided.
- Voelgoed MUST NOT inherit Store-specific module names or OTP app names.

### v0.2 slice support

Supports all v0.2 slices.

---

## 2. mix check / governance gates

Classification: **REUSE AS-IS CONCEPTUALLY**

### Why it matters

Governance gates make agent drift detectable before merge.

### What Store_Blueprint assumes

Store_Blueprint assumes gates for formatting, compile warnings, dependency audit, docs, tests, web boundary violations, direct Ash calls in web, Repo usage in web, API discipline, and docs sync.

### What Voelgoed v0.2 needs

Voelgoed v0.2 needs gates that prove web layers stay adapter-only and business truth stays in Ash resources/actions/domain facades.

### What MUST change before reuse

- Gate module names MUST be renamed.
- Gate scopes MUST match the Voelgoed directory structure.
- v0.2 planning validator gates MUST be added for resource/action/slice readiness.

### What MUST NOT be inherited

- Store-specific docs sync gates MUST NOT be inherited unless the equivalent Voelgoed docs exist.
- Any gate tied to Store-only domains MUST NOT block Voelgoed v0.2.

### v0.2 slice support

Supports all v0.2 slices.

---

## 3. Accounts

Classification: **REUSE WITH CHANGES**

### Why it matters

Join Vriendinneklub requires a registered user before membership activation and entitlement grants can be tied to a person.

### What Store_Blueprint assumes

Store_Blueprint assumes e-commerce user accounts inside a Store namespace, with admin/support role patterns.

### What Voelgoed v0.2 needs

Voelgoed v0.2 needs account registration, sign-in, unique email identity, actor context, and member ownership of membership/grants.

### What MUST change before reuse

- Account language MUST be reframed for Voelgoed users and members.
- Roles MUST be mapped to Voelgoed actors.
- Registration flow MUST be aligned with VS-001A.

### What MUST NOT be inherited

- Store admin/support roles MUST NOT be copied without an actor matrix.
- Checkout-specific account assumptions MUST NOT leak into general membership identity.

### v0.2 slice support

Supports VS-001A, VS-002B, VS-002D, VS-002E.

---

## 4. Orders

Classification: **REUSE WITH CHANGES**

### Why it matters

Join Vriendinneklub requires a durable commercial record before payment and membership activation.

### What Store_Blueprint assumes

Store_Blueprint assumes a full e-commerce order lifecycle, order refs, line items, adjustments, payment applications, inventory reservations, and refund adjustments.

### What Voelgoed v0.2 needs

Voelgoed v0.2 needs only a minimal order lifecycle for one membership purchase path.

Required v0.2 order states SHALL be limited unless explicitly expanded:

```text
pending_payment
paid
cancelled
expired
```

Failed payment SHALL be recorded on `Payment` / `PaymentEvent`.

`Order` MAY remain `pending_payment` after failed payment until it is retried, expired, or cancelled.

If Voelgoed later requires an explicit order-level failure state, `payment_failed` MUST be added through a state-transition patch before coding.

### What MUST change before reuse

- Order resources MUST be reduced to v0.2 scope.
- Inventory reservation assumptions MUST be removed.
- Refund-adjustment behaviour MUST be deferred.
- Order ownership MUST be locked to the Voelgoed platform for v0.2.
- Failed-payment behaviour MUST be explicit in the state-transition map.

### What MUST NOT be inherited

- Inventory reservation logic MUST NOT be inherited for membership purchase.
- Full refund implementation MUST NOT be inherited in v0.2.
- Shipping/tax-coupled order behaviour MUST NOT be inherited.
- Failed payment MUST NOT implicitly activate, cancel, or expire an order unless a named action does so.

### v0.2 slice support

Supports VS-002B, VS-002C, VS-002D.

---

## 5. OrderLineItem snapshots

Classification: **REUSE AS-IS CONCEPTUALLY**

### Why it matters

Membership purchase history MUST preserve the exact price paid.

### What Store_Blueprint assumes

Store_Blueprint assumes deterministic pricing and line-item snapshots for order correctness.

### What Voelgoed v0.2 needs

Voelgoed v0.2 needs `OrderItem` to snapshot the Vriendinneklub offer, price, currency, and membership fulfilment target at order creation.

### What MUST change before reuse

- Snapshot fields MUST be reduced to membership purchase needs.
- Product/variant snapshot fields MUST be replaced or made optional if not used.

### What MUST NOT be inherited

- Variant inventory fields MUST NOT be required for membership line items.
- Coupon/promotion/tax/shipping snapshot complexity MUST NOT be inherited in v0.2.

### v0.2 slice support

Supports VS-002B and VS-002D.

---

## 6. Payments / PaymentEvent / WebhookReceipt

Classification: **REUSE WITH CHANGES**

### Why it matters

Payment confirmation MUST be idempotent and MUST NOT activate membership from an untrusted return URL.

### What Store_Blueprint assumes

Store_Blueprint assumes payment intents, payment attempts, provider events, webhook receipts, provider adapters, refunds, and webhook-worker separation.

### What Voelgoed v0.2 needs

Voelgoed v0.2 needs:

- `Payment`
- `PaymentEvent`
- optional `WebhookReceipt` if external webhook verification is included
- deterministic idempotency key
- payment success applied once
- membership activation triggered after trusted payment success

PaymentEvent SHALL be the idempotency source.

Payment return/cancel SHALL be read-only.

Membership activation SHALL occur only after a trusted payment event is processed.

Failed payment SHALL be recorded on `Payment` / `PaymentEvent` and MUST NOT directly mutate membership or entitlement grants.

### What MUST change before reuse

- Provider assumptions MUST be locked for v0.2.
- PayFast/Yoco/Paystack/Peach readiness MUST be proven before production use.
- Payment domain MUST be reduced to the Join Vriendinneklub path.
- PaymentEvent uniqueness MUST be defined from provider event ID or deterministic local idempotency key.

### What MUST NOT be inherited

- Scaffold-only providers MUST NOT be treated as production-ready.
- Refund processing MUST NOT be inherited for v0.2.
- Payment return/cancel handlers MUST NOT mutate payment, order, membership, or grant state.
- Payment code MUST NOT create entitlement grants directly.

### v0.2 slice support

Supports VS-002C and VS-002D.

---

## 7. Subscriptions

Classification: **EXTRACT LATER**

### Why it matters

Vriendinneklub may eventually require recurring billing, renewal attempts, stored payment methods, and access-on-cancel policy.

### What Store_Blueprint assumes

Store_Blueprint assumes subscription plans, variant subscription plans, stored payment methods, subscriptions, subscription items, and renewal attempts.

### What Voelgoed v0.2 needs

Voelgoed v0.2 does not need full subscription machinery unless recurring billing is explicitly locked.

### What MUST change before reuse

- Recurring Vriendinneklub billing MUST be approved as a planning decision.
- Subscription states MUST be mapped to membership states.
- Renewal idempotency and payment provider support MUST be proven.

### What MUST NOT be inherited

- SubscriptionPlan MUST NOT replace MembershipPlan without a domain decision.
- VariantSubscriptionPlan MUST NOT be inherited for membership offers.
- StoredPaymentMethod MUST NOT be introduced unless off-session billing is required.

### v0.2 slice support

No direct v0.2 support unless recurring billing is explicitly locked.

---

## 8. EntitlementGrant

Classification: **REUSE WITH CHANGES**

### Why it matters

Join Vriendinneklub needs durable access grants created after membership activation.

### What Store_Blueprint assumes

Store_Blueprint assumes `EntitlementGrant` is derived from subscription lifecycle and defaults the source kind toward subscription-derived access.

### What Voelgoed v0.2 needs

Voelgoed v0.2 needs:

- `BenefitRule` as the rule source
- `EntitlementGrant` as the persisted grant
- `Memberships.evaluate_entitlement_access` as the read-side evaluation action
- grants derived from membership activation, not necessarily subscription renewal

### What MUST change before reuse

- `source_kind` MUST support membership activation / benefit rule source.
- Grant uniqueness MUST include user, benefit scope, source kind, and source ID.
- Status and validity windows MUST match membership lifecycle.

### What MUST NOT be inherited

- EntitlementGrant MUST NOT become a generic permission system.
- Subscription-only assumptions MUST NOT control Vriendinneklub access.
- Web/UI code MUST NOT create grants directly.

### v0.2 slice support

Supports VS-002D and VS-002E.

---

## 9. BenefitRule

Classification: **REWRITE FOR VOELGOED**

### Why it matters

BenefitRule is the rule source that defines what an active MembershipPlan grants.

### What Store_Blueprint assumes

Store_Blueprint does not provide a Voelgoed-specific BenefitRule source model. Store entitlement behaviour is tied to subscription-derived access patterns.

### What Voelgoed v0.2 needs

Voelgoed v0.2 needs `BenefitRule` to define what a Vriendinneklub MembershipPlan grants.

BenefitRule SHALL be the rule source used to create `EntitlementGrant` records.

BenefitRule MUST be explicit, persisted, and connected to `MembershipPlan`.

### What MUST change before reuse

- BenefitRule MUST be designed from the Voelgoed membership workflow, not inferred from Store subscriptions.
- BenefitRule MUST define grant kind, scope key, validity rule, and source MembershipPlan.
- BenefitRule MUST have tests proving grants are created exactly once after membership activation.

### What MUST NOT be inherited

- BenefitRule MUST NOT be inferred from SubscriptionPlan.
- BenefitRule MUST NOT be hidden inside pricing, checkout, payment, or admin UI code.
- BenefitRule MUST NOT become a generic marketing-benefit prose field.

### v0.2 slice support

Supports VS-002A, VS-002D, and VS-002E.

---

## 10. Catalog / Product / Variant / Inventory

Classification: **DO NOT INHERIT BLINDLY**

### Why it matters

The store catalog can corrupt the Voelgoed model if memberships, events, learning, and content are forced into product/variant/inventory shapes.

### What Store_Blueprint assumes

Store_Blueprint assumes products, variants, product options, option values, images, categories, and inventory items.

### What Voelgoed v0.2 needs

Voelgoed v0.2 needs only:

- `Offer`
- `Price`

These SHALL support only Vriendinneklub membership purchase in v0.2.

### What MUST change before reuse

- Product/Variant MUST be replaced by or narrowed behind `Offer` + `Price` for membership purchase.
- Inventory MUST be excluded.
- Product lifecycle MUST NOT become the default lifecycle for memberships.

### What MUST NOT be inherited

- Product, Variant, ProductOption, VariantOptionSelection, ProductImage, and InventoryItem MUST NOT be required for Join Vriendinneklub.
- Generic catalog expansion MUST NOT enter v0.2.

### v0.2 slice support

Supports VS-002A only if reduced to Offer + Price. Full Catalog does not support v0.2.

---

## 11. Pricing

Classification: **REUSE WITH CHANGES**

### Why it matters

OrderItem snapshots require deterministic pricing.

### What Store_Blueprint assumes

Store_Blueprint assumes coupons, promotions, tax rates, shipping-aware pricing, eligibility, and deterministic evaluation.

### What Voelgoed v0.2 needs

Voelgoed v0.2 needs one active Vriendinneklub price and deterministic snapshotting into an order item.

### What MUST change before reuse

- Pricing MUST be reduced to fixed membership price lookup and snapshot.
- Coupon stacking MUST be excluded.
- Promotion logic MUST be excluded.
- Tax/shipping pricing MUST be excluded unless legally required and explicitly decided.

### What MUST NOT be inherited

- Coupon resources MUST NOT enter v0.2.
- Promotion resources MUST NOT enter v0.2.
- Shipping/tax evaluator MUST NOT enter v0.2 by default.

### v0.2 slice support

Supports VS-002A and VS-002B.

---

## 12. Checkout

Classification: **DO NOT INHERIT BLINDLY**

### Why it matters

Checkout orchestrates customer purchase flow, but Store_Blueprint checkout includes cart, shipping, tax, subscriptions, and order finalization assumptions.

### What Store_Blueprint assumes

Store_Blueprint assumes cart-backed checkout, checkout drafts, shipping inputs, totals finalization, tax/shipping quote handling, and subscription-line detection.

### What Voelgoed v0.2 needs

Voelgoed v0.2 needs a narrow join flow:

```text
selected offer + price
→ pending order
→ payment event
→ paid order
→ membership activation
→ entitlement grants
```

### What MUST change before reuse

- CheckoutDraft complexity MUST be deferred unless proven necessary.
- Cart dependency MUST be removed for single membership purchase.
- Shipping/tax/subscription dependencies MUST be removed from v0.2 join flow.

### What MUST NOT be inherited

- Cart-first checkout MUST NOT be required for Join Vriendinneklub.
- Shipping steps MUST NOT appear in membership checkout.
- Totals finalization MUST NOT depend on product/variant/cart semantics.

### v0.2 slice support

Supports VS-002B only as a reference pattern, not as a direct extraction.

---

## 13. Fulfillment

Classification: **EXTRACT LATER**

### Why it matters

Future purchases may need fulfilment dispatch for products, digital downloads, courses, tickets, and memberships.

### What Store_Blueprint assumes

Store_Blueprint assumes fulfilment as a post-payment operational domain.

### What Voelgoed v0.2 needs

Voelgoed v0.2 does not require a generic fulfilment domain. Membership activation and grant creation SHALL be explicit Memberships actions.

### What MUST change before reuse

- Fulfilment MUST be split by fulfilment target before reuse.
- Membership activation MUST NOT be hidden behind generic fulfilment dispatch in v0.2.

### What MUST NOT be inherited

- Generic fulfilment dispatch MUST NOT obscure membership activation rules.
- Product fulfilment assumptions MUST NOT apply to Vriendinneklub.

### v0.2 slice support

No direct support. Deferred.

---

## 14. Digital downloads

Classification: **EXTRACT LATER**

### Why it matters

Voelgoed may later sell or grant protected files, replays, PDFs, and downloads.

### What Store_Blueprint assumes

Store_Blueprint assumes download grants, signed URLs, access-controlled files, and worker-safe counters/revocation.

### What Voelgoed v0.2 needs

Voelgoed v0.2 only needs membership access evaluation, not file delivery.

### What MUST change before reuse

- Digital downloads MUST be mapped to Voelgoed content/access workflows.
- DownloadGrant MUST remain separate from EntitlementGrant.

### What MUST NOT be inherited

- Digital downloads MUST NOT become the general Content or Learning domain.
- Direct file access MUST NOT bypass entitlement evaluation.

### v0.2 slice support

No direct support. Deferred.

---

## 15. Admin surfaces

Classification: **DO NOT INHERIT BLINDLY**

### Why it matters

Admin surfaces define operational power and can accidentally bypass domain rules.

### What Store_Blueprint assumes

Store_Blueprint assumes Store admin/support roles, Store admin LiveViews, and Store-specific admin workflows.

### What Voelgoed v0.2 needs

Voelgoed v0.2 needs only minimal admin/system capability to define Vriendinneklub offer, price, membership plan, and benefit rules.

### What MUST change before reuse

- Admin roles MUST be defined in the Voelgoed actor matrix.
- Admin actions MUST call domain actions only.
- Admin surfaces MUST be slice-scoped.

### What MUST NOT be inherited

- Store admin screens MUST NOT be ported wholesale.
- Admin UI MUST NOT become the source of business truth.
- Support roles MUST NOT mutate memberships/payments unless explicitly authorized.

### v0.2 slice support

Supports VS-002A only after redesign.

---

## 16. Shipping / Tax

Classification: **DEFER / REJECT FOR v0.2**

### Why it matters

Shipping and tax may matter for physical products later, but they do not belong in the first membership purchase slice unless legally required.

### What Store_Blueprint assumes

Store_Blueprint assumes shipping zones, shipping rates, tax rates, tax/shipping evaluators, and quote evidence.

### What Voelgoed v0.2 needs

Voelgoed v0.2 does not need shipping. Tax/VAT treatment MUST be captured as an accounting/legal decision, but full tax engine reuse is out of scope for v0.2.

### What MUST change before reuse

- Physical product workflows MUST be planned before shipping reuse.
- VAT/tax requirements MUST be legally/accounting reviewed before tax engine reuse.
- Any later tax implementation MUST be introduced through a dedicated tax/accounting planning decision.

### What MUST NOT be inherited

- Shipping resources MUST NOT enter Join Vriendinneklub.
- Tax/shipping snapshot complexity MUST NOT be required for v0.2.
- The v0.2 order model MUST NOT depend on shipping or tax resources.

### v0.2 slice support

No v0.2 support.

---

## Final Extraction Decision

Voelgoed SHALL NOT fork Store_Blueprint as the implementation baseline.

Voelgoed SHALL use Store_Blueprint as:

```text
reference implementation
selective extraction source
governance source
payment/idempotency pattern source
Ash boundary pattern source
```

Voelgoed v0.2 SHALL be implemented from Voelgoed resource cards, action cards, slice packs, and validator rules.

No Store_Blueprint module SHALL be copied until it receives a focused extraction decision:

```text
KEEP / RENAME / REWRITE / REJECT
```

Each extraction decision MUST include:

```text
source assumptions
target Voelgoed assumptions
required edits
forbidden inherited behaviour
tests required
slice supported
```
