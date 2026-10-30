# JC247-C purchased cancellation policy authority

Status: Runtime-authorization amendment for the accepted JC247-C authority. This authorization takes effect after this amendment is merged to main. Human review and merge remain required for the runtime PR.

Once merged, implementation must execute the existing frozen JC247-C authority and implementation plan without semantic drift. This authorization applies only to the existing frozen scope. It does not authorize JC247-C authority redesign, JC300 final cutover, term-end behavior, schema or migration work, Entitlements redesign, F1/F2 core redesign, a new public executor, new worker architecture, or a Comms redesign.

Repository: `JCSchoeman96/Store_Blueprint_Hardening`
Accepted main SHA: `b877e0c0b50fd7171c16a3a6ba4b6151681ce49c`
Accepted main tree: `3f2c44f28419dcb63761e105ea90e355db0eab4b`
Date: 2026-10-29

## Authority and scope

This is an additive JC247-C implementation authority. It follows the accepted JC247-A and JC247-B work, the JC247 purchased access policy authority correction, the SBH-50 authority amendment, and accepted F0, F0.5, F1, and F2 contracts. Where older code or tests assume that every canceled Subscription is NON_EFFECTIVE, this authority controls.

The scope is purchased `access_on_cancel` for actual cancellation transitions. Scheduling and rescission remain target-neutral. JC300 final cutover, term expiry, legacy dunning-pointer repair, new cancellation reasons, payment precedence, provider behavior, Redis/cache correctness, and new Oban architecture remain outside scope.

PostgreSQL remains the correctness authority. Subscription owns lifecycle and policy interpretation. AccessEffect stores the immutable desired target. F1 and F2 execute that target. Entitlements converges exact Subscription-source grants and does not interpret policy.

## Frozen cancellation semantics

| Transition | Required source evidence | Desired target | Executor and grant reason |
|---|---|---|---|
| Schedule period end: `cancel_at_period_end=false -> true`, status unchanged | Existing cancellation instruction and boundary rules | No target change. Create no AccessEffect. | None. It records the instruction not to renew at the future boundary. It does not cancel access now. |
| Rescind: `cancel_at_period_end=true -> false`, status unchanged | Exact current scheduled instruction and existing rescission guard | No target change. Create no AccessEffect or restoration effect. | None. Scheduling did not remove access. |
| Scheduled boundary: `active -> canceled`, reason `canceled_period_end` | Exact due boundary rechecked under the Subscription lock. Persist `canceled_at` from that boundary. | NON_EFFECTIVE; nil kind, scope, start, and end. Do not read `access_on_cancel`. | Existing F2 with the exact effect ID; grant reason `canceled_period_end`. |
| Cancel now with `access_on_cancel=:remove_immediately` | Actual transition from `active`, `past_due`, or `suspended` to canceled; reason `user_request`; exact funded `Subscription.current_plan_revision_id`; persisted `canceled_at` | NON_EFFECTIVE; nil kind, scope, start, and end. | Existing F2 with the exact effect ID; grant reason `canceled_now`. |
| Cancel now with `access_on_cancel=:keep_until_period_end` and a remaining funded interval | Same actual transition and funded PlanRevision authority. The interval remains only when `current_period_start_at <= canceled_at < current_period_end_at`. | EFFECTIVE through the funded end. Pair composition uses the exact revision pair, `valid_from_at=current_period_start_at`, and `valid_until_at=current_period_end_at`. Nil/nil composition stays nil/nil, with `valid_from_at=nil` and `valid_until_at=current_period_end_at`. | Existing F1 with the exact effect ID. Subscription status remains canceled. |
| Cancel now with `access_on_cancel=:keep_until_period_end` and no remaining funded interval | Same actual transition and evidence; valid period bounds, with cancellation outside the funded interval | NON_EFFECTIVE; nil kind, scope, start, and end. | Existing F2 with the exact effect ID; grant reason `canceled_now`. |
| Unknown or ambiguous canceled reason | No classified evidence | Fail closed. Do not derive from `status=:canceled` alone. | F0.5 rejects the source. F2 has no fallback reason and must fail closed. |

