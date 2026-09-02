# DEP-SEC-03 dependency security and OAuth identity migration design

## Goal

Remediate the proven 13-package dependency-security graph and migrate Google OAuth
linking to the persistent AshAuthentication 4.14 provider-identity model without
changing unrelated checkout, performance, S0, or memory-runtime work.

## Baseline and isolation

- Starting commit: `aea80e8306853644b9c2f103d292cbc97f35e991` (`origin/main`).
- Branch: `security/dep-sec-03-remediation`.
- Worktree: `/home/jcschoeman96/.config/superpowers/worktrees/Store_Blueprint_Hardening/dep-sec-03-remediation`.
- The untouched baseline suite ran with 453 tests and 0 failures.
- PR #2 (`docs/memory-runtime-hardening`) and the dirty primary checkout are out
  of scope and will not be modified.

## Approaches considered

### Native AshAuthentication 4.14 flow, selected

Add the small `Store.Accounts.UserIdentity` resource required by the resolved
AshAuthentication release. Configure Google with its identity resource, disable
trust in provider email verification, and use the package's
`AshAuthentication.Strategy.OAuth2.IdentityChange` and confirmation-required
flow. This keeps provider identity resolution, server-side pending payloads,
token revocation, and confirmation linking in the supported package path.

### Application-owned linking state

Create a separate pending-link resource and service that verifies and consumes
custom tokens. This would duplicate AshAuthentication's 4.14 implementation,
add schema and route surface, and make it easier for client-controlled data to
override the provider payload. It is outside the minimum migration.

### Email-based linking

Continue treating a matching email as proof of provider ownership. This is
rejected because it restores the vulnerable assumption that an email match is a
stable provider identity and cannot satisfy the existing-user migration
contract.

## Dependency changes

Use targeted resolver operations only. The final lockfile must change exactly
these 13 records unless the real resolver documents an unavoidable difference:

| Package | Before | After |
| --- | ---: | ---: |
| ash | 3.23.1 | 3.24.7 |
| ash_authentication | 4.13.7 | 4.14.0 |
| bandit | 1.11.0 | 1.11.1 |
| decimal | 2.3.0 | 3.0.0 |
| ecto | 3.13.5 | 3.13.6 |
| jason | 1.4.4 | 1.4.5 |
| mint | 1.7.1 | 1.9.0 |
| open_api_spex | 3.22.2 | 3.22.3 |
| phoenix | 1.8.3 | 1.8.6 |
| plug | 1.19.1 | 1.19.2 |
| postgrex | 0.22.0 | 0.22.4 |
| req | 0.5.17 | 0.6.1 |
| xema | 0.17.6 | 0.17.8 |

These compatibility anchors must remain unchanged: `ash_postgres 2.6.32`,
`ash_sql 0.4.5`, `ecto_sql 3.13.4`, `ash_authentication_phoenix 2.15.0`, and
`finch 0.21.0`.

Existing direct constraints will remain unchanged when they admit the target.
The direct Req constraint must be changed from `~> 0.5` because it excludes
0.6.1. Decimal will become a direct dependency only if inspection of the
resolved dependency constraints proves that the `>= 3.0.0` security floor is
otherwise not durable. No dependency override, fork, patch, or broad update is
allowed.

## Authentication architecture

Add `Store.Accounts.UserIdentity` in `lib/store/accounts/user_identity.ex` as an
Ash resource using `AshPostgres.DataLayer`, `AshAuthentication.UserIdentity`,
and `Ash.Policy.Authorizer`, in the `Store.Accounts` domain. Configure the
extension for `Store.Accounts.User` and the `user_identities` table using the
exact DSL accepted by AshAuthentication 4.14. The resource will use the
project's UUIDv7 primary-key convention and the extension-generated identity
attributes and actions.

Register the resource in `Store.Accounts`. Keep the resource's generated CRUD
actions private to AshAuthentication's trusted internal interaction path.
Normal actors must not list arbitrary identities, reassign `user_id`, or destroy
links. The identity's provider key and token fields are not public; access and
refresh token material is sensitive. No unlink route or UI will be added.

The User resource will use the existing `register_with_google` action with one
additional native `AshAuthentication.Strategy.OAuth2.IdentityChange`. Google
will be configured with:

```elixir
identity_resource Store.Accounts.UserIdentity
trust_email_verified? false
on_untrusted_email_match :confirm
```

The resolved package source is authoritative for the exact DSL syntax. Its
resolver must use `(strategy, uid)` as the provider ownership key, preserve the
existing account's email and fields when that key is known, reject missing or
conflicting identities, and never silently link an unknown provider identity to
an existing account by email.

## Confirmation flow

