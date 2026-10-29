# JC247-B past-due remove-immediately authority

## Decision and scope

This additive JC247-B decision resolves the stable grant revocation metadata question deferred by the [accepted JC247 authority](2026-10-26-jc-247-purchased-access-policy-authority-correction.md). It otherwise preserves the accepted JC247 and F2 architecture. This document does not authorize runtime implementation or merge.

The purchased `:keep_during_grace` policy continues to select an EFFECTIVE target and F1. The purchased `:remove_immediately` policy selects a NON_EFFECTIVE target and, after the narrow admission and metadata extension below, existing F2. F1 core, F2 core, F0 currentness, the Subscription mutex, exact-source convergence, APPLIED semantics, Entitlements ownership, and the AccessEffect schema remain frozen.

## Grant revocation reason

```text
JC247_B_GRANT_REVOCATION_REASON="past_due_remove_immediately"
```

This means a Subscription exact-source EntitlementGrant is revoked because the exact current purchased `access_on_past_due` policy selected `:remove_immediately` while the Subscription remains `:past_due`.

The reason belongs to grant revocation history. It is not Subscription `billing_status_reason`, RenewalAttempt failure or error data, provider response metadata, AccessEffect disposition or failure reason, or a projection invalidation reason. The projection reason remains exactly `non_effective_access_effect_applied`.

Do not use `grace_expired`: the grace boundary has not expired. Do not use `canceled_now` or `canceled_period_end`: the Subscription remains `past_due`. Do not use `payment_failed`: the authoritative authentication-required dunning producer also enters JC247-B, and grant metadata describes the purchased access decision rather than a provider or billing failure classification. Do not derive the grant reason dynamically from `billing_status_reason`.

## Source transition and replay

For both already-authorized first-episode producers, verified bound payment failure and authentication-required bound dunning, the exact bound RenewalAttempt snapshot may select `access_on_past_due = :remove_immediately`. The locked source transaction must then move `active` to `past_due`, set or retain the exact `current_dunning_renewal_attempt_id`, and set the exact `past_due_since_at` and `failed_payment_boundary_at`. It derives `disposition = NON_EFFECTIVE` with nil `entitlement_kind`, `entitlement_scope_key`, `valid_from_at`, and `valid_until_at`. It establishes or reuses the exact AccessEffect, returns its exact ID, and commits commercial truth. After commit, it executes existing F2 with that ID. It must not look up the latest AccessEffect after commit.

Commercial truth remains committed independently of the executor outcome, under the postcommit-result principle accepted for JC247-A. The outer source-domain result contract remains unchanged.

A same-episode replay or retry from `past_due` to `past_due` with unchanged purchased policy retains the current dunning attempt pointer and failed payment boundary, creates no second policy AccessEffect, and does not reinterpret mutable Plan or PlanRevision policy. Aggregate-version-only bookkeeping may advance. F0.5 independently rederives the same NON_EFFECTIVE target from the exact bound RenewalAttempt policy.

## F0.5 and F2

Only a later authorized JC247-B runtime implementation may replace the JC247-A-era temporary `:jc247_b_policy_deferred` classification. For `past_due` with the exact current dunning pointer, valid owner and episode evidence, and a charged snapshot with `access_on_past_due = :remove_immediately`, F0.5 independently derives the current NON_EFFECTIVE target. The existing F0.5 rules then treat the same complete target as already covered and repair or supersede a different or stale complete target from locked source evidence.

Legacy nil-pointer handling stays unchanged and fail-closed. Malformed owner, period, snapshot, or episode evidence also fails closed. Do not search heuristically for a RenewalAttempt.

A later JC247-B implementation may extend F2 source admission only enough to execute a proven current NON_EFFECTIVE effect while the locked Subscription remains `:past_due`. The admitted path uses grant revocation reason `past_due_remove_immediately`. The upstream immutable AccessEffect target and existing currentness proof constitute the access decision. F2 uses locked Subscription state only for the existing source-admission and revocation-metadata mapping.

F2 must not load Plan, PlanRevision, or RenewalAttempt to interpret policy; decide whether to remove access; or choose EFFECTIVE versus NON_EFFECTIVE. It must not change F0 currentness, the source-version/fingerprint/latest-effect fence, transaction ownership, exact-source convergence, APPLIED or SUPERSEDED semantics, projection repair, or Entitlements production code.