An explicit `:period_end` request that existing payment and boundary checks resolve to an actual `:now` transition follows the cancel-now rows. It is classified by the persisted `user_request` reason, not by the caller requested mode.

## Policy and target evidence

The only `access_on_cancel` authority is the immutable PlanRevision referenced by the locked Subscription field `current_plan_revision_id`. Do not read mutable `SubscriptionPlan.access_on_cancel`, an old renewal snapshot, a queue row, or an AccessEffect to choose policy. The current revision ID remains on the Subscription after either cancellation transition. The cancellation actions write status, timestamps, flags, and dunning identity without clearing `current_plan_revision_id` or changing funded period bounds.

The cancel-now target derivation belongs in `Store.Subscriptions.AccessEffectTargetOrder`, using a narrow helper such as `derive_cancel_now_target(subscription, funded_revision)`. It must prove all of the following before returning a target:

- `subscription.status == :canceled` and `subscription.canceled_reason == "user_request"`.
- `canceled_at` is a persisted DateTime.
- `current_plan_revision_id` is present and equals the passed `PlanRevision.id`.
- `current_period_start_at` and `current_period_end_at` are DateTimes with `start < end`.
- `access_on_cancel` is a recognized value read from that exact PlanRevision.
- Entitlement composition is either a complete kind/scope pair or exactly nil/nil.

For `:remove_immediately`, return NON_EFFECTIVE. For `:keep_until_period_end`, first test the exact half-open interval. Inside it, return EFFECTIVE with pair or nil/nil composition and the validity values above. Outside it, return NON_EFFECTIVE. Never modify either funded period timestamp or extend the interval. Missing, mismatched, malformed, or unsupported evidence fails closed.

Every target also preserves complete current source provenance: `source_order_line_item_id` and `current_contract_change_id` from the locked Subscription, and `plan_revision_id == current_plan_revision_id`. A dunning RenewalAttempt or mutable Plan must not replace this provenance.

The Subscription state machine currently permits `pending` for its private cancel-now transition, while customer and admin action capabilities exclude `pending`. JC247-C must enforce the accepted cancel source states in the facade before changing cancellation state. A pending source is not a new purchased cancellation case.

`canceled_at` is authoritative because the cancel-now update persists it in the Subscription transition. The scheduled-boundary transition persists the exact selected boundary. Both terminal cancellation actions clear `current_dunning_renewal_attempt_id` in that same source update. The RenewalAttempt remains audit history. No attempt guessing or backfill is authorized.

## Producer and transaction contracts

### Customer and admin cancel-now

`StoreWeb.Live.SubscriptionsLive.Show` calls `Store.Subscriptions.Facade.cancel_subscription_for_user/3`. `StoreWeb.Live.Admin.Subscriptions.ShowLive` calls `cancel_subscription_for_admin/3`. Both use the same `run_cancel/3` and `cancel_subscription_in_transaction/4` source transaction. The customer path also supports rescission. Admin currently exposes schedule and cancel-now only.

The transaction locks the Subscription first through `lock_subscription_aggregate_version/1`. It then runs the existing exact renewal-attempt and payment-application precedence checks, performs the existing cancellation transition, derives the target from the exact funded revision, and establishes or reuses the immutable AccessEffect before commit. Keep the payment and cancellation ordering rules from JC281 and JC265 unchanged.

The transaction result must carry the exact effect identity and disposition, equivalent to `%{id: access_effect_id, disposition: :effective | :non_effective}`. For cancellation email eligibility, it also carries an internal `membership_access_ended_email?` boolean derived from the same exact funded PlanRevision used for target derivation. After the outer transaction commits, route the exact effect ID to F1 or F2. Do not query the newest effect or infer an executor from Subscription state after commit. Keep effect IDs and the email flag out of public scheduled-sweep results.