For an unknown Google UID whose presented email matches an existing local user,
AshAuthentication will abort the OAuth registration action with its native
confirmation-required result. The package's confirmation mechanism will retain
the OAuth linking payload server-side in its protected token state and send the
existing confirmation email. The payload will not be reconstructed from query
parameters, URLs, or email content.

The existing sender and confirmation route will be kept. The sender will inspect
the options supplied by the resolved package and distinguish
`confirmation_type: :identity_link` with `provider: :google` from normal account
confirmation. Identity-link copy will say that confirming grants Google
sign-in access to the existing account. It will not expose OAuth tokens or
provider payloads.

Consuming a valid confirmation will create one identity for the stored provider
tuple and the intended user, then revoke the consumed confirmation. Expired,
invalid, replayed, cross-user, malformed, missing-UID, and conflicting-ownership
attempts will create no identity. There will be no historical email-based
backfill. Existing users acquire a Google identity only after a valid link
confirmation.

## Data integrity and migration

Use the canonical Ash/Postgres code-generation workflow after the resource and
domain are wired. Accept only the generated UserIdentity migration and its
matching snapshot. Review the generated output manually before committing it.

The migration must create only `user_identities` with:

- a non-null UUIDv7 `id` primary key;
- non-null `strategy` and `uid` provider-key columns;
- nullable access-token, refresh-token, and expiry columns with sensitive
  resource metadata;
- non-null `user_id` referencing `users.id`;
- a foreign key with `ON DELETE CASCADE` where the generated adapter supports it;
- a unique `(strategy, uid)` constraint/index.

No user, token, or other existing table will be rewritten. The migration will
contain no data backfill and no email-derived identity records.

## Lifecycle model

The lifecycle is semantic and uses AshAuthentication's confirmation/token
mechanism rather than a new persisted state field:

| State | Transition | Guard | Side effect | Terminal |
| --- | --- | --- | --- | --- |
| `unlinked` | `linked` | Valid provider response and stable UID, no conflicting owner, permitted immediate link/create | Insert exactly one `(strategy, uid, user_id)` identity | No |
| `unlinked` | `pending_confirmation` | Unknown UID, existing email candidate, email trust disabled, confirmation policy enabled | Store protected provider payload and send identity-link confirmation | No |
| `pending_confirmation` | `linked` | Correct user/provider, valid unexpired unconsumed confirmation, no conflicting owner | Insert identity and revoke confirmation | No |
| `pending_confirmation` | `expired` | Confirmation lifetime elapsed | No identity insert | Yes |
| `unlinked` or `pending_confirmation` | `rejected` | Invalid UID/payload/confirmation, cross-user use, replay, conflict, or failed trust guard | No identity insert | Yes |

## Test strategy

Use resource and integration tests for identity ownership and linking, and keep
the existing route and LiveView tests for framework paths. Coverage will include
new Google registration, known identity resolution, existing-email confirmation,
valid/expired/invalid/replayed/cross-user confirmations, conflicting UID,
missing UID, uniqueness races, payload substitution, password auth, reset,
normal email confirmation, logout/session behavior, authenticated LiveViews,
sender semantics, sensitive-field visibility, and cascading user deletion.

Run focused HTTP regressions for existing endpoint/request behavior, LiveView
connection/session behavior, repository multipart coverage, and existing Req
Stripe and Postmark tests. Do not add artificial dependency exercises.

Run clean database migration and Ash snapshot checks, the Accounts integration
suite, and the repository's canonical `mix check`, `mix check.static`, and
`mix check.types` gates where applicable. Run `mix deps.audit` and inspect every
final lock record directly. No performance or load certification is part of
this work.

## Performance and scaling review

- Hot paths are OAuth callback/session resolution and provider identity lookup.
  Warm paths are registration, confirmation, and password reset. No cold-path
  business query is changed.
- The provider lookup uses one indexed `(strategy, uid)` read. The user foreign
  key supports ownership and cascade checks. No collection preload or N+1 loop
  is introduced.
- No ETS/Redis cache is added. The identity mapping is small, authoritative
  database state, so cache invalidation and stampede protection are not needed
  for this bounded change.
- AshAuthentication's confirmation token lifetime and revocation provide
  replay protection. The database unique constraint is the final identity race
  guard.
- Existing auth telemetry and test assertions remain the observability path.
  No performance tuning or load test is permitted in this task.

## Stop conditions

Stop and preserve the branch if the target graph needs a major-version upgrade,
more than the proven dependency cluster, an override, a redesign of the native
OAuth contract, email-based historical backfill, unrelated generated schema
changes, S0/performance changes, PR #2 changes, or a material `origin/main`
scope conflict.
