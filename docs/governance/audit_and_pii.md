# Governance: Audit & PII (Authoritative)

## AuditLog append-only guarantees (MUST)
Ash layer:
- AuditLog resource MUST expose create-only actions.
- AuditLog MUST NOT expose update/destroy actions.
- Policies MUST deny any mutation other than create.

Optional DB layer (pack):
- Trigger to deny UPDATE/DELETE on audit_logs table.

## What AuditLog may store (MUST)
Allowed:
- actor_id (uuid)
- action (string)
- resource (string)
- record_id (uuid)
- inserted_at
- metadata (scrubbed map)
- payload_sha256 (if referencing evidence)

Forbidden:
- raw webhook bodies
- payment instrument details
- sensitive personal data unless explicitly approved

## Evidence separation (MUST)
- Raw webhook payloads may only be stored in Payments.WebhookReceipt.
- AuditLog may reference WebhookReceipt by id and store payload_sha256.

## Scrubbing rules (baseline)
Mask or remove known PII keys before storing metadata:
- email, phone, address, name, card, bank, account, iban, bic, token, secret

## Test gates (MUST)
- There is no update/destroy action for AuditLog.
- Attempting to mutate AuditLog returns UNAUTHORIZED (or equivalent).
- Audit entries exist for at least one admin mutation path and one payment transition path.
