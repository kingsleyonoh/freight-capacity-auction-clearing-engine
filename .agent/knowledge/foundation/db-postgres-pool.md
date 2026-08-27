# Shared PostgreSQL Pool

## What it establishes

Each server or worker process owns exactly one race-safe Caqti/Lwt PostgreSQL pool that starts eagerly, caches one handle, normalizes failures, drains in-flight work once, and remains terminal after shutdown.

## Files

- `src/shared/db_pool.ml` / `src/shared/db_pool.mli` — process-global lifecycle, explicit pool configuration, health query, admission counting, failure normalization, and shutdown
- `tests/integration/db_pool_test.ml` — real PostgreSQL startup failure/retry, singleton/concurrency, queries, admission stop, drain waiting, and terminal behavior
- `tests/integration/run_postgres16.sh` — unique cached-image PostgreSQL 16 harness with redacted evidence and cleanup proof
- `src/shared/migration_catalog.{ml,mli}` / `migration_runner.{ml,mli}` — explicit compile-time embedded migration catalog, restricted Caqti parsing, PostgreSQL SHA-256 checksums, per-database/schema advisory locking, drift checks, and one-transaction-per-migration application through this pool
- `migrations/000001_create_schema_migrations.sql` / `bin/migrate.ml` — global ledger-only Phase 0 baseline and typed runtime-config composition with guaranteed pool shutdown
- `tests/integration/postgres_schema_harness.{ml,mli}` / `sql_schema_test.ml` / `migration_runner_test.ml` — generated-schema mechanics plus real production runner/catalog, concurrency, drift, rollback, and compiled CLI coverage

## When to read this

Before writing code that:
- Starts, obtains, uses, or shuts down PostgreSQL access
- Adds a Caqti query or database-backed service
- Changes executable startup/shutdown ordering or connection budgets

## Contract

- Composition validates configuration, unwraps the secret to a `Uri.t`, and calls `Db_pool.start`; shared/domain modules never read `DATABASE_URL` or create another pool.
- Startup uses explicit `Caqti_pool_config` values and a static parameterized `SELECT ?` before publishing `Running`; failed startup is safe and retryable.
- Use `Db_pool.with_connection`. It admits under the lifecycle mutex, releases the mutex before pool I/O/callbacks, normalizes every Caqti failure, and decrements in-flight use in a finalizer.
- Never render or log Caqti errors, URI/userinfo, SQL parameters, or credentials. Inspect only `error_code` and `error_message`.
- Shutdown stops admission, waits for active uses, drains exactly once, and is concurrent/repeated-call idempotent. `Stopped` is terminal; there is no reset API.
- Default maximum size 10 is provisional. Budget replicas × pool size against PostgreSQL before deployment.
- Integration schema names are generated internally, grammar/length validated, abstract outside the tests-only harness, and privately quoted for owned `CREATE SCHEMA` / `DROP SCHEMA ... CASCADE`. Every harness or migration transaction parameterizes `set_config` with `\"<owned-schema>\",pg_catalog`, excludes `public`, and proves transaction-local state does not leak through the pool.
- `Migration_catalog.production` is generated at build time from an explicit SQL dependency, so binaries contain exact bytes and never scan or require migration files at runtime. Caqti's `angstrom_list_parser` owns statement splitting; the catalog rejects block comments, transaction controls, dynamic parameters/expansions, missing semicolons, and invalid ordered filenames before DB access.
- `Migration_runner` holds one `Db_pool` connection for a run, locks by database/schema, validates the exact applied prefix and PostgreSQL-computed SHA-256 checksum, and inserts each ledger row in the same transaction as its migration. `status`/`current` are read-only.
- The only Phase 0 production relation is global `schema_migrations`; it is non-data-bearing operational metadata. Generic tenant-leading probe tables remain test mechanics only, and every application/domain/integration migration remains Phase 1/3 work.

## Cross-references

- `.agent/knowledge/modules/src-shared.md`
- `.agent/rules/db_rules.md`
- `docs/freight-capacity-auction-clearing-engine_prd.md` §7
