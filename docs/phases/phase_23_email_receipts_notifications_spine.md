# Phase 23 — Email, receipts, and notification delivery spine (enterprise)

## Outcome

By the end of this phase, the blueprint can **reliably send customer-facing emails** (order receipt, payment confirmation, refund updates) through a **single outbound delivery spine** that is:

- **Idempotent** (no duplicate sends on retries/replays)
- **Async by default** (Oban workers, never from web)
- **Auditable** (outbox records + delivery attempts)
- **Provider-agnostic** (swap Postmark/Mailgun/SES without touching domains)
- **Safe under failure** (retries without re-running committed domain transitions)

This phase turns “state changed” into “customer got notified” in a production-safe way.

---

## Scope (MVP)

### In-scope (must ship)
- A `Store.Comms` domain (or equivalent comms context) that owns outbound messaging.
- A durable **outbox** model for email messages.
- Oban workers that deliver emails via a provider adapter.
- Templates for:
  - **Order receipt** (paid)
  - **Refund requested** (admin/user appropriate)
  - **Refund processed** (refunded/partially refunded)
- A single wrapper function per email kind:
  - `Store.Comms.enqueue_order_receipt/2`
  - `Store.Comms.enqueue_refund_requested/2`
  - `Store.Comms.enqueue_refund_processed/2`
- A deterministic, searchable “message key” (idempotency key) for each email kind.

### Explicitly out of scope (later phases)
- SMS/WhatsApp/push notifications
- Marketing email campaigns and segmentation
- Customer preference center
- Complex templating editors (CMS)

---

## Hard rules (enterprise boundary)

1. **No email sending from `lib/store_web/**`** (controllers/liveviews/contexts).
   - Web may enqueue a worker or call a domain facade that enqueues.
2. **No provider HTTP calls from domains**.
   - Provider adapters are “edge” modules only.
3. **A committed domain transition must never be retried just because email failed**.
   - Email delivery retries must be isolated from order/payment transitions.
4. **Idempotency must be enforced at the outbox layer**.
   - If enqueue is called twice (replay/webhook retry), only one message should be delivered.

These rules are consistent with `docs/governance/side_effects_quarantine.md` and `docs/governance/outbound_http.md`.

---

## Architecture

### 1) Domain: `Store.Comms`

Recommended resources:

#### `Store.Comms.EmailOutbox`
Purpose: durable queue record for outbound emails.

Suggested attributes:
- `id` (UUIDv7)
- `kind` (enum: `:order_receipt | :refund_requested | :refund_processed | ...`)
- `idempotency_key` (string; **unique**, see below)
- `to_email` (string)
- `to_name` (string, optional)
- `subject` (string)
- `template` (string / enum)
- `template_assigns` (map, JSON)
- `status` (enum: `:queued | :sending | :sent | :failed`)
- `provider` (string/enum)
- `provider_message_id` (string, optional)
- `last_error` (string, optional)
- `attempt_count` (integer)
- `sent_at` (utc_datetime_usec, optional)

Indexes/constraints:
- `UNIQUE (idempotency_key)`
- Index on `(status, inserted_at)`
- Index on `(kind, inserted_at)`
- Optional foreign keys:
  - `order_id` nullable
  - `payment_intent_id` nullable
  - `refund_id` nullable

Policies:
- **Admin**: read/query outbox
- **System**: create/update outbox via workers
- **No public read** (PII)

> Note: You can avoid storing raw email bodies for retention/PII reasons. Prefer storing template + assigns and rendering at send-time.

---

### 2) Provider adapter layer (edge modules)

Create a provider behaviour:

- `Store.Comms.Provider.deliver_email/1 -> {:ok, provider_message_id} | {:error, reason}`

Implementation options:
- **Minimal (no extra dependency)**: use your approved HTTP wrapper (Req via `Store.Support.HTTP.*`).
- **Conventional**: adopt `Swoosh` + provider adapter.

Blueprint preference:
- Start minimal using the existing outbound HTTP wrapper to reduce dependencies.
- Keep the provider behaviour so Swoosh can be swapped in later without domain churn.

Provider configuration must live in `runtime.exs` (credentials never committed).

---

### 3) Delivery workers (Oban)

Workers:
- `Store.Workers.DeliverEmailOutboxWorker`
  - Input: `email_outbox_id`
  - Loads outbox record
  - Renders template
  - Calls provider adapter
  - Updates outbox status + provider_message_id
  - Retries on transient failures

Idempotency:
- Use **unique jobs** keyed by `email_outbox_id` (or idempotency_key), so enqueue is replay-safe.

Retry policy:
- Backoff for provider rate limiting/timeouts.
- Hard fail for invalid email address format (mark failed, no retries).

---

## Trigger points (where enqueue happens)

### Preferred: enqueue from workers that already represent the “edge” transition
For example:
- After `apply_payment_success_once` completes successfully, enqueue `order_receipt`.
- After refund request is created, enqueue `refund_requested`.
- After refund is marked processed, enqueue `refund_processed`.

Rules:
- Enqueue must happen **after the state change is committed** (same principle as post-commit notifications).
- If you enqueue inside a DB transaction, you must ensure Oban insert is not rolled back incorrectly.
  - Preferred: enqueue **after** the transaction (outside) using the already committed IDs.

> Do **not** rely on Ash in-process notifiers for email. Email is an external side effect; treat it as an Oban-driven concern.

---

## Templates

Template storage:
- `priv/email_templates/` with EEx templates:
  - `order_receipt.html.heex` + `order_receipt.text.eex`
  - `refund_requested.html.heex` + `.text.eex`
  - `refund_processed.html.heex` + `.text.eex`

Rendering:
- Render in worker using assigns.
- Ensure deterministic formatting for money (use your internal money display policy, not pricing engine formatting).

Must include:
- Order reference
- Line items summary
- Shipping info (if physical)
- Support contact

---

## Observability & audit

Log fields (structured):
- `email_outbox_id`
- `kind`
- `idempotency_key`
- `provider`
- `attempt`
- `provider_message_id` when available

Metrics:
- delivered count by kind
- failure count by reason
- queue age p95

PII rule:
- Do not log full email body or full address.
- Keep only what you need to diagnose.

---

## Tests (required)

Add governance tests that assert:

1. **Idempotent enqueue**
   - calling `enqueue_order_receipt/2` twice yields one outbox row
2. **Unique job**
   - enqueue twice results in one Oban job (or one delivery)
3. **No send from web**
   - web layer never calls provider adapter directly (static gate + tests if needed)
4. **Delivery worker updates**
   - status transitions `queued -> sent` and stores provider message id
5. **Failure retry isolation**
   - provider failure does not alter order/payment state; only outbox status/attempts

---

## Acceptance criteria

- A paid order results in exactly one receipt email outbox record and one delivery attempt chain.
- Webhook replay or job replay does not duplicate sends.
- Email failure retries do not re-run payment/order transitions.
- Admin can inspect outbox status for troubleshooting.
- All outbound email uses the provider behaviour (no direct Req in random modules).

---

## Governance impact

- No global governance doc updates are required **if** you follow the existing outbound HTTP + side effects quarantine rules.
- If you later add SMS/push, create a new governance doc for “multi-channel notifications” instead of overloading email rules.
