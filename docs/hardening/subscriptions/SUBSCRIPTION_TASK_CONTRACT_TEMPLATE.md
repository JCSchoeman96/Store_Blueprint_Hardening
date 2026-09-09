# Store Blueprint Hardening — Subscription Task Contract Template

**Template version:** v0.1.3  
**Purpose:** Materialize exactly one branch-sized, already-authorized Subscription hardening task.

> A completed Task Contract is execution authority only for the exact bounded task described here. It does not authorize adjacent findings, architecture changes, shared-domain changes, merges, deployment, or production operations.

---

## Active-mode precondition

This template is used only in `ACTIVE_IMPLEMENTATION_BATCH`.

Before materializing a task:

```text
tracked worktree clean
untracked worktree clean
local bootstrap authority promoted/tracked or supplied externally
```

If any bootstrap authority file remains untracked:

```text
BOOTSTRAP_NOT_PROMOTED
STOP
```

---

# 1. Contract Identity

| Field | Required value |
|---|---|
| `task_id` | `<CANONICAL_SBH_ID>` |
| `title` | `<SHORT_BOUNDED_TITLE>` |
| `register_version` | `<MASTER_REGISTER_VERSION_OR_COMMIT>` |
| `task_state` | `READY` |
| `loop_eligible` | `true` |
| `priority` | `<P1_OR_P2>` |
| `batch_id` | `<SUB_BATCH_ID>` |
| `governance_authority_sha` | `<CANONICAL_MAIN_GOVERNANCE_SHA>` |
| `development_base_sha` | `<ACCEPTED_SUBS_DEVELOPMENT_BASE_SHA>` |
| `batch_base_sha` | `<EXACT_BATCH_BASE_SHA>` |
| `integration_base_sha` | `<NULL_DURING_HARDENING_OR_EXACT_INTEGRATION_SHA>` |
| `workstream_branch` | `hardening/subscriptions` |
| `task_branch` | `<AUTHORIZED_TASK_BRANCH>` |

If `task_state != READY` or `loop_eligible != true`, STOP.

---

# 2. TOON Execution Summary

| Field | Content |
|---|---|
| Task | `<ONE_SINGLE_FOCUSED_ACTION>` |
| Objective | `<WHY_THIS_ACTION_MATTERS_AND_WHAT_IT_ENABLES>` |
| Output | `<CONCRETE_FILES_CHANGES_TESTS_OR_ARTIFACTS_EXPECTED>` |
| Note | `<GUARDS_EDGE_CASES_INDEXES_CACHE_TTL_REDIS_RULE_INVALIDATION_PUBSUB_SECURITY_CONCURRENCY_AND_STOP_BOUNDARIES>` |

The TOON summary must describe exactly one task.

---

# 3. Authority

## Programme authority

```text
<EXACT_PROGRAMME_AUTHORITY_PATH_OR_REFERENCE>
```

## Hardening Register authority

```text
<EXACT_REGISTER_PATH_AND_VERSION_OR_COMMIT>
```

## Task authority

This Task Contract.

## Required shared authority

```text
<NONE_OR_EXPLICIT_AUTHORITY_ASSIGNMENT>
```

Name shared surfaces exactly. If required authority is absent, STOP.

## Base-role law

```text
governance_authority_sha = canonical governance observed on origin/main
development_base_sha = accepted SUBS code base for independent hardening
batch_base_sha = exact batch fixed point
integration_base_sha = null during ordinary hardening
```

Do not substitute one SHA role for another.

---

# 4. Objective

```text
<ONE_SENTENCE_OUTCOME>
```

No secondary objectives.

---

# 5. Canonical Invariant

```text
<EXACT_INVARIANT_THE_IMPLEMENTATION_MUST_PROVE>
```

The worker may not weaken or reinterpret this invariant.

---

# 6. Lifecycle Impact

## Concept

```text
<SUBSCRIPTION | RENEWAL_ATTEMPT | DUNNING | SCHEDULED_CANCELLATION | PLAN_REVISION | CONTRACT_CHANGE | STORED_PAYMENT_METHOD | ENTITLEMENT_EFFECT | OTHER_APPROVED_CONCEPT>
```

## Source state(s)

```text
<EXACT_SOURCE_STATES_OR_CONDITIONS>
```

## Allowed transition(s)

```text
<EXACT_ALLOWED_TRANSITIONS>
```

## Guards

```text
<EXACT_TRANSITION_GUARDS>
```

## Side effects

