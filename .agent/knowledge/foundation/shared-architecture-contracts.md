# Shared Architecture Contracts Foundation

## What it establishes

Shared cached helper and architecture boundaries that feature code must use instead of creating one-off DB, Redis, HTTP, outbox, tenant, solver, or error-response implementations.

## Files

- `src/shared/cache.ml` — typed cached helper for request/startup scoped expensive values.
- `src/shared/db_pool.ml` — DB pool descriptor, redacted database URL summary, and tenant predicate helper.
- `src/shared/redis_queue.ml` — tenant-scoped Redis queue command shape and idempotency key convention.
- `src/shared/http_client.ml` — adapter HTTP request descriptor, timeout policy, retry policy, and sensitive-header redaction.
- `src/shared/event_outbox.ml` — optional integration event outbox status machine and deterministic idempotency keys.
- `src/shared/tenant_context.ml` — tenant, actor, role, request, and carrier-scope access context.
- `src/shared/errors.ml` — standard JSON error response envelope.
- `src/solver/process_adapter.ml` — solver adapter process command contract and production heuristic rejection rule.
- `tests/unit/main.ml` — behavioral tests for every shared contract.
- `tests/integration/main.ml` — documentation coverage test for these contracts.

## When to read this

Before writing any code that:
- Opens or caches a database pool, Redis queue, HTTP adapter, event outbox, solver process, or request-scoped expensive value.
- Performs tenant authorization, carrier-scoped access checks, or background-job scoping.
- Emits API/job/UI error response JSON.
- Adds feature code under `auth`, `tenants`, `imports`, `auctions`, `clearing`, `reports`, `integrations`, `jobs`, or `ui` that needs shared infrastructure.

## Contract

- Cached helper: use `Cache.get_or_compute` for per-request or startup expensive values; never duplicate independent fetches on the same request path.
- DB pool: consume `Db_pool.get_or_create`; log only `safe_database_url`; every query helper must include a tenant predicate such as `tenant_id = $tenant_id`.
- Redis queue: every queue stream and dedupe key includes `tenant_id`; jobs carry JSON payloads and idempotency keys explicitly.
- HTTP client: optional adapter calls use config-derived timeouts, retry policy, and redacted headers; never log authorization, API-key, or cookie values.
- Event outbox: optional integration emissions are persisted/retried by tenant-scoped deterministic idempotency keys and never mutate canonical auction state by themselves.
- Tenant context: feature code passes an explicit tenant context and rejects cross-tenant resources before business logic runs; carrier viewers can access only their own carrier records.
- Solver adapter: production clearing success cannot be satisfied by `heuristic_baseline`; solver runs produce tenant/auction/job-scoped artifacts.
- Error response: API/job-visible errors use the shared JSON envelope with code, message, status, request ID, and sanitized details only.

## Cross-references

- `docs/freight-capacity-auction-clearing-engine_prd.md` §2 Architecture Principles, §9 Project Structure, and §10b Caching Strategy.
- `.agent/rules/CODING_STANDARDS_DOMAIN.md` Server-Side Performance Rules and Freight Auction Clearing Domain Rules.
- `.agent/knowledge/foundation/config-runtime-config.md` for env-derived timeout and backend values.
- `.agent/knowledge/foundation/infra-local-services.md` for local Postgres/Redis/DuckDB/solver boundaries.
