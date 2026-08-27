# `src/shared` Module

## Purpose

Own the project-dependency-free infrastructure contracts shared by executables and future domain libraries: safe errors, structured logging, PostgreSQL and Redis lifecycles, bounded outbound HTTP, explicit tenant context, and the integration-event outbox port.

## Key files

- `src/shared/errors.ml` / `.mli` — canonical validated error envelope
- `src/shared/logging.ml` / `.mli` — typed allow-listed JSON logging
- `src/shared/db_pool.ml` / `.mli` — PostgreSQL startup, cached use, and terminal shutdown
- `src/shared/migration_catalog.ml` / `.mli` — explicit ordered compile-time catalog, exact SQL bytes, six-digit filename/version validation, and restricted Caqti statement parsing
- `src/shared/migration_runner.ml` / `.mli` — one-connection advisory-locked application, transaction-local schema scope, SHA-256/prefix drift checks, transactional ledger writes, and read-only status/current
- `src/shared/redis_queue.ml` / `.mli` — bounded queues, owned locks, progress Streams, and one terminal Redis lifecycle
- `src/shared/http_client.ml` / `.mli` — validated outbound requests, bounded deadlines/concurrency, retries, and response decoding
- `src/shared/tenant_context.ml` / `.mli` — immutable tenant and actor identity with carrier-viewer scope invariants
- `src/shared/event_outbox.ml` / `.mli` — bounded integration events and caller-transaction writer port
- `src/shared/process_runner.ml` / `.mli` — shell-free literal argv, allowlisted environment, independent I/O caps, deadline/cancellation, process-tree cleanup, and atomic safe capture
- `src/shared/dune` — unwrapped `fca_shared` plus dependency-free-tier `fca_process_runner` libraries

## Dependencies

- Upstream: external `logs`, `yojson`, `unix`, `lwt.unix`, `uri`, `redis`, `redis-lwt`, `cohttp`, `cohttp-lwt`, `cohttp-lwt-unix`, `caqti`, `caqti-lwt.unix`, and `caqti-driver-postgresql`; neither shared library imports another `fca_*` project library.
- Downstream: future auth/domain/job/UI libraries and executable composition import `fca_shared` according to the downward-only hierarchy.

## Tests

- `tests/unit/errors_test.ml` and `tests/unit/logging_test.ml` enforce typed construction, exact JSON contracts, filtering, escaping, and non-leakage.
- `tests/integration/db_pool_test.ml` and `migration_runner_test.ml` through `tests/integration/run_postgres16.sh` enforce real PostgreSQL 16 lifecycle plus the exact production catalog/runner/compiled CLI: ledger-only fresh apply, idempotency, timezone instant, same/cross-schema concurrency, local search path, parser dialect, drift, rollback, tenant-leading test mechanics, and cleanup. No Phase 1/3 application migration is claimed.
- `tests/unit/tenant_context_test.ml` and `tests/unit/event_outbox_test.ml` enforce pure identity/scope/event/writer contracts.
- `tests/integration/redis_queue_test.ml` through `tests/integration/run_redis.sh` enforces real Redis 7 queues, shared queue conformance, locks, bounded Streams, lifecycle, and cleanup. `tests/fixtures/in_memory_queue.ml` runs the same queue semantics under OUnit2 as test support only, while `run_redis_parallel.sh` proves simultaneous harness identity separation and zero remaining resources.
- `tests/integration/http_client_test.ml` enforces loopback-only request validation, retry, deadline, cap, cancellation, redaction, and socket cleanup behavior.
- `tests/unit/process_runner_test.ml` executes a compiled fixture for literal argv/NUL rejection, independent bounds, exact process outcomes, timeout/cancellation, cooperative and TERM-resistant POSIX descendant termination after leader exit, and safe capture.
- `tests/architecture/dependency_hierarchy_test.ml` enforces that `fca_shared` and `fca_process_runner` have no project-library dependency.

## Cross-references

- `.agent/knowledge/foundation/observability-json-logging.md`
- `.agent/knowledge/foundation/http-error-envelope.md`
- `.agent/knowledge/foundation/db-postgres-pool.md`
- `.agent/knowledge/foundation/queue-redis.md`
- `.agent/knowledge/foundation/http-outbound-client.md`
- `.agent/knowledge/foundation/auth-tenant-context.md`
- `.agent/knowledge/foundation/events-integration-outbox.md`
- `.agent/knowledge/foundation/solver-process-boundary.md`