## Historical grants and recovery

When JC247-B revokes an ACTIVE exact-source grant during `past_due`, its `revoked_reason` is `past_due_remove_immediately`. That inactive grant remains unchanged. A later `past_due -> suspended` transition must not rewrite its reason to `grace_expired`: existing exact-source convergence revokes only currently ACTIVE grants.

If exact paid recovery establishes a new ACTIVE grant and a future dunning episode later reaches suspension, existing suspension semantics may revoke that newer active grant with `grace_expired`. Each historical reason describes the transition that revoked its grant.

Exact paid recovery remains `past_due/suspended -> active` and establishes a newer EFFECTIVE target using existing F1. Newer paid truth wins: stale JC247-B NON_EFFECTIVE F2 cannot revoke recovered access. This requires no F1 change, F2 core change, or new executor state.

## Implementation boundaries

```text
JC247_B_TARGET=NON_EFFECTIVE
JC247_B_GRANT_REVOCATION_REASON=past_due_remove_immediately

F0_5_CHANGE_REQUIRED=YES
SOURCE_PRODUCER_CHANGE_REQUIRED=YES
F2_SOURCE_ADMISSION_METADATA_CHANGE_REQUIRED=YES

F1_CORE_CHANGE_REQUIRED=NO
F2_CORE_CHANGE_REQUIRED=NO
ENTITLEMENTS_CHANGE_REQUIRED=NO
ACCESS_EFFECT_SCHEMA_CHANGE_REQUIRED=NO
SUBSCRIPTION_SCHEMA_CHANGE_REQUIRED=NO
RENEWAL_ATTEMPT_SCHEMA_CHANGE_REQUIRED=NO
MIGRATION_REQUIRED=NO

JC247_C_CHANGE_INCLUDED=NO
JC300_FINAL_CUTOVER_INCLUDED=NO
LEGACY_POINTER_REPAIR_INCLUDED=NO
TERM_END_INCLUDED=NO
```

## Required future implementation proofs

1. Payment-failure first transition with remove-immediately creates exactly one NON_EFFECTIVE effect.
2. Authentication-required first transition does the same.
3. The exact effect ID reaches postcommit F2 without a latest-effect lookup.
4. The F2 APPLIED path revokes every ACTIVE Subscription-source grant with `revoked_reason="past_due_remove_immediately"`.
5. Historical inactive grants remain unchanged.
6. Other-source EntitlementGrants remain unchanged.
7. Nil/nil source composition remains NON_EFFECTIVE and requires no invented pair.
8. Same-attempt retry creates no second effect.
9. F0.5 independently derives NON_EFFECTIVE and repairs stale EFFECTIVE JC247-A-era or current candidates when source policy is remove-immediately.
10. Legacy nil pointers remain fail-closed.
11. Owner, period, snapshot, and boundary mismatches remain fail-closed.
12. Exact paid recovery supersedes the NON_EFFECTIVE target, and stale F2 cannot revoke recovered access.
13. Suspension after an applied JC247-B revoke does not rewrite historical `revoked_reason`.
14. Projection invalidation continues to use `non_effective_access_effect_applied`.
15. A deterministic PostgreSQL race proves stale F2 versus paid recovery.
16. F2 admission continues to reject unsupported source states and evidence.
17. No Entitlements production changes are made.
18. Query ceiling changes require measurement, not speculative margin.

## Performance and scaling review

```text
CORRECTNESS_AUTHORITY=PostgreSQL
HOT_CACHE_AUTHORITY=NONE
REDIS_CORRECTNESS_ROLE=NONE
```

JC247-B must not add Redis, ETS, Cachex, or GenServer correctness state. Reuse already locked and evidenced records. Add no scans, attempt-order queries, or N+1 relationship loads. Add no index unless an actual new query path requires one. F2 convergence remains bounded exact-source work. Query ceiling changes require measurement.

Runtime Resource Safety Review: NOT_APPLICABLE. This authority document changes no runtime behavior; the future implementation must assess relevant resource safety with evidence.
