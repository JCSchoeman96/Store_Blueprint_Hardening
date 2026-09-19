# Store Blueprint Hardening — Subscription Task Contract Template

**Template version:** v0.1.4
**Purpose:** materialize exactly one bounded, human-selected Subscription
hardening issue for the current serial workflow.

> This contract is subordinate to canonical main governance and the SUBS master
> register. It authorizes only the exact task and scope recorded here. It is not
> a controller specification, does not select work automatically, and does not
> authorize adjacent findings, shared-domain changes, deployment, or merge.

## 1. Serial admission precondition

Complete every check before creating the task branch:

~~~
register state == READY
relevant Product / Architecture / Domain law == frozen
acceptance criteria == deterministic
human explicitly selected this issue
current origin/main governance inspected
current origin/hardening/subscriptions inspected
required external dependencies present
required shared authority assigned
objective bounded
allowed and forbidden write scope explicit
~~~

loop_eligible may be copied as historical/register metadata, but it is not an
execution-admission switch. Do not manufacture READY work. At most one SUBS
implementation issue may be active through this workflow.

## 2. Contract identity

| Field | Required value |
|---|---|
| task_id | <CANONICAL_SBH_ID> |
| title | <SHORT_BOUNDED_TITLE> |
| register_revision | <MASTER_REGISTER_REVISION_OR_EXACT_AUTHORITY> |
| task_state | READY |
| human_selection_evidence | <USER_OR_OWNER_SELECTION_AND_DATE> |
| canonical_main_governance_sha | 59dd41100593b207907c3a7ab4d77755cd80f929 or freshly verified current SHA |
| task_base_sha | <EXACT_CURRENT_EXPLICITLY_ACCEPTED_ORIGIN_HARDENING_SUBSCRIPTIONS_TIP> |
| workstream_branch | hardening/subscriptions |
| task_branch | <ONE_TASK_BRANCH> |

Definition:

~~~
task_base_sha = exact current explicitly accepted origin/hardening/subscriptions
                 tip from which this one issue branches
~~~

Fetch and inspect current refs immediately before recording these fields. Do not
silently rebase after the branch is created; if the accepted base moves, STOP
and obtain a new task decision.

## 3. Authority and ownership

### SUBS authority retained

This task must remain within Subscription ownership:

~~~
Subscription
SubscriptionPlan
SubscriptionItem
RenewalAttempt
renewal scheduling
dunning
cancellation
plan / variant changes
Subscription commercial-contract law
Subscription-specific reconciliation and certification
~~~

Explicit exclusions:

~~~
InventoryAdmission
generic dependency / platform work
auth platform
migrations unless separately authorized
Payments core
Orders core
generic Entitlements infrastructure
~~~

Cross-domain mutations require the owning workstream/domain authority.

### Required shared authority

~~~
<NONE_OR_EXACT_AUTHORITY_ASSIGNMENT>
~~~

If the task needs an authority not listed here, STOP at that owning authority
level. Do not repair the neighbouring domain inside this task.

## 4. Objective and invariant

Objective:

~~~
<ONE_BOUNDED_OUTCOME>
~~~

Canonical invariant:

~~~
<EXACT_INVARIANT_THE_TASK_MUST_PROVE>
~~~

No secondary objective or reinterpretation of frozen law is permitted.

## 5. Lifecycle impact

| Field | Evidence |
|---|---|
| Concept(s) | <Subscription / RenewalAttempt / Dunning / Cancellation / PlanRevision / other> |
| Source state(s) | <EXACT_STATES_OR_CONDITIONS> |
| Allowed transition(s) | <EXACT_TRANSITIONS_OR_NONE> |
| Guards | <EXACT_GUARDS> |
| Side effects | <EXACT_SIDE_EFFECTS_OR_NONE> |
| Failure/recovery | <EXACT_FAILURE_AND_RECOVERY_RULES> |
| Terminal states | <EXACT_TERMINAL_STATES_OR_NONE> |

If lifecycle meaning, commercial law, or race precedence is ambiguous, STOP.

## 6. Dependencies and shared boundaries

### Internal dependencies

~~~
- <DEPENDENCY_ID>: CLOSED / CANONICAL
~~~

### External dependencies

| Dependency | Owning workstream | Exact capability / SHA | Present in task base? | Status |
|---|---|---|---|---|
| <NAME> | <OWNER> | <REQUIREMENT> | YES/NO | SATISFIED/BLOCKED_EXTERNAL_DEPENDENCY |

