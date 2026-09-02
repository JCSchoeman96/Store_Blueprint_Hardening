# DEP-SEC-03 implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade the proven 13-package security graph and migrate Google OAuth to durable, confirmation-gated AshAuthentication 4.14 provider identities.

**Architecture:** Keep the Accounts domain as the only authentication boundary. Let AshAuthentication own provider resolution, protected pending confirmation payloads, identity creation, and confirmation consumption. Add only the generated UserIdentity schema needed to persist `(strategy, uid) -> user_id`, with database and Ash policy guards around it.

**Tech Stack:** Elixir 1.19, Phoenix 1.8, LiveView, Ash 3.x, AshPostgres 2.x, AshAuthentication 4.14.0, PostgreSQL, Swoosh, Req, ExUnit.

---

## File map

| File | Responsibility |
| --- | --- |
| `mix.exs` | Durable direct constraints for the required graph, limited to declarations that need a change. |
| `mix.lock` | The resolved 13-record security graph. |
| `lib/store/accounts/user_identity.ex` | AshAuthentication provider identity resource and policy boundary. |
| `lib/store/accounts/domain.ex` | Register `Store.Accounts.UserIdentity`. |
| `lib/store/accounts/user.ex` | Wire the Google strategy and `register_with_google` action to native identity resolution. |
| `lib/store/accounts/emails.ex` | Render normal confirmation and identity-link confirmation copy without exposing OAuth payloads. |
| `lib/store/accounts/user/senders/send_new_user_confirmation_email.ex` | Pass and interpret AshAuthentication confirmation options. |
| `test/store/accounts/authentication_test.exs` | Password, Google, existing-user, and native confirmation lifecycle coverage. |
| `test/store/accounts/user_identity_test.exs` | Resource policy, field sensitivity, uniqueness, ownership, and deletion invariants. |
| `test/store_web/controllers/auth_routes_test.exs` | Existing route, session, and confirmation email regressions. |
| `priv/repo/migrations/*user_identities*.exs` | Generated `user_identities` table and constraints only. |
| `priv/resource_snapshots/repo/user_identities/*.json` | Matching generated Ash resource snapshot only. |

No S0, checkout-performance, InventoryAdmission, memory-runtime, or PR #2 file is in the implementation write set.

## Task 1: Resolve the bounded dependency graph

**Files:**

- Modify: `mix.exs` only if a direct constraint excludes a required target.
- Modify: `mix.lock` through targeted Mix resolver commands.

- [ ] **Step 1: Record the baseline declarations and lock records.**

Run:

```bash
git rev-parse HEAD
git show HEAD:mix.exs | rg -n 'phoenix|ash_authentication|bandit|decimal|ecto|jason|mint|open_api_spex|plug|postgrex|req|xema'
git show HEAD:mix.lock | rg -n '"(ash|ash_authentication|bandit|decimal|ecto|jason|mint|open_api_spex|phoenix|plug|postgrex|req|xema|ash_postgres|ash_sql|ecto_sql|ash_authentication_phoenix|finch)"'
```

Expected baseline is `aea80e8306853644b9c2f103d292cbc97f35e991`, with the 13 versions in the approved design and the five unchanged compatibility anchors.

- [ ] **Step 2: Change only the direct constraint that cannot admit the target.**

The baseline declaration is:

```elixir
{:req, "~> 0.5"},
```

Change it to:

```elixir
{:req, "~> 0.6"},
```

Keep the existing `phoenix`, `ash`, `ash_authentication`, `bandit`, `open_api_spex`, `postgrex`, `jason`, and other declarations unchanged when they already admit the target. Inspect Ecto, Ash, and Xema constraints before adding Decimal directly. Add `{:decimal, "~> 3.0"}` only if the resolved graph proves that the security floor can otherwise be downgraded by a normal dependency resolution.

- [ ] **Step 3: Resolve only the named packages.**

Run:

