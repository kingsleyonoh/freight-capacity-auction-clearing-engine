# Freight Capacity Auction Clearing Engine — Production and Security Rules

## Delivery Flow

Development runs on `dev` against local PostgreSQL, local Redis. Before `main`: full tests, build/static checks, migrations, browser evidence, secret scan, and production-path solver evidence for clearing changes. Deploy migrations before separate `server` and `worker` processes. Hotfixes branch from `main`, receive targeted plus full regression evidence, and reconcile into `dev`.

## Secrets and Configuration

- Secrets come from environment variables through typed `config/runtime_config.ml`; never literals in source, SQL, tests, fixtures, docs, Docker files, logs, or agent artifacts.
- `.env` variants are local/ignored. `.env.example` contains names and safe empty/example values only.
- `integration_settings.config` stores non-secret metadata and env-var names—not values.
- Production compose/deployment uses environment substitution; never inline DB, JWT, HMAC, solver, or portfolio-service credentials.
- Never log API keys, hashes, JWTs, cookies, passwords, webhook signatures, connection URLs with credentials, bid payloads, or raw adapter error bodies.
- Run `pwsh scripts/scan-secrets.ps1 -Mode tracked` or the shell equivalent before review. If a secret leaks: rotate first, replace with env lookup, then clean history under explicit human control.

## Input, HTML, and SQL Safety

- Validate every form/API/upload/webhook boundary server-side. Enforce content type, size, enum, numeric, timestamp, UUID, and state-transition constraints.
- Caqti queries are parameterized. Dynamic identifiers come from closed trusted maps, never request strings.
- Dream templates escape untrusted content by default. Any raw HTML must come from a reviewed safe renderer.
- CSV/Parquet import previews before commit and quarantines invalid rows with field-level evidence.
- Webhook callbacks authenticate before tenant lookup and are idempotent.
- Return the canonical error envelope `{error:{code,message,details}}`; never expose stack traces or cross-tenant existence.

## Multi-Tenant Config-Driven Surfaces

Never hardcode tenant identity, legal/operator text, address, registration, contact, wordmark, license, or brand values into UI, notification, report, or export templates.

Reports use the immutable snapshot captured into `report_exports.snapshot_json`. Token inventory is backed by PRD §4 fields and `clearing_decisions`; missing tokens fail rendering. Re-renders use the frozen snapshot, not mutable tenant/auction rows.

Template tests load both tenants from `tests/fixtures/tenants.json`, render each, and reject every other-tenant literal with `TENANT_IDENTITY_LEAK`. Carrier/public renderers apply redaction before formatting.

## Authentication and Authorization

- Resolve hashed API key or signed JWT into one active tenant and active user before domain work.
- Enforce permission names from `src/auth/permission_matrix.ml`; unknown names fail startup/authorization closed.
- Scope database lookup by tenant before deciding 404/403 so existence does not leak.
- Carrier viewers require matching `carrier_id`; background jobs use one tenant-scoped system actor.
- Log safe denial context: tenant/user/request/permission/error code, never credential material.

## Logging and Observability

Emit structured JSON to stdout with `tenant_id`, `user_id` when applicable, `request_id`, module, job/entity ID, status, duration, and stable error code. Use Logs levels consistently. Trace routes, jobs, solver child processes, and integrations with propagated request/trace IDs. Core readiness reports Dream/PostgreSQL/Redis requirements separately from optional adapter degradation.

## Performance and Reliability

- Share one PostgreSQL pool, Redis policy, outbound HTTP client, config snapshot, and tenant resolver.
- Run independent Lwt operations concurrently only when transaction/order semantics permit; dependent mutations remain sequenced.
- Prefer joined/batched tenant-scoped queries to per-row loops.
- Never run blocking solver, DuckDB, or large-file work on the Dream event loop.
- Every queued operation is idempotent and persists enough state for restart/retry. Canonical DB state changes transactionally; optional delivery uses `integration_outbox`.
- After five related operations on one route/job, audit total DB/Redis/HTTP/process calls.

## Code Organization

- Thin entry points validate/authenticate, invoke a domain service, and format a response.
- Pure scoring/policy/state functions do not import Dream, Caqti, Redis, or process modules.
- Adapters own protocol translation; domain modules depend on typed interfaces/results.
- Wire routes, middleware, workers, schedules, and adapters in the same change as implementation.
- See `auth_rules.md`, `db_rules.md`, `api_rules.md`, `jobs_rules.md`, and `solver_rules.md` for concentrated contracts.

## Production Checklist

- `dune build @check` and `dune build @all` pass with warnings policy.
- Unit/integration/Playwright suites required by the touched surface pass.
- No debug prints, unresolved markers, silent catches, undocumented env vars, unwired modules, or secrets.
- Migration rollback/recovery posture and retention implications are documented.
- Optional adapters remain disabled by default and cannot roll back canonical auction state.
- Production clearing never silently uses heuristic or recorded output.
