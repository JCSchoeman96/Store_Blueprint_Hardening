# Governance: Policy Matrix (Authoritative)
This document pins **who can do what**. If it isn’t here, it MUST be denied by default.

## 1) Roles (single-tenant baseline)
- super_admin: full control (still audited)
- admin: manage business data (catalog/pricing/orders/payments) but not root security operations unless explicitly allowed
- editor: manage content only (posts/categories/tags)
- support: customer support operations (read-only + limited tools), never pricing configuration, never provider configuration, never refunds without step-up and explicit allow
- customer: self-service only (their own orders/profile)

## 2) Enforcement rules (MUST)
1) **Deny-by-default** for all non-read actions unless explicitly allowed below.
2) Authorization MUST be enforced at the **Ash policy** layer (not just LiveView routes).
3) Web routes MUST be thin gates; policies are the real enforcement.
4) Failures MUST return stable error codes:
   - UNAUTHORIZED (not logged in)
   - FORBIDDEN (logged in, but not allowed)
   - STEP_UP_REQUIRED (sensitive op without recent step-up)
5) Support role MUST NOT become “shadow admin”. If you need a support-only mutation, define it explicitly below.
6) Visibility constraints MUST be filter-based where possible (row-scoping in query/policy filter). Runtime checks are allowed only for non-row-scoping constraints (for example role gates and step-up gates).

## 3) Global “own-data” rule (customer)
Customers may only read and mutate records they own:
- Orders where order.user_id == actor.id
- User profile where user.id == actor.id
This rule MUST be implemented in resource policies.

## 4) Step-up rule (MUST)
Step-up is required for:
- refunds (initiating and executing)
- payment provider configuration changes
- payout/bank detail changes (if present)

Default window: 15 minutes.
`step_up_at` MUST be set by trusted server-side step-up completion only (reauth/MFA boundary), injected into Ash context, and denied if absent/stale.
See `docs/governance/step_up.md`.

## 4.1 Data/index requirements (MUST)
- `orders.user_id` MUST be indexed for own-data policy reads.

---

## 5) Policy Matrix (Pinned)

Legend:
- R = read/list
- C = create
- U = update
- D = destroy
- X = special action (named)

### 5.1 Accounts (Accounts.User, Accounts.UserSecurityEvent)
| Resource | Action | super_admin | admin | editor | support | customer |
|---------|--------|-------------|-------|--------|---------|----------|
| User | R(list/read) | YES | YES | NO | LIMITED* | SELF** |
| User | U(update) | YES | LIMITED*** | NO | NO | SELF** |
| User | C(create) | YES | YES | NO | NO | YES (registration only) |
| User | D(destroy) | YES | NO | NO | NO | NO |
| UserSecurityEvent | R | YES | YES | NO | LIMITED | SELF** |
| UserSecurityEvent | C | SYSTEM | SYSTEM | SYSTEM | SYSTEM | SYSTEM |

\* LIMITED support: read-only, scrubbed fields (no password-related internals, no secrets).  
\** SELF means only where record.id == actor.id.  
\*** LIMITED admin updates: may disable/enable users and reset sessions, but MUST be audited; may not change elevated roles without super_admin.

### 5.2 Admin Governance (Admin.RoleAssignment, Admin.AuditLog, optional Admin.SiteSetting)
| Resource | Action | super_admin | admin | editor | support | customer |
|---------|--------|-------------|-------|--------|---------|----------|
| RoleAssignment | R | YES | YES | NO | NO | NO |
| RoleAssignment | C/U/D | YES | NO | NO | NO | NO |
| AuditLog | R | YES | YES | NO | LIMITED | NO |
| AuditLog | C | SYSTEM | SYSTEM | SYSTEM | SYSTEM | SYSTEM |
| SiteSetting (provider config) | R | YES | YES | NO | NO | NO |
| SiteSetting (provider config) | U | YES (step-up) | YES (step-up) | NO | NO | NO |

Note: AuditLog MUST remain append-only (create-only actions).