```bash
mix deps.update ash ash_authentication bandit decimal ecto jason mint open_api_spex phoenix plug postgrex req xema
```

Do not run `mix deps.update --all`, add overrides, use forks, or edit package source.

- [ ] **Step 4: Check the graph and remove avoidable churn.**

Run:

```bash
mix deps.tree
git diff -- mix.exs mix.lock
```

The changed lock keys must be exactly:

```text
ash ash_authentication bandit decimal ecto jason mint open_api_spex phoenix plug postgrex req xema
```

The final versions must be `3.24.7`, `4.14.0`, `1.11.1`, `3.0.0`, `3.13.6`, `1.4.5`, `1.9.0`, `3.22.3`, `1.8.6`, `1.19.2`, `0.22.4`, `0.6.1`, and `0.17.8`, respectively. `ash_postgres 2.6.32`, `ash_sql 0.4.5`, `ecto_sql 3.13.4`, `ash_authentication_phoenix 2.15.0`, and `finch 0.21.0` must not change. If the resolver changes materially more records or needs a forbidden major version, stop and preserve the branch.

- [ ] **Step 5: Verify the security floor before moving on.**

Run:

```bash
mix deps.audit
mix compile --warnings-as-errors
```

Expected audit output is `No vulnerabilities found.`. Record the exact output for the final report. Commit only `mix.exs` and `mix.lock` if no unrelated changes appear:

```bash
git add mix.exs mix.lock
git commit -m "security: upgrade bounded dependency graph"
```

## Task 2: Add the protected UserIdentity resource and schema

**Files:**

- Create: `lib/store/accounts/user_identity.ex`.
- Modify: `lib/store/accounts/domain.ex`.
- Create: `test/store/accounts/user_identity_test.exs`.
- Create: one generated `priv/repo/migrations/*user_identities*.exs` file.
- Create: one generated `priv/resource_snapshots/repo/user_identities/*.json` file.

- [ ] **Step 1: Write the failing resource contract test.**

Create `test/store/accounts/user_identity_test.exs` with focused tests for domain registration, the extension's `user_resource`, the unique `[:strategy, :uid]` identity, and sensitive private token fields. Use `AshAuthentication.UserIdentity.Info`, `Ash.Resource.Info`, and `Ash.Domain.Info` functions available in the resolved Ash version.

- [ ] **Step 2: Run the test and verify the expected red failure.**

Run:

```bash
mix test test/store/accounts/user_identity_test.exs
```

Expected failure is that `Store.Accounts.UserIdentity` is not yet a resource or is not registered. Fix only test/API mistakes if the failure is a syntax or unavailable-function error; do not add production code before the resource test demonstrates the missing behavior.

- [ ] **Step 3: Add the minimum resource and domain registration.**

Use the exact 4.14 DSL present in `deps/ash_authentication` after Task 1. The resource shape must be equivalent to:

```elixir
defmodule Store.Accounts.UserIdentity do
  @moduledoc """
  Durable provider identity associated with an accounts user.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication.UserIdentity],
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Accounts

  attributes do
    uuid_v7_primary_key(:id)

    attribute :access_token, :string do
      allow_nil?(true)
      public?(false)
      sensitive?(true)
    end

    attribute :refresh_token, :string do
      allow_nil?(true)
      public?(false)
      sensitive?(true)
    end
  end

  user_identity do
    user_resource(Store.Accounts.User)
  end

  postgres do
    table("user_identities")
    repo(Store.Repo)
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if(always())
    end

    policy always() do
      forbid_if(always())
    end
  end
end
```

If the 4.14 verifier rejects explicit generated attributes or the policy syntax differs, use the exact accepted form from the resolved package. Preserve the required properties: AshAuthentication internal operations work, ordinary actors cannot read/reassign/destroy identities, and token attributes are private and sensitive. Register the resource beside the existing resources:

```elixir
resources do
  resource(Store.Accounts.User)
  resource(Store.Accounts.UserIdentity)
  resource(Store.Accounts.Token)
end
```

