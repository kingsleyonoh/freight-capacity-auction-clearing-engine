# Freight Capacity Auction Clearing Engine — Codebase Context

Last updated: 2026-06-16
Template synced: 2026-06-16
PRD: `docs/freight-capacity-auction-clearing-engine_prd.md`

## Project Summary

Tenant-scoped freight spot-capacity auction clearing engine. The system imports loads, lanes, carriers, bids, policies, service history, and replay datasets; runs explainable constraint-backed clearing; records solver artifacts and frozen explanations; supports approval and replay workflows; and optionally connects to portfolio Notification Hub, Workflow Engine, and Webhook Engine without making them mandatory.

## Tech Stack

| Layer | Choice |
|---|---|
| Language | OCaml 5.2 |
| HTTP/UI | Dream + server-rendered HTMX + Tailwind CSS |
| Database | PostgreSQL 16 with tenant-leading composite indexes and JSONB snapshots |
| Replay store | DuckDB |
| Queue/cache | Redis |
| Solver | MiniZinc-compatible process adapter with OR-Tools fallback and heuristic replay fixtures |
| Tests | Alcotest/OUnit, SQL migration tests, Playwright |
| Hosting | Docker Compose/self-hosted; Railway/Fly.io-compatible containers |

## Commands

| Purpose | Command |
|---|---|
| Install OCaml toolchain | `opam switch create . 5.2.0 --deps-only --with-test` |
| Install JS/dev tooling | `npm install` |
| Start infra | `docker compose up -d postgres redis` |
| Stop infra | `docker compose down` |
| Check infra | `docker compose ps` |
| Run migrations | `dune exec bin/migrate.exe` |
| First-run setup | `dune exec bin/setup.exe` |
| Dev server | `dune exec bin/server.exe` |
| Dev worker | `dune exec bin/worker.exe` |
| Run tests | `dune runtest --no-buffer && dune exec tests/integration/main.exe && npx playwright test` |
| Run tests (unit only) | `dune runtest --no-buffer` |
| Run tests (integration only) | `dune exec tests/integration/main.exe` |
| E2E tests | `npx playwright test` |
| Lint/static checks | `dune build @check` |
| Format | `dune build @fmt --auto-promote` |
| Build | `dune build @all` |
| Golden fixture replay | `dune exec bin/replay_bench.exe -- --fixture tests/fixtures/replay/golden_12_month.parquet` |
| Solver smoke | `dune exec bin/solver_smoke.exe` |

## Project Structure

Source directories: `bin/, config/, src/, migrations/, tests/, docs/`.

| Area | Planned path | Notes |
|---|---|---|
| Binaries | `bin/` | `server.ml`, `worker.ml`, `migrate.ml`, `setup.ml`, replay/solver smoke binaries |
| Runtime config | `config/` | env parsing, feature flags |
| Shared foundation | `src/shared/` | DB pool, Redis queue, HTTP client, tenant context, event outbox, errors |
| Auth/tenant | `src/auth/`, `src/tenants/` | API key/JWT resolution, permission matrix, tenant identity |
| Auction core | `src/auctions/`, `src/carriers/`, `src/policies/`, `src/imports/` | master data, import preview/staging/quarantine |
| Clearing/solver | `src/clearing/`, `src/solver/` | model builder, scoring, adapter process boundary, explanations |
| Review/replay/reporting | `src/approvals/`, `src/replays/`, `src/reports/` | approvals, DuckDB replay, frozen snapshots and exports |
| Notifications/integrations/jobs | `src/notifications/`, `src/integrations/`, `src/jobs/` | in-app notifications and optional adapters |
| UI | `src/ui/` | server-rendered HTMX screens |
| Persistence | `migrations/` | tenant-leading schema changes |
| Tests | `tests/` | unit, integration, authorization, fixtures, e2e |

## Shared Foundation

