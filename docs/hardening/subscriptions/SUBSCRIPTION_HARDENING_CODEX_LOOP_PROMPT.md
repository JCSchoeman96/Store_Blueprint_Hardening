# Codex Loop Prompt — Historical Notice

**Historical loop prompt:** `v1.4`
**Full prior prompt preserved at:** Git commit
`80d44613dc45a26ecb34a8eb6cbad8cce1e4f0c1`

This file is historical provenance only. **Do not paste or execute the prior
prompt for current SUBS work.** It described the retired autonomous controller
and no longer grants task-selection, implementation, resumption, or merge
authority.

Current SUBS tasks are explicitly human-selected and serial. Use the current
task contract together with canonical `main` governance, especially:

```text
docs/agent_rules/active_workstreams.md
docs/hardening/subscriptions/SUBSCRIPTION_TASK_CONTRACT_TEMPLATE.md
```

The current policy keeps `SUBS lifecycle = READY`, permits at most one bounded
implementation issue at a time, requires a fresh current governance/SUBS-tip
check, TDD or minimal implementation as applicable, focused verification,
fresh independent review, repository quality gates, exact-head PR CI, and a
human merge decision. Refresh the canonical SUBS authority before selecting
another issue.

Frozen Subscription business/domain law, including JC-219 through JC-223, is
unchanged by retiring the controller.
