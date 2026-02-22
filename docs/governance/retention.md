# Governance: Retention (Authoritative)

## Default retention windows (suggested defaults)
- WebhookReceipt.raw_body: 30 days
- WebhookReceipt.headers_subset: 30 days
- WebhookReceipt.payload_sha256: indefinite
- ProviderEvent.normalized_payload (scrubbed): 180 days (optional)
- AuditLog: indefinite (scrubbed only)

## Purge workflow (MUST)
- Purge is performed by an Oban scheduled job.
- Purge must:
  - remove raw_body and headers_subset after TTL
  - keep payload_sha256 and minimal metadata
  - record purge action in AuditLog (scrubbed)

## Compliance hooks (optional)
- Configurable shorter TTLs.
- Manual “right to be forgotten” workflow for user PII (do NOT auto-delete AuditLog).
