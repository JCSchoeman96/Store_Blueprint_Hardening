# Backup And Restore

## Backup Scope
- Back up Postgres daily at minimum.
- Keep backup encryption keys outside the application host.
- If S3 backs digital products, enable versioning or an equivalent retention policy on the bucket.

## Backup Procedure
- Take a logical Postgres dump with a consistent snapshot.
- Store dumps in durable storage with retention and access controls.
- Record:
  - backup timestamp
  - database version
  - application release version
  - object storage bucket/versioning state

## Restore Drill
- Restore into an isolated staging environment.
- Boot the restored release.
- Run:
  - `bin/store eval "Store.Release.restore_audit()"`
  - `bin/store eval "Store.Release.preflight()"`
- Validate:
  - orders count is sane
  - payment intents count is sane
  - webhook receipts count is sane
  - email outbox count is sane
  - download grants count is sane

## Post-Restore Smoke Checks
- log in as a test user
- browse catalog
- create a checkout
- confirm webhook ingestion still works
- confirm email outbox still delivers
- confirm digital signed URL issuance still works

## PgBouncer Note
- If the deployment uses PgBouncer transaction pooling, set:
  - `STORE_DB_POOL_MODE=transaction`
- This forces Ecto to use unnamed prepared statements and avoids transaction-pool prepared statement crashes.

## Evidence Retention
- Webhook receipt payloads and headers are purgeable after `STORE_WEBHOOK_RETENTION_DAYS`.
- Hashes and minimal metadata remain for reconciliation.
- Purge evidence with the scheduled worker or by running the application long enough for the cron schedule to execute.

## Reconciliation After Restore
- Check webhook receipts that were ingested but not processed.
- Check subscription renewals stuck in retryable states.
- Check email outbox rows in `pending` or `failed`.
- Re-run worker-safe flows only through existing domain and Oban paths.
