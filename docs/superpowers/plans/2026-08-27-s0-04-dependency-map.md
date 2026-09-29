# S0-04 Dependency Map Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create an evidence-based dependency map for the existing Subscription Commerce V1 implementation without changing application behaviour.

**Architecture:** Read the current domain modules, Ash resources, migrations, workers, integrations, tests, and governance documents. Record only verified caller/callee relationships, data and lifecycle effects, runtime/async/external coupling, and extraction risks in `docs/hardening/04_dependency_map.md`.

**Tech Stack:** Elixir, Phoenix, Ash 3.x, PostgreSQL, Oban, and the repository's existing runtime integrations.

---

### Task 1: Establish evidence scope

- [x] Read `AGENTS.md`, applicable `docs/agent_rules/`, governance guidance, and the existing hardening documents.
- [x] Confirm the working tree and bead state before documentation changes.

### Task 2: Inventory implementation dependencies

- [x] Map domain modules, resources, facades, services, orchestration modules, and cross-domain calls under `lib/store/`.
- [x] Map relevant tables, foreign keys, indexes, constraints, snapshots, and version/locking fields under `priv/repo/migrations/`.
- [x] Map workers, supervision/runtime dependencies, tests, and external adapters.

### Task 3: Write the dependency map

- [x] Create `docs/hardening/04_dependency_map.md` with a dependency graph and evidence-backed domain, data, runtime, async, external, and extraction-boundary sections.
- [x] Separate current behaviour, verified risks, and unresolved unknowns; validate the previously reported subscription, payment, and inventory findings.

### Task 4: Verify and hand off

- [x] Run documentation, formatting, and repository checks appropriate to a docs-only change.
- [x] Confirm no application or migration files changed.
- [x] Commit and push the documentation, synchronize the bead, and record the verification evidence.