- [ ] **Step 4: Run the resource test and compile.**

Run:

```bash
mix test test/store/accounts/user_identity_test.exs
mix compile --warnings-as-errors
```

Expected result is a passing resource contract and a clean compile. Do not continue if the extension requires Ash 4, AshPostgres 3, or another forbidden major release.

- [ ] **Step 5: Generate and inspect the schema artifacts.**

Run the repository's canonical commands:

```bash
mix ash_postgres.generate_migrations
mix ash_postgres.generate_migrations --check
```

Inspect the generated files before accepting them. The migration may create only `user_identities`, and its snapshot must describe only that resource. It must contain a UUIDv7 primary key, non-null `strategy`, `uid`, and `user_id`, the `users.id` foreign key with cascade deletion where the generator supports it, and a unique `(strategy, uid)` index. If codegen emits a second unrelated migration, changes an existing table, or produces a non-cascading/non-null relationship that the generated DSL cannot correct, stop and report the exact output.

- [ ] **Step 6: Add database invariant tests.**

Extend `user_identity_test.exs` with real database checks for duplicate provider ownership, non-null `user_id`, denial of ordinary actor reads/upserts/destroys, successful private AshAuthentication interaction, and cascading deletion. The core duplicate and cascade assertions must remain database-backed:

```elixir
test "database rejects duplicate provider ownership" do
  user = Store.TestFixtures.register_user!(email: Store.TestFixtures.unique_email("identity_owner"))
  attrs = %{strategy: "google", uid: "google-duplicate", user_id: user.id}

  assert {:ok, _identity} = Ash.create(UserIdentity, attrs, domain: Store.Accounts, authorize?: false)
  assert {:error, _reason} = Ash.create(UserIdentity, attrs, domain: Store.Accounts, authorize?: false)
end
```

- [ ] **Step 7: Run focused database tests and commit the resource slice.**

Run:

```bash
mix test test/store/accounts/user_identity_test.exs
git diff --check
git add lib/store/accounts/user_identity.ex lib/store/accounts/domain.ex test/store/accounts/user_identity_test.exs priv/repo/migrations priv/resource_snapshots/repo/user_identities
git commit -m "security: add protected provider identity resource"
```

## Task 3: Wire Google identity resolution and confirmation copy

**Files:**

- Modify: `lib/store/accounts/user.ex`.
- Modify: `lib/store/accounts/emails.ex`.
- Modify: `lib/store/accounts/user/senders/send_new_user_confirmation_email.ex`.
- Modify: `test/store/accounts/authentication_test.exs`.
- Modify: `test/store_web/controllers/auth_routes_test.exs`.

- [ ] **Step 1: Write failing Google configuration and lifecycle tests.**

Add tests for `identity_resource`, `trust_email_verified?: false`, `on_untrusted_email_match: :confirm`, and `AshAuthentication.Strategy.OAuth2.IdentityChange`. Add deterministic integration cases for new users, known `(google, uid)`, existing email with no identity, valid confirmation, expired/invalid/replayed/cross-user confirmations, conflicting UID, missing UID, malformed payload, client payload substitution, and sender options.

- [ ] **Step 2: Run the tests and verify the expected red failure.**

Run:

```bash
mix test test/store/accounts/authentication_test.exs test/store_web/controllers/auth_routes_test.exs
```

Expected failures identify the missing identity resource configuration, missing `IdentityChange`, or missing sender semantics. Correct test setup errors without weakening the assertions.

- [ ] **Step 3: Add the exact 4.14 Google DSL and native change.**

Keep the existing `register_with_google` action structure and add only the native change:

```elixir
change(AshAuthentication.GenerateTokenChange)
change(AshAuthentication.Strategy.OAuth2.IdentityChange)
```

Configure the existing Google strategy as:

