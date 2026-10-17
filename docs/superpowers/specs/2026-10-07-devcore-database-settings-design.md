# DevCore database settings design

## Context

The Platform task branch already points development PostgreSQL at
`127.0.0.1:55432` and test PostgreSQL at `127.0.0.1:55433`. It uses the
project-specific `store_blueprint_dev` and `store_blueprint_test` roles and
databases, but Ecto reads only the two password variables. The repository has no
tracked `.devcore/` contract, and its README still documents a separate local
secret wrapper.

The supplied DevCore bootstrap v1.0.0 supports project-scoped roles and databases,
profile-specific env files, and literal substitution for database host, port,
role, name, and password. It does not start or stop Docker services.

## Approaches

1. Keep host, port, role, and database values in `config/dev.exs` and
   `config/test.exs`, and use DevCore only to render passwords. This is small but
   duplicates the project database contract between Elixir config and DevCore.
2. Use one `DATABASE_URL` per profile. This reduces the number of variables, but
   test database suffixes and the existing separate `Store.DirectRepo` settings
   need extra URL handling.
3. Use separate DevCore `dev` and `test` profiles to render all connection fields
   consumed by Ecto. This keeps role/database allocation in `.devcore/project.conf`,
   lets the app consume the provisioned values, and keeps dev and test credentials
   in separate ignored files. This is the recommended approach.

## Design

Add a tracked `.devcore/` contract with project key `store_blueprint`, dev and test
roles/databases matching the current Ecto settings, `TEST_ROLE_CREATEDB=yes` for
partitioned test databases, and separate render-map rows for the `dev` and `test`
profiles. Each profile template will contain that profile's host, port, role,
database, and password variables. DevCore renders them to `.env.development.local`
and `.env.test.local`, which the existing ignore rules already cover.

`config/dev.exs` will read the `STORE_DEV_DATABASE_*` variables for both
`Store.Repo` and `Store.DirectRepo`. `config/test.exs` will read the
`STORE_TEST_DATABASE_*` variables for ordinary workstation tests. It will append
the existing test suffix to the configured base database name. The separate
performance-smoke database settings will remain intact. Defaults will preserve the
current dev-core endpoints and the CI test service values, so CI does not need the
workstation bootstrap tool.

Document `devcore-project run dev -- ...` and `devcore-project run test -- ...` as
the workstation commands that load the profile credentials. Keep all secrets out
of tracked files. The contract and app config will not start, stop, or recreate
containers, change Docker files, alter production database settings, or touch PR
#128.

## Validation

- Check the DevCore contract with `devcore-project plan` and `devcore-project
  doctor` after the contract is implemented. Run `activate` only to provision the
  declared project roles/databases and generate the ignored profile files.
- Run the repository's required `mix check` through the test profile and confirm
  the existing `STORE_TEST_DB_SUFFIX` behavior.
- Run `git diff --check` and review the exact changed-file list to confirm no
  Docker lifecycle files or PR #128 files changed in this task.

## Scope

In scope: `config/dev.exs`, `config/test.exs`, the tracked `.devcore/` contract,
`.env.example`, and local setup instructions in `README.md` and
`docs/deployment/env-vars.md`.

Out of scope: Docker/Compose files and service lifecycle, PR #128, production
database configuration, schema/migrations, and application behavior outside
database connection configuration.
