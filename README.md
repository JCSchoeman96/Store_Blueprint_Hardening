# Store

On the standard workstation, use the shared `dev-core` services described below.
The DevCore wrapper supplies the database profile before Mix starts.

## Local development infrastructure

The workstation `dev-core` stack owns the shared PostgreSQL and Redis servers.
This repository connects to them and does not start, stop, or recreate them.

| Environment | PostgreSQL | Redis | Database | Role |
| --- | --- | --- | --- | --- |
| Development | `127.0.0.1:55432` | `127.0.0.1:56379` | `store_blueprint_dev` | `store_blueprint_dev` |
| Test | `127.0.0.1:55433` | `127.0.0.1:56380` | `store_blueprint_test` plus the existing test suffix | `store_blueprint_test` |

The tracked `.devcore/` contract declares the project roles and databases. It
contains no secrets. Preview and activate the allocation, then run workstation
Mix commands with the matching profile:

```sh
devcore-project plan
devcore-project activate
devcore-project run dev -- mix setup
devcore-project run dev -- mix phx.server
devcore-project run test -- mix test
```

DevCore writes ignored `.env.development.local` and `.env.test.local` files with
mode `0600`. `.env.example` lists safe settings for other local secret managers.
Never commit database passwords. The TEST role must remain non-superuser and have
`CREATEDB` to support partition-suffixed databases.

Tests connect only to the TEST cluster. The test Redis key prefix includes this
project, the test environment, and a per-run identifier. Cleanup scans and
deletes only that prefix. Performance smoke runs require project-isolated
PostgreSQL 18 and Redis 7 endpoints. Set `STORE_PERF_DATABASE_HOST` and
`STORE_PERF_DATABASE_PORT`, plus `STORE_PERF_REDIS_HOST` and
`STORE_PERF_REDIS_PORT`, before setting `STORE_PERF_SMOKE=true`. CI uses
job-owned ephemeral services for these runs.

`docker-compose.yml` is retained as legacy local infrastructure while its
existing containers and data are preserved. Do not use it for ordinary
development. The repository-owned `compose.yaml` is the application deployment
contract and contains no PostgreSQL or Redis services.

For production, copy `.env.production.example` to an ignored `.env.production`,
replace every placeholder, and run Compose with `--env-file .env.production`.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