| Concern | Planned path | Establishes |
|---|---|---|
| Tenant context | `src/shared/tenant_context.ml` | Resolves tenant/user/request IDs and prevents cross-tenant access |
| Permission matrix | `src/auth/permission_matrix.ml` | Role-resource matrix from PRD §2b |
| DB pool | `src/shared/db_pool.ml` | Caqti/Postgres pool and tenant-scoped query helpers |
| Redis queue | `src/shared/redis_queue.ml` | Async jobs, locks, progress streams |
| HTTP client | `src/shared/http_client.ml` | Adapter timeouts/retries and redacted logging |
| Event outbox | `src/shared/event_outbox.ml` | Optional adapter retries and idempotency |
| Error handling | `src/shared/errors.ml` | Standard JSON error envelope from PRD §8b |
| Solver process adapter | `src/solver/process_adapter.ml` | External solver execution and artifact capture |

## Deep References

| Topic | Path |
|---|---|
| Tenant isolation tests | `tests/authorization/` |
| Import fixtures | `tests/fixtures/imports/` |
| Solver fixtures | `tests/fixtures/solver/` |
| Replay golden dataset | `tests/fixtures/replay/` |
| Notification Hub fixtures | `tests/fixtures/notification_hub/` |
| Workflow Engine fixtures | `tests/fixtures/workflow_engine/` |
| Webhook Engine fixtures | `tests/fixtures/webhook_engine/` |
| UI journeys | `tests/e2e/` |

## Database Schema Overview

Tables: tenants, users, carriers, lanes, auctions, loads, bids, auction_policies, clearing_jobs, awards, clearing_decisions, report_exports, approval_requests, replay_runs, audit_events, integration_settings, import_runs, import_staging_rows, import_row_errors, integration_outbox, notifications, notification_preferences. Every data-bearing table has `tenant_id`; every query path must use tenant-leading indexes.

## Tenant Model

Tenant is resolved by `X-API-Key` or UI JWT. Single self-hosted installations still use a default tenant. Carrier viewers may only see their own carrier-scoped bid/explanation records. Background jobs run as system actors scoped to exactly one tenant.

## External Integrations

| Integration | Status | Env vars |
|---|---|---|
| Notification Hub | Optional, disabled by default | `NOTIFICATION_HUB_ENABLED`, `NOTIFICATION_HUB_URL`, `NOTIFICATION_HUB_API_KEY` |
| Workflow Engine | Optional, disabled by default | `WORKFLOW_ENGINE_ENABLED`, `WORKFLOW_ENGINE_URL`, `WORKFLOW_ENGINE_API_KEY`, `WORKFLOW_HIGH_VALUE_APPROVAL_ID` |
| Webhook Engine | Optional, disabled by default | `WEBHOOK_ENGINE_ENABLED`, `WEBHOOK_ENGINE_URL`, `WEBHOOK_ENGINE_API_KEY`, `WEBHOOK_ENGINE_RECEIVER_SECRET` |
| Sentry/OpenTelemetry/PostHog | Optional observability | `SENTRY_DSN`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `POSTHOG_KEY`, `POSTHOG_HOST` |

## Key Patterns & Conventions

- Tenant scope is mandatory on every data access path and every artifact/export.
- Solver input, policy snapshot, solver output, and explanations are versioned artifacts.
- Production `single_round_spot` cannot report success through heuristic/recorded fixtures.
- Reports use frozen `report_exports.snapshot_json`; live tenant identity changes do not alter historical reports.
- Optional adapter failure never mutates canonical auction/award state unless the adapter is the explicit validated inbound source.
- Sealed-bid privacy redacts competitor bid amounts from carrier-facing views and exports.

## Gotchas

| Gotcha | Prevention |
|---|---|
| OCaml + JS mixed toolchains can drift | Keep OCaml source authoritative; JS only supports Tailwind/HTMX assets and Playwright |
| Solver binary missing locally | Unit tests use fixture adapters; live solver smoke is conditional, but P1 production gate must prove adapter contracts |
| Tenant template leakage | Use §4.T identity columns and snapshot APIs; never hard-code tenant names/addresses in templates |
| Optional integration outages | Store outbox/health state and retry without rolling back core auction state |