The cancellation transaction commits commercial truth together with the immutable target. A post-commit F1/F2 failure does not undo or rewrite the canceled Subscription. The existing AccessEffect recovery path can retry the durable target.

### Legacy direct revoke

The current post-commit path is `Store.Subscriptions.Facade.finalize_immediate_cancellation/2`, called by the shared customer/admin path. It calls `Store.Entitlements.Facade.revoke_subscription_entitlements_for_system/2` with `canceled_now`. This is a post-commit direct grant writer. Remove that call from the cancel-now finalizer so it cannot race with or duplicate the exact F1/F2 executor.

The current finalizer also queues a membership `access_ended` outbox message. Its audience gate must use `funded_revision.entitlement_kind == :membership_access`, where `funded_revision` is the exact PlanRevision already loaded inside the cancel-now source transaction. Carry the resulting boolean in the internal transaction result. Do not read mutable `SubscriptionPlan` after commit, add an email field to AccessEffect, or change schema. The existing Comms enqueue path must accept this evidence without looking up mutable Plan data; keep its recipient, template, and outbox idempotency behavior. If the existing subject needs a Plan name or key, use a generic access-ended subject rather than fetching mutable Plan data.

For cancel-now, queue that existing message only when all three conditions hold: the internal flag is true, the exact established effect disposition is NON_EFFECTIVE, and exact F2 execution returns `{:ok, :applied}` or `{:ok, :applied_projection_pending}`. Both results mean durable grant convergence succeeded; the latter means projection invalidation still needs repair. Never queue for EFFECTIVE, a non-membership funded revision, F2 error, `:noop`, or `:superseded`. Use the exact effect ID and disposition plus the F2 result. Keep this post-commit consequence outside the source transaction. The email is not correctness authority.

### Scheduling and rescission

Schedule and rescind continue through the existing Subscription-locked contract-change transaction. They change only cancellation intent and related future-contract state. They create no AccessEffect and dispatch no executor, including on replay. The facade must reject unsupported source states before applying a cancellation command.

### Scheduled boundary and late paid reconciliation

`Store.Workers.RunDueScheduledCancellationsWorker` calls `run_due_scheduled_cancellations_for_system/1`. The facade selects due active Subscriptions, locks each source, rechecks the exact boundary, writes `canceled_period_end`, sets `canceled_at` to the boundary, clears cancellation flags and dunning identity, and establishes a NON_EFFECTIVE target in the same source transaction.

The current direct due-worker path discards the effect ID and sends post-commit notifications and email. Late paid renewal reconciliation can call the same terminalization helper from its locked transaction; that path also discards the effect ID and defers execution to recovery. JC247-C must return the exact NON_EFFECTIVE ID from both paths and dispatch existing F2 after the owning outer transaction commits. It must not read `access_on_cancel` at the boundary. The public `run_due_scheduled_cancellations_for_system/1` result remains unchanged, including `due_count`, `canceled_count`, `failed_count`, `cursor`, and `now`; exact effect IDs and the membership-email flag stay internal.

For the existing scheduled-boundary membership email, derive the same membership flag from the exact funded PlanRevision in the source transaction and carry it internally. Commit `canceled_period_end` and the NON_EFFECTIVE effect first, then run exact F2. Queue the existing email only after F2 returns `{:ok, :applied}` or `{:ok, :applied_projection_pending}` and the membership flag is true. F2 errors, `:noop`, and `:superseded` must not enqueue a new message in the direct path. The existing scheduled-notification replay must not bypass this rule: it may enqueue only after the exact current boundary effect has durable-applied, and it must use funded-revision membership evidence rather than mutable Plan data. If the exact revision cannot be proved, suppress the email without changing cancellation target or source transition.

Email delivery remains best effort. JC247-C does not make F2 application and outbox enqueue one atomic transaction. A crash after F2 commits but before the outbox enqueue can omit this communication. Closing that gap requires separate Comms/outbox authority and is outside JC247-C.

## F1, F2, and F0.5 admission

### F1