```elixir
google :google do
  client_id(Store.Accounts.Secrets)
  client_secret(Store.Accounts.Secrets)
  redirect_uri(Store.Accounts.Secrets)
  identity_resource(Store.Accounts.UserIdentity)
  trust_email_verified?(false)
  on_untrusted_email_match(:confirm)
  register_action_name(:register_with_google)
end
```

Do not retain `upsert_fields` or custom changes that can reassign the provider owner. If the resolved 4.14 action contract uses a package-generated identity action, preserve the package's token-only conflict update behavior and verify `user_id` is not an upsert field.

- [ ] **Step 4: Update the existing sender without adding a route.**

Keep the existing `confirm_route` and token URL. Pass the received options into the email helper:

```elixir
@impl AshAuthentication.Sender
def send(user, token, opts) do
  Emails.deliver_email_confirmation_instructions(
    user,
    url(~p"/confirm-new-user/#{token}"),
    opts
  )
end
```

The helper must keep normal copy for ordinary account confirmation and use provider-specific copy for `confirmation_type: :identity_link`, with the provider read from `opts[:provider]`. The identity-link message must say that confirming grants Google sign-in access to the existing account. It must not include `user_info`, `oauth_tokens`, UID, or any client-provided URL parameter. Preserve deterministic Swoosh test delivery.

- [ ] **Step 5: Run auth tests and inspect persisted state.**

Run:

```bash
mix test test/store/accounts/authentication_test.exs test/store_web/controllers/auth_routes_test.exs
```

For the historical-user case, assert before confirmation that the user email, confirmation timestamp, password hash, and identity count are unchanged. Assert after a valid confirmation that the identity's `strategy`, `uid`, and `user_id` match the server-retained provider payload and intended user. Assert a second confirmation attempt creates no additional identity.

- [ ] **Step 6: Run password, reset, logout, session, and LiveView regressions.**

Run:

```bash
mix test test/store/accounts/authentication_test.exs test/store_web/controllers/auth_routes_test.exs test/store_web/live/account_live_test.exs
```

Keep the existing route and LiveView helpers. Do not add a browser flow for persistence properties.

- [ ] **Step 7: Commit the OAuth slice.**

Run:

```bash
git diff --check
git add lib/store/accounts/user.ex lib/store/accounts/emails.ex lib/store/accounts/user/senders/send_new_user_confirmation_email.ex test/store/accounts/authentication_test.exs test/store_web/controllers/auth_routes_test.exs
git commit -m "security: require confirmed OAuth identity linking"
```

## Task 4: Run HTTP, database, and repository regressions

**Files:**

- Modify no application files unless a test exposes a scoped regression in the implementation.
- Test: existing HTTP, payment, comms, controller, LiveView, and Accounts test files.

- [ ] **Step 1: Run focused HTTP and provider suites.**

Run:

```bash
mix test \
  test/store_web/controllers \
  test/store_web/live \
  test/store/support/http/req_client_test.exs \
  test/store/payments \
  test/store/comms \
  test/store/accounts
```

This covers endpoint/request behavior, LiveView connection/session behavior, existing multipart coverage if present, Req-based Stripe interactions, and Req-based Postmark interactions. Do not add tests that call dependency internals directly.

- [ ] **Step 2: Recreate the local test database and check migration alignment.**

Use only the test database configured on port 5433:

```bash
MIX_ENV=test mix ecto.drop
MIX_ENV=test mix ecto.create
MIX_ENV=test mix ecto.migrate
mix ash_postgres.generate_migrations --check
```

Confirm the `user_identities` table, non-null fields, foreign key, cascade behavior, and unique provider key. Do not connect to production or any non-test database.

- [ ] **Step 3: Run the canonical static and type gates.**

Run:

```bash
mix compile --warnings-as-errors
mix deps.audit
mix check.static
mix check.types
```

Record any pre-existing dependency warnings separately from implementation failures.

- [ ] **Step 4: Run the full canonical check.**

Run:

```bash
mix check
```

Expected result is exit code 0. No performance smoke or load test is part of this plan.