```text
<EXACT_REQUIRED_SIDE_EFFECTS_OR_NONE>
```

## Failure/recovery transitions

```text
<EXACT_FAILURE_AND_RECOVERY_BEHAVIOUR>
```

## Terminal states

```text
<EXACT_TERMINAL_STATES_OR_NONE>
```

If lifecycle semantics are ambiguous, STOP.

---

# 7. Dependencies

## Internal dependencies

All required Subscription dependencies must already be satisfied:

```text
- <DEPENDENCY_ID>: CLOSED
- <DEPENDENCY_ID>: CLOSED
```

## External dependencies

Declare every cross-workstream capability this exact task requires:

| Dependency | Owning workstream | Required capability / SHA | Present in development base? | Status |
|---|---|---|---|---|
| `<NAME>` | `<S0_PLATFORM_OTHER>` | `<EXACT_REQUIREMENT>` | `YES/NO` | `<SATISFIED/BLOCKED_EXTERNAL_DEPENDENCY>` |

Rules:

```text
external dependency absent from development base
→ BLOCK THIS TASK ONLY
→ do not globally block SUBS
```

If any required dependency is unresolved, STOP this task and allow the controller to consider another READY task.

## Shared authority

Any shared surface must be explicitly `AUTHORITY_ASSIGNED`. No authority decision = no modification.

---

# 8. Allowed Read Scope

```text
- <PATH_OR_MODULE>
- <PATH_OR_MODULE>
```

Reading broadly enough to understand a named boundary is allowed. Writing broadly is not.

---

# 9. Allowed Write Scope

```text
- <EXACT_PATH_OR_NARROW_GLOB>
- <EXACT_PATH_OR_NARROW_GLOB>
```

No file outside this section may be modified unless the contract is formally amended before implementation.

---

# 10. Forbidden Scope

At minimum:

```text
- unrelated Subscription hardening findings
- InventoryAdmission
- Payments core unless explicitly assigned
- Orders core unless explicitly assigned
- generic Entitlements infrastructure unless explicitly assigned
- auth/platform
- generic Redis infrastructure
- CI/governance files unless explicitly assigned
- production configuration
- deployment
- unrelated facade refactor
```

Task-specific exclusions:

```text
- <TASK_SPECIFIC_FORBIDDEN_SURFACE>
```

---

# 11. Expected File Impact

## Create

```text
- <EXACT_PATH_IF_KNOWN>
```

## Modify

```text
- <EXACT_PATH_IF_KNOWN>
```

## Tests

```text
- <EXACT_TEST_PATH_IF_KNOWN>
```

If exact paths are not yet known, name exact modules/surfaces and permit only minimal path discovery.

---

# 12. TDD Contract

## RED proof

```text
<WHAT_MUST_FAIL_AND_WHY>
```

The focused test must fail for the intended missing/incorrect behaviour.

If it fails for an unrelated reason, STOP normal implementation and diagnose.

## GREEN proof

Minimal implementation must make the same focused test pass without weakening the assertion.

---

# 13. Acceptance Criteria

All criteria must be deterministic:

```text
1. <DETERMINISTIC_BEHAVIOURAL_CRITERION>
2. <DETERMINISTIC_DATA_INTEGRITY_CRITERION>
3. <DETERMINISTIC_CONCURRENCY_OR_LIFECYCLE_CRITERION>
4. <DETERMINISTIC_NEGATIVE_OR_EDGE_CASE_CRITERION>
```

Do not use vague criteria such as “works correctly”, “better”, or “appropriate”.

---

# 14. Required Tests

Focused:

```bash
<EXACT_FOCUSED_TEST_COMMAND>
```

Neighbouring regression:

```bash
<EXACT_RELEVANT_REGRESSION_COMMAND>
```

Additional task-specific check:

```bash
<EXACT_COMMAND_OR_NONE>
```

---

# 15. Required Quality Gates

Use repository-native commands:

```bash
<EXACT_QUALITY_COMMAND_1>
<EXACT_QUALITY_COMMAND_2>
git diff --check
```

Do not add arbitrary unrelated gates.

---

# 16. Performance & Scaling Review

## Data layer

```text
HOT:
<WILL_OR_WILL_NOT_USE_ETS_GEN_SERVER_CACHEX_AND_WHY>

WARM:
<WILL_OR_WILL_NOT_USE_REDIS_AND_WHY>

COLD / DURABLE:
<POSTGRES_AUTHORITY_DESCRIPTION>
```

## Required indexes

```text
<NONE_OR_EXACT_INDEX_REQUIREMENTS>
```