An absent dependency blocks this task only. Do not widen the task or create a
programme-wide blocker.

## 7. Scope

### Allowed read scope

~~~
<EXACT_FILES_DOCUMENTS_TESTS_AND_HISTORY>
~~~

### Allowed write scope

~~~
<EXACT_FILES_OR_DOCUMENTATION_SURFACES>
~~~

### Forbidden scope

~~~
Subscription source outside the contract
tests outside the contract
migrations / schema / dependencies unless explicitly authorized
Payments, Orders, Inventory, Auth, Entitlements, or Platform ownership
Product / Architecture / Domain law
unrelated CI or infrastructure repair
deployment, production data, credentials, or destructive operations
automatic merge
~~~

## 8. Acceptance criteria

1. <DETERMINISTIC_CRITERION>
2. <DETERMINISTIC_CRITERION>
3. <DETERMINISTIC_CRITERION>

The implementation is complete only when every criterion is evidenced at the
exact task head.

## 9. TDD and verification contract

Where implementation changes are required:

~~~
write the smallest deterministic failing test
prove RED
make the minimal implementation
prove GREEN
run focused tests for the changed surface
run named neighbouring regressions where relevant
~~~

Record the commands and results:

~~~
focused tests: <COMMANDS_AND_RESULTS>
neighbouring regressions: <COMMANDS_AND_RESULTS_OR_NOT_APPLICABLE>
performance/scaling checks: <COMMANDS_AND_RESULTS>
~~~

## 10. Performance & Scaling Review

Record this review even when the task is documentation-only:

| Temperature | Required review |
|---|---|
| Hot | DB query count, N+1 risk, indexes, durable authority, and latency impact for storefront, cart, checkout, webhooks, renewals, access, or dunning paths |
| Warm | ETS/Redis/derived-cache use, TTL, invalidation, stampede protection, and proof that caches do not decide commercial/lifecycle truth |
| Cold | bounded reconciliation/audit, Oban uniqueness/idempotency, retry safety, and telemetry/logging that separates provider occurrence, local observation, queue execution, and application |

~~~
<PERFORMANCE_AND_SCALING_REVIEW>
~~~

## 11. Security and single-tenant review

Confirm authorization, actor boundaries, replay/idempotency, sensitive data,
tenant assumptions, and cross-domain effects:

~~~
single-tenant law remains in force; do not add tenant_id or tenant routing
authorization / actor review: <EVIDENCE>
security / replay / idempotency review: <EVIDENCE>
multi-tenant review: <NOT_APPLICABLE_SINGLE_TENANT_OR_EXACT_EVIDENCE>
~~~

## 12. Review and repository gates

The task requires:

- fresh independent read-only review of the exact diff and task head;
- required repository quality gates and relevant checks;
- exact-head PR CI success before merge;
- a human merge decision; no automatic merge.

~~~
independent reviewer: <NAME_OR_HANDLE>
review result: <PASS / CHANGES REQUIRED>
quality gates: <COMMANDS_AND_RESULTS>
exact-head PR CI: <URL / STATUS / HEAD_SHA>
~~~

## 13. STOP conditions

STOP the selected task, without selecting another automatically, if any occurs:

~~~
current governance or SUBS authority cannot be verified
task is not READY or human selection is absent
task_base_sha moves or cannot be proven
acceptance criteria or frozen law is ambiguous
required dependency or shared authority is absent
scope expands beyond this contract
implementation requires migration or another owner without authority
source reveals an upstream contradiction
focused verification, independent review, required gate, or CI fails
security, performance, or single-tenant assumptions cannot be evidenced
~~~

Stop at the owning authority level. Do not create a new lifecycle state,
manufacture READY work, silently rebase, or repair unrelated failures.

## 14. Completion record

~~~
task_id: <ID>
task_base_sha: <EXACT_SHA>
task_head_sha: <EXACT_HEAD>
changed_paths: <LIST>
review: <PASS / CHANGES REQUIRED>
quality_gates: <PASS / FAIL>
exact_head_ci: <PASS / FAIL / PENDING>
human_merge_decision: <PENDING / APPROVED / DECLINED>
post-merge SUBS authority refresh: <SHA_OR_NOT_APPLICABLE>
~~~