## Task 5: Review the diff and open the PR

**Files:**

- Modify no files during review unless a scoped defect is found and covered by a new failing test.
- PR description: include the required DEP-SEC-03 evidence and Performance & Scaling Review.

- [ ] **Step 1: Review the complete scoped diff.**

Run:

```bash
git status --short
git diff --stat origin/main...HEAD
git diff origin/main...HEAD
git diff --check
```

Allowed categories are the dependency declarations/lockfile, UserIdentity resource and domain registration, User OAuth configuration/action, existing confirmation sender/email handling, focused tests, one UserIdentity migration, its snapshot, and the approved design/plan documents. Confirm there are no S0/performance or PR #2 files and no unexplained lock records.

- [ ] **Step 2: Recheck main before push.**

Run:

```bash
git fetch origin
git diff --name-status aea80e8306853644b9c2f103d292cbc97f35e991..origin/main
git merge-base --is-ancestor aea80e8306853644b9c2f103d292cbc97f35e991 origin/main
```

If `origin/main` advanced, inspect every intervening file. Stop if it touches dependency files, authentication resources, migrations, snapshots, auth tests, HTTP/security infrastructure, or the frozen task contract. Rebase only demonstrably unrelated changes, then rerun all affected gates.

- [ ] **Step 3: Push the dedicated branch.**

Run:

```bash
git push -u origin security/dep-sec-03-remediation
git status -sb
```

The worktree must be clean after the push.

- [ ] **Step 4: Create a separate PR without merging.**

Use:

```bash
gh pr create \
  --base main \
  --head security/dep-sec-03-remediation \
  --title "security: remediate dependency advisories and harden OAuth identity linking" \
  --body-file /tmp/dep-sec-03-pr-body.md
```

The PR body must state the baseline SHA, pushed HEAD SHA, exact 13-package table, advisory remediation including Postgrex `0.22.4`, UserIdentity migration semantics, `NONE` for email-based backfill, lifecycle and invariant coverage, migration/snapshot filenames, focused and full gate results, exact `mix deps.audit` output, CI status, untouched PR #2, untouched S0/performance scope, and no merge.

- [ ] **Step 5: Verify CI against the exact pushed HEAD.**

Run:

```bash
git rev-parse HEAD
gh pr checks security/dep-sec-03-remediation --watch
```

Report checks against that exact SHA. If a check fails because of this branch, fix it on the same branch, rerun the affected gates, push, and recheck. Do not modify unrelated code or merge the PR.

## Acceptance checklist

- [ ] Exactly 13 dependency lock records changed, with the five anchors unchanged.
- [ ] `postgrex >= 0.22.4`, `decimal >= 3.0.0`, `ash_authentication >= 4.14.0`, `phoenix >= 1.8.6`, `bandit >= 1.11.1`, `plug >= 1.19.2`, `mint >= 1.9.0`, and `req >= 0.6.1` are directly verified from `mix.lock`.
- [ ] `mix deps.audit` prints `No vulnerabilities found.`.
- [ ] `Store.Accounts.UserIdentity` is registered and backed by `user_identities`.
- [ ] Google provider ownership uses `(strategy, uid)`, never email.
- [ ] Existing local accounts with a matching email require native confirmation even when the provider says the email is verified.
- [ ] Confirmation payload is retained server-side, and client substitution cannot change it.
- [ ] Valid confirmation links once, then becomes unusable. Invalid, expired, replayed, cross-user, conflicting, malformed, and missing-UID attempts create no identity.
- [ ] Database enforces non-null ownership, unique provider identity, and safe user deletion behavior.
- [ ] Password, reset, normal confirmation, logout/session, LiveView, HTTP, Req, Postmark, Stripe, and database regressions pass.
- [ ] `mix compile --warnings-as-errors`, `mix check.static`, `mix check.types`, and `mix check` pass.
- [ ] Branch is pushed, clean, and has an open PR against `main`; no merge occurred.