`AccessEffectCurrentnessFence.prove/1` locks the Subscription and candidate, then checks source identity, source version, fingerprint, target shape, and latest-effect identity. It does not reject a canceled Subscription. The EFFECTIVE executor consumes the immutable effect target and performs exact-source convergence without checking cancellation policy.

Therefore `F1_CANCELED_EFFECTIVE_CURRENTLY_ADMITTED=YES` for a current, executable EFFECTIVE effect on a canceled source. `F1_CHANGE_CLASS=NONE`. Do not change F1 currentness, convergence, lifecycle, Entitlements semantics, or source lock order.

### F2

The existing F2 path maps `canceled_reason="canceled_period_end"` to `canceled_period_end` and `canceled_reason="user_request"` to `canceled_now`. It receives only a proven NON_EFFECTIVE target. It does not read `access_on_cancel`, Plan, or PlanRevision to choose a target.

`F2_CANCELED_ADMISSION=PASS`, `F2_CORE_CHANGE_REQUIRED=NO`, and `F2_POLICY_INTERPRETATION_REQUIRED=NO`. Preserve the existing mapping and exact-source revocation behavior.

### F0.5

The current `derive_current_target/2` maps every canceled Subscription to NON_EFFECTIVE. That status-only branch is insufficient. Update it so:

- `canceled` plus `canceled_period_end` derives NON_EFFECTIVE without loading policy.
- `canceled` plus `user_request` loads the exact funded current PlanRevision by primary key, proves its ID, requires persisted `canceled_at` and valid funded bounds, reads `access_on_cancel` from that revision, and returns the complete target defined above.
- Any other cancellation reason or missing evidence fails closed.

Keep the existing F0.5 candidate page, Subscription-first lock, candidate validation, currentness fence, target comparison, cursor, counts, terminal replay, and repair behavior. Equal complete evidence remains `already_covered`. A different current target follows the existing repair/supersession path from locked source evidence. A stale candidate follows current F0 currentness semantics. F0.5 does not execute effects.

## Replay and grant history

An already canceled user-request Subscription with cancellation flags cleared remains an idempotent cancel-now no-op. Scheduling and rescission replay create no target. Scheduled boundary replay is a no-op after the first source transition. A repeated F0.5 candidate is terminal, newer-effect-present, or already-covered under the existing rules; it must not create a duplicate policy effect for the same transition.

F2 revokes every active grant for the exact Subscription source and preserves inactive rows and their prior revocation reasons. Other source kinds and other Subscription IDs remain unchanged. F1 makes the exact funded target effective through the stored end and converges other active rows for the same Subscription source under existing rules. Historical inactive grants remain historical. No grant row is deleted. Projection invalidation remains after the executor transaction commits.

## Race proofs

The implementation must add deterministic PostgreSQL proofs without changing commercial precedence:

1. Extend existing JC281 payment-application versus cancellation tests for payment-first and cancellation-first order. Preserve the current payment history, cancellation, refund, and recovery assertions. Assert access follows the winning source truth.
2. Extend existing JC265 cancel-now versus paid-recovery/access-sync coverage. Prove the exact current effect decides the final grant set and a stale renewal writer cannot restore or revoke access incorrectly.
3. Extend `access_effect_target_order_contention_test.exs` for cancellation producer versus F0.5 in both producer-first and reconciler-first lock-arrival orders. Use the existing independent PostgreSQL connection and blocker evidence. Do not use sleeps.
4. Remove the direct cancel-now grant writer. Prove keep-until-period-end access remains effective after F1. Do not retain two competing writers and attempt to test their race.

Payment-first and cancellation-first outcomes stay those already accepted by JC281/JC265. The AccessEffect change orders access convergence around the winning source result; it does not add payment precedence.

## Implementation boundary and exclusions

Expected production files:

- `lib/store/subscriptions/access_effect_target_order.ex` for classified canceled target derivation.
- `lib/store/subscriptions/facade.ex` for source transaction target establishment, internal email evidence, exact post-commit dispatch, direct-revoke removal, scheduled-boundary result propagation, and source-state admission.
- `lib/store/comms/domain.ex` for a narrow update to the existing access-ended enqueue path so cancellation callers can pass immutable membership evidence without a mutable Plan lookup. Preserve the existing recipient, template, and outbox behavior. Do not redesign Comms.

Expected tests are focused additions or edits under `test/store/subscriptions/` and `test/store/comms/domain_test.exs`, including the target-order unit and reconciliation tests, cancellation acceptance coverage, exact email eligibility and no mutable Plan read, currentness/executor tests, existing payment/cancellation races, scheduled-boundary tests, and target-order contention coverage.

Do not modify `Store.Entitlements` production code, AccessEffect schema, Subscription schema, RenewalAttempt schema, migrations, indexes, public executors, or worker architecture. The existing worker calls the facade; no worker change is required if the facade returns and dispatches the effect ID. Stop for authority review if a schema, migration, Entitlements, executor, term-end, or JC300 change appears necessary.

## Performance & Scaling Review

| Dimension | JC247-C plan |
|---|---|
| Hot, warm, cold | Cancellation is a warm source write. Storefront entitlement reads remain hot and unchanged. F0.5 reconciliation remains cold, bounded PostgreSQL work. |
| Query added | Cancel-now, scheduled-boundary email eligibility, and each canceled `user_request` F0.5 candidate may need the exact funded PlanRevision row. Reuse it when target derivation already loaded it. Otherwise use `current_plan_revision_id` as an exact primary-key lookup. Do not load mutable Plan or traverse a collection. |
| Query count and N+1 | At most one exact PlanRevision lookup per cancellation source transaction, reused for target or email evidence, and one per canceled `user_request` F0.5 candidate. The F0.5 page is already bounded and processes each candidate under its existing source lock. No per-grant loop or relationship fan-out is added. Measure the transaction query delta. |
| Indexes and scans | The PlanRevision lookup is a primary-key lookup. Add no index and no scan. Existing AccessEffect and Subscription indexes remain unchanged. |
| Transaction and locks | The warm cancellation transaction gains one exact identity read inside its existing transaction; it adds no second transaction. Subscription remains the first source lock. The PlanRevision read adds no correctness lock. AccessEffect establishment and F1/F2 retain their existing lock order. Do not add a second source lock. |
| Cache and correctness | `CORRECTNESS_AUTHORITY=PostgreSQL`; `CACHE_CORRECTNESS_ROLE=NONE`. Cachex, Redis, and PubSub do not select policy or target. No cache, TTL, invalidation, or stampede changes are authorized. Existing executor projection invalidation stays post-commit. |
| Post-commit work | Keep exact F1/F2 dispatch outside the source transaction after commit. The transaction persists commercial truth and target even if execution later fails. |
| Oban and email | Add no job, worker, or outbox architecture. Keep existing scheduled-cancellation and AccessEffect recovery uniqueness and outbox idempotency. Derive membership email eligibility from the exact funded PlanRevision and carry it internally. Queue the existing message only after exact NON_EFFECTIVE F2 returns `:applied` or `:applied_projection_pending`. Do not queue it for EFFECTIVE, non-membership revisions, errors, `:noop`, or `:superseded`. The F2/outbox crash window remains a best-effort communication limit. |
| Telemetry | Preserve existing cancellation, executor, and recovery telemetry. Record exact effect ID, disposition, outcome, bounded candidate progress, and relevant query/lock timing without logging customer data. |

## Runtime Resource Safety Review

The proposed code changes add no long-lived process, mailbox, cache, or resource lifecycle. The cancel-now source transaction gains an exact primary-key read while it already holds the Subscription lock. F0.5 continues to use its existing bounded page and per-candidate transaction. The implementation review must measure query count and source-lock time, confirm candidate memory remains bounded, and inspect cleanup and failure paths. Runtime and convergence claims stay UNMEASURED until measured. A single run is diagnostic; convergence or no-accumulation claims require at least two equivalent bounded repetitions.