## Cache rules

```text
<NONE_OR_EXACT_CACHE_RULE>
```

## TTL strategy

```text
<NONE_OR_EXACT_TTL>
```

## Redis data structure

```text
NONE
```

unless explicit architecture authority exists. If used, name exactly `hash | set | bitmap | zset | list | hyperloglog` and explain why.

## Invalidation trigger

```text
<NONE_OR_EXACT_TRIGGER>
```

## PubSub rule

```text
<NONE_OR_EXACT_POST_COMMIT_BROADCAST>
```

## Performance invariants

```text
- no authoritative Subscription lifecycle read from Redis
- no global Subscription serialization
- no unnecessary N+1 query
- no unindexed critical query
- no peak-time full-table scan
```

---

# 17. Security / Multi-Tenant Review

```text
actor/owner boundary:
<EXACT_RULE>

system/admin boundary:
<EXACT_RULE>

cross-tenant isolation:
<EXACT_RULE>

sensitive payment data:
<EXACT_RULE>

external provider references:
<EXACT_RULE>
```

Authorization changes require explicit authority in this contract.

---

# 18. Agent Skills and Minimum Tools

Normal implementation:

```text
Primary skill: $tdd
Supporting instruction: @unslop where available
```

Unexplained failing behaviour:

```text
Primary skill: $diagnosing-bugs
```

Minimum tools:

```text
filesystem/search
shell
git
mix
existing repository quality commands
test PostgreSQL where required
gh only for push / draft PR / check inspection
```

No additional tools unless this task proves they are necessary.

---

# 19. Fresh Reviewer Contract

Reviewer receives:

```text
Task Contract
authorized base SHA
task HEAD SHA
exact base...HEAD diff
focused test results
quality results
```

Reviewer returns:

```text
VERDICT: PASS | CHANGES_REQUIRED | BLOCKED
```

Findings must contain:

```text
severity
invariant
file/surface
evidence
required correction
```

Reviewer cannot edit code.

---

# 20. Correction Budget

```text
maximum_correction_cycles: 2
maximum_no_progress_iterations: 2
maximum_full_quality_reruns: 2
```

On exhaustion:

```text
RETRY_EXHAUSTED
STOP
```

---

# 21. Draft PR Contract

Only after:

```text
focused verification = PASS
fresh reviewer = PASS
full required verification = PASS
```

may the worker commit, push, and open exactly one **draft PR**.

Default PR base:

```text
hardening/subscriptions
```

unless current governance explicitly authorizes another base.

The worker may not merge.

---

# 22. Exact-Head PR CI Contract

Required checks:

```text
<EXACT_REQUIRED_CHECK_NAMES_OR_GOVERNANCE_REFERENCE>
```

Exact-head verification command:

```bash
<EXACT_GH_CHECK_COMMAND_OR_REPOSITORY_NATIVE_EQUIVALENT>
```

A task is successful only when all required checks pass against the exact current task head SHA.

Allow only one bounded CI wait/check cycle per head.

If checks remain pending after that cycle:

```text
CI_PENDING_STOP
STOP ENTIRE BATCH
```

If CI fails because of the task, correction consumes the existing correction budget and requires:

```text
local focused verification
fresh reviewer PASS
required local quality PASS
push new exact head
exact-head CI re-verification
```

If CI fails for an unrelated blocking reason:

```text
record evidence
do not fix unrelated infrastructure
STOP
```

---

# 23. New Findings

If a new problem is discovered:

```text
record candidate
capture bounded evidence
identify likely owner
do not implement
```

---

# 24. Task-Specific STOP Conditions

In addition to universal loop STOP conditions:

```text
1. <TASK_SPECIFIC_STOP>
2. <TASK_SPECIFIC_STOP>
3. <TASK_SPECIFIC_STOP>
```

Final STOP condition:

```text
The bounded task has been completed, recorded, and its draft PR has been opened.
```

---

# 25. Completion Record

```text
TASK_ID:
STATUS: PASS | BLOCKED | RETRY_EXHAUSTED | CI_PENDING_STOP | NO_CHANGE
AUTHORIZED_BASE_SHA:
TASK_HEAD_SHA:
TASK_BRANCH:
PR:
FILES_CHANGED:
FOCUSED_TESTS:
QUALITY_GATES:
PR_CI:
REVIEW_VERDICT:
NEW_CANDIDATE_FINDINGS:
SHARED_AUTHORITY_USED:
STOP_REASON:
```

Then STOP.