### 5.3 Content (Content.Post, Category, Tag, joins)
| Resource | Action | super_admin | admin | editor | support | customer |
|---------|--------|-------------|-------|--------|---------|----------|
| Post | R(published) | YES | YES | YES | YES | YES |
| Post | R(draft) | YES | YES | YES | YES | NO |
| Post | C/U/D | YES | YES | YES | NO | NO |
| Post | X(publish/unpublish) | YES | YES | YES | NO | NO |
| Category/Tag | C/U/D | YES | YES | YES | NO | NO |

### 5.4 Catalog (Catalog.Product, Variant, Category, joins, InventoryItem)
| Resource | Action | super_admin | admin | editor | support | customer |
|---------|--------|-------------|-------|--------|---------|----------|
| Product | R(active) | YES | YES | YES | YES | YES |
| Product | R(draft/archived) | YES | YES | NO | NO | NO |
| Product | C/U/D | YES | YES | NO | NO | NO |
| Product | X(publish/unpublish) | YES | YES | NO | NO | NO |
| Variant | C/U/D | YES | YES | NO | NO | NO |
| InventoryItem | R | YES | YES | NO | LIMITED | NO |
| InventoryItem | U | YES | YES | NO | NO | NO |

### 5.5 Pricing (Pricing.PriceBook, PriceEntry, Promotion, Coupon, DiscountApplication)
| Resource | Action | super_admin | admin | editor | support | customer |
|---------|--------|-------------|-------|--------|---------|----------|
| PriceBook/PriceEntry | R | YES | YES | NO | NO | NO |
| PriceBook/PriceEntry | C/U/D | YES | YES | NO | NO | NO |
| Promotion/Coupon | R | YES | YES | NO | LIMITED* | NO |
| Promotion/Coupon | C/U/D | YES | YES | NO | NO | NO |
| DiscountApplication | R | YES | YES | NO | LIMITED | SELF** |

\* LIMITED support coupon read: code + validity window + usage counts only (no internal rules engine payload).

### 5.6 Orders (Orders.Order, LineItem, Adjustment)
| Resource | Action | super_admin | admin | editor | support | customer |
|---------|--------|-------------|-------|--------|---------|----------|
| Order | R | YES | YES | NO | LIMITED* | SELF** |
| Order | X(cancel) | YES | YES | NO | YES (scrubbed) | YES (own, if not paid) |
| Order | X(refund) | YES (step-up) | YES (step-up) | NO | NO | NO |
| OrderLineItem/Adjustment | R | YES | YES | NO | LIMITED | SELF** |
| OrderLineItem/Adjustment | C/U/D | NO*** | NO*** | NO | NO | NO |

\* LIMITED support order read: no payment secrets, but enough to assist customers.  
\*** Order lines/adjustments are snapshot evidence and MUST NOT be mutated after order creation.

### 5.7 Payments (PaymentIntent, PaymentAttempt, WebhookReceipt, ProviderEvent)
| Resource | Action | super_admin | admin | editor | support | customer |
|---------|--------|-------------|-------|--------|---------|----------|
| PaymentIntent | R | YES | YES | NO | LIMITED | SELF** |
| PaymentIntent | X(create/submit) | YES | YES | NO | NO | YES (own checkout only) |
| PaymentAttempt | R | YES | YES | NO | LIMITED | SELF** |
| WebhookReceipt | R | YES | YES | NO | NO | NO |
| ProviderEvent | R | YES | YES | NO | NO | NO |

---

## 6) Test gates (MUST)
Implement a **pinned policy matrix test suite** that asserts:
1) Customer cannot read another customer’s order.
2) Support cannot mutate catalog/pricing/provider config.
3) Editor cannot mutate catalog/pricing/orders/payments.
4) Admin can manage catalog/pricing/orders (but refund requires step-up).
5) SiteSetting/provider config requires step-up for admin and super_admin.
6) AuditLog has no update/destroy actions (separate test).

Tests MUST fail loudly when drift happens.

## 7) Drift protocol (MUST)
If a client needs an exception:
- Update this document first.
- Add/adjust the corresponding test gate.
- Only then update policies/actions.

No doc update = no change.
