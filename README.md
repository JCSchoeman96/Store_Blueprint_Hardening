# Store

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## Local development infrastructure

The workstation `dev-core` stack owns the shared PostgreSQL and Redis servers.
This repository connects to them and does not start, stop, or recreate them.

| Environment | PostgreSQL | Redis | Database | Role |
| --- | --- | --- | --- | --- |
| Development | `127.0.0.1:55432` | `127.0.0.1:56379` | `store_blueprint_dev` | `store_blueprint_dev` |
| Test | `127.0.0.1:55433` | `127.0.0.1:56380` | `store_blueprint_test` plus the existing test suffix | `store_blueprint_test` |

Provide the PostgreSQL passwords locally as `STORE_DEV_DATABASE_PASSWORD` and
`STORE_TEST_DATABASE_PASSWORD`; never commit them. On the standard workstation,
use the local secrets wrapper for Mix tasks that connect to PostgreSQL:

```sh
~/.local/bin/with-store-blueprint-db-secrets mix setup
~/.local/bin/with-store-blueprint-db-secrets mix phx.server
```

`.env.example` is a safe template for other local secret managers. The TEST role
must remain non-superuser and have `CREATEDB` to support partition-suffixed test
databases.

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
