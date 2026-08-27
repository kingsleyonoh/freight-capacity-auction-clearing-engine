# Test-only fixtures

None of the modules or executables in this directory is a production server, worker, route, authentication mechanism, or persistence path. Production `bin/server.ml` and `bin/worker.ml` must never depend on these libraries.

## Queue and database support

- `Queue_conformance` defines framework-neutral bounded FIFO semantics reused by the OUnit2 memory suite and the Alcotest real-Redis integration suite.
- `In_memory_queue` is a test fixture, not a production Redis replacement. Each instance owns private mutex-protected state, copies payloads, enforces exact serialized payload limits and atomic depth admission, and closes terminally.
- There is no reset, raw-storage, raw-Redis, or flush hook. Redis-only locks, Streams, authentication, failure, and lifecycle behavior remain covered against disposable real Redis.
- `Postgres_schema_harness` is integration-test support. It creates only internally generated validated/quoted schemas and transaction-local search paths. Generic probe tables in `sql_schema_test.ml` are not production migrations or Phase 1 domain tables.

Production migration coverage remains blocked until a real production migration catalog/runner exists. Tests must not add a generic SQL splitter or mark that coverage complete.

## Canonical tenant fixture

`tenants.json` is the only source for the two synthetic tenant identities used by OCaml and Playwright. `tenants.schema.json` is its Draft 2020-12 structural contract. `Tenant_fixture` is the shared OCaml loader and semantic validator; `tests/e2e/helpers/tenant-fixture.ts` independently enforces the same external contract without duplicating identity literals.

The fixture must always have schema version 1, exactly two tenants, distinct identity/registration fields, and distinct carrier/load/auction UUIDs. Carrier names, load references/labels, and auction names intentionally overlap across tenants. Recursive secret-like keys are rejected. Fixture values are public synthetic `.example.test` data only.

## Dream request probe

`Dream_tenant_probe_app` is a test-only registered middleware/router/error chain under `/__test/*`. It uses `Dream.catch`, a typed Dream field carrying `Tenant_context.t`, and `X-FCA-Test-Tenant` only as fixture selection—not API-key/JWT authentication. It returns current-tenant public fixture data, stable test errors, and non-disclosing cross-tenant 404s.

`tests/integration/dream_request_harness` runs the same builder through `Dream.request` and `Dream.test`. `tests/e2e/fixtures/http_fixture_server` compiles the same builder into a loopback-only real-HTTP fixture. Passing these tests proves reusable test infrastructure, not product route/auth coverage.

## Compiled lifecycle protocol

Protocol version 1 uses private bounded file-spool control directories:

- child readiness: `server-ready.json`, `worker-ready.json`;
- worker command: `validate_fixture` with generated request ID and requested canonical tenant ID;
- worker result: typed `validated` or stable error JSON written atomically;
- supervisor stdout: `ready`, `stopped`, or `error` JSON events;
- supervisor stdin: `{ "protocolVersion": 1, "command": "stop" }`.

The worker reloads `tenants.json` for each command and validates exact-two, overlap, UUID, identity, and no-secret invariants before success. `runtime_supervisor` launches both fixture children through production `Process_runner`, requires both ready files plus real HTTP readiness, then cancellation-reaps both children and removes control artifacts.

On a Windows host, Playwright compiles/runs the Linux fixtures in the cached exact OCaml 5.2.0/Dream alpha7 test image. Dream remains bound to container loopback; a cached Alpine `nc` sidecar in the same container network namespace exposes that loopback socket only through a uniquely published host-loopback port. Global teardown removes the sidecar, runtime container, unique network, control artifacts, and port.
