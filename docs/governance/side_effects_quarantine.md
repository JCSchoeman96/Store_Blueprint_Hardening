# Governance: Side Effects Quarantine (Authoritative)
This document prevents “web layer creep” where controllers/liveviews start doing irreversible work.
In this blueprint, **side effects are quarantined** to controlled loci.

## 1) Definitions
**Side effect** includes (non-exhaustive):
- outbound HTTP calls (any third-party API)
- job enqueueing (Oban.insert / Oban.insert_all)
- email/SMS sending
- file uploads to external storage
- payment/refund/capture actions
- anything that changes external state outside Postgres

## 2) Allowed loci (MUST)
Side effects MUST occur only in:
1) **Oban workers** (`lib/store/workers/**`)  
2) **Domain actions** that are explicitly marked as “side-effectful” and internally enqueue a job (preferred: enqueue job, don’t do the side effect inline)  
3) **Integration modules** under `lib/store/integrations/**` that are ONLY invoked by workers or side-effectful domain actions

## 3) Web layer prohibitions (MUST NOT)
Under `lib/store_web/**`:
- MUST NOT call outbound HTTP (including `Store.Support.HTTP.ReqClient`)
- MUST NOT call `Oban.insert/2` or `Oban.insert_all/2`
- MUST NOT call payment provider SDKs or refund/capture APIs
- MUST NOT send emails/SMS

**Web layer role:** validate input, call Ash actions, render responses.

## 4) Narrow exceptions (ALLOWLIST)
Two exceptions are allowed by this blueprint:

### 4.1 Webhook controller enqueue-only
`lib/store_web/controllers/webhook_controller.ex` MAY:
- read and preserve raw webhook evidence (`raw_body` + headers)
- create a `Payments.WebhookReceipt` via an Ash action (preferred)
- enqueue a single Oban job to process the receipt

It MUST NOT:
- verify signatures inline
- apply payment state transitions inline
- call outbound HTTP inline

Phase 08 deterministic idempotency baseline:
- `idempotency_key = sha256("#{provider}\n" <> raw_body)`
- duplicate ingest MUST be NOOP-safe (receipt dedupe)

### 4.2 Payment callback controller enqueue-only
`lib/store_web/controllers/payment_callback_controller.ex` MAY:
- read callback payload + headers
- create a `Payments.WebhookReceipt` via Ash action
- enqueue `Store.Workers.ProcessWebhookReceiptWorker` only

It MUST NOT:
- call outbound HTTP inline
- mutate order/payment state inline
- enqueue arbitrary worker modules

## 5) Enforcement gates (MUST)
`mix check` MUST include gates that fail CI when violations occur.

### 5.1 No outbound HTTP in web gate (MUST)
Fail if any file under `lib/store_web/**` references:
- `Store.Support.HTTP.ReqClient`
- `Req.`

### 5.2 No Oban enqueue in web gate (MUST)
Fail if any file under `lib/store_web/**` references:
- `Oban.insert`
- `Oban.insert_all`

ALLOWLIST:
- `lib/store_web/controllers/webhook_controller.ex` may enqueue (enqueue-only rule)
- `lib/store_web/controllers/payment_callback_controller.ex` may enqueue `Store.Workers.ProcessWebhookReceiptWorker` only

Preferred implementation:
- Credo custom check with per-path allowlist and file/line reporting.

## 6) Test gates (P0)
- At least one test proves webhook controller only enqueues and does not transition order/payment state inline (i.e., transition occurs in worker).
- CI gates prove web layer does not call HTTP wrapper or Oban insert (except allowlist).

## 7) Drift protocol (MUST)
If a project needs a new web-layer exception:
1) Update this doc (add explicit exception)
2) Update the CI allowlist + tests
3) Then implement the change

No doc update = no exception.