## Preflight disposition

```text
BASE_SHA=b877e0c0b50fd7171c16a3a6ba4b6151681ce49c
BASE_TREE=3f2c44f28419dcb63761e105ea90e355db0eab4b
MAIN_UNMOVED=YES
TASK0=PASS
CANCELED_AT_AUTHORITY=PROVEN
FUNDED_REVISION_AFTER_CANCEL=PROVEN
F1_CANCELED_EFFECTIVE_CURRENTLY_ADMITTED=YES
F1_CHANGE_CLASS=NONE
F1_CORE_CHANGE_REQUIRED=NO
F2_CANCELED_ADMISSION=PASS
F2_CORE_CHANGE_REQUIRED=NO
F2_POLICY_INTERPRETATION_REQUIRED=NO
F0_5_CANCELED_POLICY_GAP=STATUS_ONLY_CANCELED_MAPPING
LEGACY_DIRECT_REVOKE_LOCATION=Store.Subscriptions.Facade.finalize_immediate_cancellation/2
LEGACY_DIRECT_REVOKE_TRANSACTIONAL_OR_POSTCOMMIT=POSTCOMMIT
LEGACY_DIRECT_REVOKE_DECISION=REMOVE
EXPECTED_PRODUCTION_FILES=lib/store/subscriptions/access_effect_target_order.ex, lib/store/subscriptions/facade.ex, lib/store/comms/domain.ex
IMMUTABLE_EMAIL_KIND_AUTHORITY=PlanRevision.entitlement_kind
MUTABLE_PLAN_EMAIL_READ_REQUIRED=NO
CANCEL_NOW_EMAIL_RULE_FROZEN=YES
SCHEDULED_BOUNDARY_EMAIL_AFTER_F2=YES
COMMUNICATION_CRASH_WINDOW_DOCUMENTED=YES
SCHEDULED_SWEEP_PUBLIC_RESULT_SHAPE=UNCHANGED
SCHEMA_CHANGE_REQUIRED=NO
MIGRATION_REQUIRED=NO
ENTITLEMENTS_CHANGE_REQUIRED=NO
NEW_PUBLIC_EXECUTOR_REQUIRED=NO
IMPLEMENTATION_AUTHORIZED=YES
MERGE_AUTHORIZED=NO
STOP_CONDITION=NONE
```

## Evidence inspected

- `lib/store/subscriptions/facade.ex`
- `lib/store/subscriptions/access_effect_target_order.ex`
- `lib/store/subscriptions/access_effect_currentness_fence.ex`
- `lib/store/subscriptions/subscription.ex`
- `lib/store/subscriptions/plan_revision.ex`
- `lib/store/entitlements/facade.ex`
- `lib/store/comms/domain.ex`
- `lib/store/comms/templates.ex`
- `priv/email_templates/access_ended.html.eex`
- `lib/store/workers/run_due_scheduled_cancellations_worker.ex`
- `lib/store_web/live/subscriptions_live/show.ex`
- `lib/store_web/live/admin/subscriptions/show_live.ex`
- `test/store/subscriptions/cancellation_renewal_authority_test.exs`
- `test/store/subscriptions/access_effect_target_order_reconciliation_test.exs`
- `test/store/subscriptions/access_effect_target_order_contention_test.exs`
- `test/store/subscriptions/sbh_40_02_durable_period_boundary_terminalization_test.exs`
- `docs/superpowers/specs/2026-10-26-jc-247-purchased-access-policy-authority-correction.md`
- `docs/superpowers/specs/2026-10-29-jc247-b-past-due-remove-immediately-authority.md`
- `docs/superpowers/specs/2026-10-23-access-effect-f0-5-target-order-coverage-design.md`
- `docs/superpowers/specs/2026-10-22-jc-245-246-access-effect-convergence-authority-design.md`
- `docs/governance/sbh_50_access_effect_entitlements_authority_amendment.md`
