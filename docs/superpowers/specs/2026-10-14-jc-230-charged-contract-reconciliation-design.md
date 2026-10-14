# JC-230 charged-contract reconciliation design

## Authority and base

This design implements Linear issue JC-230, SBH-10-05, as re-admitted on 2026-10-14. JC-228 and JC-229 are Done. The canonical base is origin/main at e8616ab1cdbea866600265037e65d88bbf90b84c, the merge of PR #151.

The paid occurrence authority chain is:

    exact successful RenewalCollectionAttempt
      -> exact PaymentApplication / PaymentIntent
      -> exact RenewalAttempt
      -> exact PlanRevision identity and RenewalAttempt charged snapshot
      -> Subscription commercial application
      -> immediate entitlement consequence

The JC-229 handoff remains mandatory. Reconciliation requires order_id, renewal_attempt_id, collection_attempt_id, and payment_intent_id. RenewalCollectionAttempts.success_handoff_for_system/1 validates the exact successful collection. PaymentApplication.payment_intent_id must equal that collection's PaymentIntent. RenewalAttempt.payment_intent_id remains a derived compatibility pointer only. Payments core and PaymentApplication identity are outside this change.

## Current gap

The authorized path rejects attempts with contract_change_id using "ContractChange-bound renewal requires charged-contract reconciliation". Keep that guard until the replacement path is complete. The legacy success path promotes mutable pending fields, omits current_plan_revision_id and quantity, clears future-target fields, and re-fetches mutable SubscriptionPlan data for entitlement sync.

## Design

Load the exact RenewalAttempt.plan_revision_id. The revision must exist, and its subscription_plan_id supplies the Subscription plan identity. Do not re-evaluate its current sale status. A retired revision remains valid evidence for an already-bound paid occurrence. Do not select a replacement revision, recalculate price, or read current SubscriptionPlan commercial fields to interpret the occurrence.

Perform first commercial application in one PostgreSQL transaction. Lock the Subscription row with FOR UPDATE, then lock the exact ContractChange row when attempt.contract_change_id is present. This order matches existing ContractChange persistence. Validate immutable ContractChange evidence, check for an exact already-applied occurrence before checking future-target ambiguity, update the existing Subscription aggregate from charged values, and transition the bound ContractChange to applied. Any failure rolls back both writes.

Extend Subscription.:extend_period to accept current_plan_revision_id and quantity. The reconciliation call supplies only charged commercial fields and paid-renewal recovery fields. It never supplies current_contract_change_id, pending_* attributes, or change_effective_at. Remove future-target fields from the action's accepted attributes because reconciliation is its only production caller.

| Subscription field | Exact source |
| --- | --- |
| current_period_start_at | RenewalAttempt.period_start_at |
| current_period_end_at | RenewalAttempt.period_end_at |
| next_renewal_at | RenewalAttempt.period_end_at |
| current_plan_revision_id | RenewalAttempt.plan_revision_id |
| subscription_plan_id | exact PlanRevision.subscription_plan_id |
| variant_id | RenewalAttempt.variant_id |
| quantity | RenewalAttempt.quantity |
| renewal_amount_minor | RenewalAttempt.amount_minor |
| renewal_currency | RenewalAttempt.currency |
| membership_key | charged snapshot entitlement_scope_key only when entitlement_kind is membership_access and the scope is non-empty; otherwise nil |
| dunning_attempt_count | 0 |
| next_retry_at, retry_suppressed_at, past_due_since_at, billing_status_reason | nil |
| status | active through the existing state transition |

For a ContractChange-bound attempt, first application requires the exact ContractChange to belong to the same Subscription, remain bound_to_renewal, and match the attempt's revision, variant, quantity, amount, currency, and effective_at == attempt.period_start_at. The private/system :apply action permits only bound_to_renewal -> applied. It cannot apply queued, superseded, or canceled changes. Exact replay recognizes an already-applied change only when the Subscription contains every exact charged value. It does not call :apply again.

For an attempt without a ContractChange, replay requires the same exact Subscription commercial fields. For a ContractChange-bound attempt, replay also requires the exact ContractChange status to be applied. Attempt status alone is not proof that commercial application happened.

On first application, the locked Subscription must still have current_period_end_at == attempt.period_start_at. Fail closed if its current period moved. A current ContractChange pointer, a queued future ContractChange, or any legacy pending projection also fails closed before first application. Preserve each future-target value. Run exact replay detection first so a crash after commercial commit can finish access sync if a later target was queued afterward.

The transaction returns :applied or :already_applied, the Subscription, the charged entitlement target, and collected Ash notifications. Deliver notifications after commit. Preserve the sequence: commercial transaction, paid-renewal access-sync telemetry boundary, immediate strict entitlement sync, then mark_attempt_succeeded. A crash at the telemetry boundary leaves the attempt retryable. Retry must not change the Subscription aggregate version or ContractChange status again.

Build the immediate entitlement target from RenewalAttempt.charged_contract_snapshot or the existing parsed renewal-policy helper. Pass that target with the updated Subscription to strict sync. Do not fetch entitlement fields from SubscriptionPlan. This change proves that the immediate call requests the correct target. Durable AccessEffect recovery, retries after terminal failure, and general target-set revocation remain SBH-50 work.

## Scope boundaries

Do not define JC-233 renewal-versus-future-change ordering, SBH-50 durable entitlement convergence, Payments redesign, PayStack runtime behavior, refund policy, or a second commercial aggregate. Preserve JC-265 past_due/suspended recovery and JC-281 authority-withdrawn late-success remediation.

## Validation design

Create test/store/subscriptions/sbh_10_05_charged_contract_reconciliation_test.exs. Cover the fail-closed baseline, exact charged-field application, retired revision replay, all ContractChange evidence mismatches, later-target preservation, exact payment evidence, lifecycle boundaries, and the crash between commercial commit and entitlement sync. The crash test raises from [:store, :subscriptions, :paid_renewal_access_sync] and retries the same four-ID handoff.

The hot path adds only bounded exact reads: PlanRevision by primary key, locked Subscription by primary key, optional locked ContractChange by primary key, and the existing subscription-scoped queued-target lookup. There is no scan, N+1 behavior, or cache authority. Record before-and-after query counts and existing ceilings without silently raising a ceiling. Validation includes required focused subscription, cancellation, worker, payment, and entitlement tests, repository checks, migration alignment, and both performance smoke profiles.
