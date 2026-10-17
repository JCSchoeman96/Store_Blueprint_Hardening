# DevCore workstation database contract

This repository uses project-scoped roles and databases on the workstation's
shared `dev-core` PostgreSQL services. The tracked `.devcore/` files contain no
secrets. The bootstrap tool renders the credentials to ignored
`.env.development.local` and `.env.test.local` files with mode `0600`.

From the repository root, preview and activate the allocation:

```sh
devcore-project plan
devcore-project activate
```

Start the app with the DEV profile:

```sh
devcore-project run dev -- mix setup
devcore-project run dev -- mix phx.server
```

Run tests with the TEST profile. Add a suffix when a separate database is needed
for a parallel or isolated run:

```sh
devcore-project run test -- mix test
STORE_TEST_DB_SUFFIX=local devcore-project run test -- mix test
```

`devcore-project` provisions the declared project roles and databases and checks
their connections. It does not start, stop, or recreate containers. Dockge owns
the shared service lifecycle.
