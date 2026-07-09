# Freight Capacity Auction Clearing Engine — Live and Integration Testing

## Do Not Mock Services We Own

Use local PostgreSQL, local Redis for integration behavior. Use the real Dream middleware/handler/service/query path. Use local filesystem/DuckDB for replay fixtures. Mocks are limited to optional external systems or irreversible effects.

Priority: local instance → dedicated dev/sandbox → recorded boundary fixture. Never replace PostgreSQL with SQLite or Redis with an in-memory approximation.

## Dream API and Handler Integration

Every endpoint, middleware, worker, and consumer needs in-process integration coverage before real-HTTP E2E:

- construct a Dream request through the registered router/middleware chain;
- resolve a real fixture API key/JWT tenant context;
- assert status, headers, content type, exact error envelope, and durable PostgreSQL/Redis effects;
- cover unauthenticated 401, unauthorized 403, cross-tenant not-found behavior, malformed input, duplicate request, and downstream failure;
- test pagination/filter/sort against real rows;
- publish queue work to local Redis and assert canonical DB outcomes and retry/idempotency.

Do not call an unregistered handler function and label it endpoint integration. Trace from router entry point to service and database.

## Server-Rendered HTMX UI Testing

This project has a frontend but not a client component framework. Test Dream-rendered documents and HTMX fragments through HTTP semantics:

- full-page GET returns semantic document landmarks, headings, labels, focus targets, and tenant-safe content;
- HTMX requests return the correct fragment and `HX-*` response behavior without duplicating the page shell;
- forms cover valid submission, validation errors, permission errors, duplicate submission, loading/disabled state contract, and redirect/swap behavior;
- fragments never become an alternate authorization path; server auth and validation apply identically;
- HTML escaping, sealed-bid redaction, strict report tokens, and cross-tenant literal exclusion are asserted;
- state transitions remain server/PostgreSQL authoritative; do not rely on hidden browser-only state.

Pure HTML rendering tests may use Alcotest/OUnit assertions over production template functions. Interactive behavior and layout are verified with Playwright, not DOM simulation libraries tied to a SPA framework.

## Solver and DuckDB Boundaries

- Unit tests execute the production model serializer/output parser against recorded fixtures.
- Process-adapter integration tests cover arguments, environment, timeout, signal/exit status, malformed JSON, artifact paths, and cleanup.
- Live solver smoke runs `dune exec bin/solver_smoke.exe` only when `MINIZINC_BINARY_PATH` or `ORTOOLS_WORKER_PATH` resolves.
- Missing solver binaries may skip live smoke with an explicit reason; they do not allow production clearing to fall back.
- Replay tests use a temporary DuckDB path and real CSV/Parquet fixtures, then prove no live award/outbox mutation.

## Optional External Adapters

Notification Hub, Workflow Engine, and Webhook Engine are disabled by default. Recorded fixtures must match documented HTTP contracts. Live/local tests require explicit enabled flags and URL/key env vars; no shared or production credentials.

Mock the HTTP boundary, not domain/outbox logic. Always execute production payload building, idempotency, redaction, outbox state transition, and response parsing.

## Isolation and Cleanup

- Use a dedicated test database/schema and Redis namespace.
- Apply all migrations before suites.
- Prefer transaction rollback for DB-isolated tests; explicitly clean committed job/E2E data.
- Use unique tenant/job/idempotency identifiers per test.
- Close pools, terminate child processes, remove temporary artifacts, and stop servers reliably.
