# Freight Capacity Auction Clearing Engine — Codebase Context

> Greenfield plan from `docs/freight-capacity-auction-clearing-engine_prd.md`. Planned paths do not exist until their phase lands. Read `CODEBASE_CONTEXT_SCHEMA.md` and `CODEBASE_CONTEXT_MODULES.md` with this file.
>
> Last updated: 2026-07-14
> Template synced: 2026-07-14

## Tech Stack

| Layer | Technology |
|---|---|
| Language/build | OCaml 5.2.0, local opam switch, Dune |
| HTTP/UI | Dream, server-rendered HTML, HTMX fragments, Tailwind CSS |
| OLTP | PostgreSQL 16 via Caqti; tenant-leading indexes; JSONB evidence snapshots |
| Queue/cache | Redis; canonical job state stays in PostgreSQL |
| Replay | DuckDB via typed binding or typed CLI adapter |
| Optimization | MiniZinc process adapter; OR-Tools worker fallback |
| Runtime libraries | Lwt, Logs, Yojson/ppx_deriving_yojson |
| Tests | Alcotest/OUnit2, SQL integration harness, Playwright |
| Asset tooling | npm only for Tailwind, HTMX assets, Playwright/browser tooling |
| Hosting | Docker Compose self-hosted; Railway/Fly.io-compatible image; separate server/worker |
| Local services | local PostgreSQL, local Redis |

## Planned Structure

```text
bin/                  server, worker, migrate, setup, replay benchmark, solver smoke
config/               typed runtime config and feature flags
src/shared/           DB, Redis, HTTP, tenant context, outbox, errors
src/auth/             API key, JWT session, permission matrix
src/<domain>/         tenants, carriers, policies, auctions, imports, clearing,
                      solver, approvals, replays, reports, notifications,
                      integrations, jobs, ui
migrations/           ordered PostgreSQL migrations
tests/                unit, integration, authorization, fixtures, e2e
data/                 local DuckDB/artifacts; not canonical tenant authority
```

Detailed planned files/dependency graph: `CODEBASE_CONTEXT_MODULES.md` and PRD §9. `approvals` owns an integration-neutral workflow-approval port and depends only on `shared`, `auth`, and `clearing`. `integrations` depends downward on `approvals`, implements the port, and the executable composition layer injects that implementation; `approvals` never imports `integrations`. Schema/status/index detail: `CODEBASE_CONTEXT_SCHEMA.md` and PRD §4.

## Tenant Model

- Resolve tenant from hashed `X-API-Key` or JWT `{tenant_id,user_id,role}` in planned `src/shared/tenant_context.ml` and `src/auth/`.
- Every API/UI/job/replay/report/import/notification/callback carries explicit tenant context; route/body IDs are re-scoped before domain work.
- Permissions live in planned `src/auth/permission_matrix.ml`; unknown names fail closed. Roles: `tenant_admin`, `auction_manager`, `procurement_analyst`, `carrier_viewer`.
- Background work has one tenant and a system actor. Carrier viewers are additionally constrained by `carrier_id`.
- Config-driven UI/reports render immutable `TenantAuctionSnapshot` data from `report_exports.snapshot_json` with strict missing-token handling and sealed-bid redaction.
- Scoped tests load both records in `tests/fixtures/tenants.json` and assert bidirectional non-leakage.

## Integrations and Observability

| Boundary | Contract | Configuration |
|---|---|---|
| CSV/Parquet | Local preview → staging/quarantine → commit | upload/replay vars |
| MiniZinc / OR-Tools | Child process; versioned input/output; fail closed | solver vars |
| Notification Hub (optional) | Outbound `POST /api/events`; outbox/health failure only | `NOTIFICATION_HUB_*` |
| Workflow Engine (optional) | Outbound execute/status; local approval canonical | `WORKFLOW_ENGINE_*` |
| Webhook Engine (optional) | Inbound authenticated idempotent bid update | `WEBHOOK_ENGINE_*` |
| Error/trace/metrics | Sentry or OTLP; JSON stdout; `/metrics` | observability vars |
| Analytics | Optional PostHog-compatible capture | `POSTHOG_KEY`, `POSTHOG_HOST` |

Core readiness never depends on optional adapters. Core health: `/health`, `/health/db`, `/health/ready`; tenant adapter health: `/api/integrations/health`.

## Environment Variables

| Group | Exact variables and safe defaults/requirements |
|---|---|
| App | `APP_ENV=development`; `APP_BASE_URL=http://localhost:8080`; `APP_PORT=8080`; `LOG_LEVEL=info`; `SECRET_KEY_BASE` required |
| Data | `DATABASE_URL` required; `REDIS_URL=redis://localhost:6379/0`; local host compute uses `REPLAY_STORE_PATH=./data/replays/replay.duckdb`; `MIGRATIONS_AUTO_RUN=false` |
| Tenant seed | `SELF_REGISTRATION_ENABLED=true`; `DEFAULT_TENANT_NAME=Default Freight Auction Tenant`; `DEFAULT_ADMIN_EMAIL=admin@example.com`; `SEED_SAMPLE_DATA=true` |
| Auth | `AUTH_TOKEN_TTL_MINUTES=60`; `API_KEY_PREFIX=fca_live` |
| Import | `MAX_CSV_UPLOAD_MB=50`; `DEFAULT_CURRENCY=USD`; `BID_LATE_GRACE_SECONDS=0`; `UNKNOWN_CARRIER_POLICY=reject` |
| Solver/replay | `SOLVER_BACKEND=minizinc`; `SOLVER_TIMEOUT_SECONDS=30`; `PRODUCTION_CLEARING_REQUIRES_SOLVER=true`; `HEURISTIC_FALLBACK_FOR_REPLAY=true`; `MINIZINC_BINARY_PATH=minizinc`; `ORTOOLS_WORKER_PATH` optional; `REPLAY_MAX_ROWS=1000000`; `REPLAY_ALLOW_EXTERNAL_EVENTS=false` |
| Policy/retention | `DEFAULT_SERVICE_RISK_CAP=0.15`; `DEFAULT_MAX_CARRIER_SHARE=0.30`; `APPROVAL_EXPIRY_HOURS=24`; `AUDIT_RETENTION_DAYS=365`; `SOLVER_ARTIFACT_RETENTION_DAYS=90` |
| Notification Hub | `NOTIFICATION_HUB_ENABLED=false`; `NOTIFICATION_HUB_URL=http://localhost:3847`; `NOTIFICATION_HUB_API_KEY` optional secret; `NOTIFICATION_RETRY_ENABLED=true` |
| Workflow Engine | `WORKFLOW_ENGINE_ENABLED=false`; `WORKFLOW_ENGINE_URL=http://localhost:8000`; `WORKFLOW_ENGINE_API_KEY` optional secret; `WORKFLOW_HIGH_VALUE_APPROVAL_ID` optional; `WORKFLOW_STATUS_POLLING_ENABLED=true` |
| Webhook Engine | `WEBHOOK_ENGINE_ENABLED=false`; `WEBHOOK_ENGINE_URL=http://localhost:3000`; `WEBHOOK_ENGINE_API_KEY` optional secret; `WEBHOOK_ENGINE_RECEIVER_SECRET` optional secret |
| Integration health | `INTEGRATION_HTTP_TIMEOUT_SECONDS=5`; `INTEGRATION_HEALTH_CHECK_ENABLED=true` |
| Observability | `SENTRY_DSN` optional; `OTEL_EXPORTER_OTLP_ENDPOINT` optional; `METRICS_ENABLED=true`; `POSTHOG_KEY` optional; `POSTHOG_HOST` optional |

Secrets are environment-only, never logged, and empty in `.env.example`.

## Exact Commands

| Action | Command |
|---|---|
| Install OCaml/test deps | `opam switch create . 5.2.0 --deps-only --with-test` |
| Install asset/E2E tooling | `npm install` |
| Initialize local host storage | `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/local-storage.ps1 -Action init` or `bash scripts/local-storage.sh init` |
| Verify local host storage | `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/local-storage.ps1 -Action verify` or `bash scripts/local-storage.sh verify` |
| Start infra | `docker compose up -d postgres redis` |
| Stop infra (volumes preserved) | `docker compose down` |
| Check infra | `docker compose ps` |
| Migrate DB | `dune exec bin/migrate.exe` |
| First-run seed | `dune exec bin/setup.exe` |
| Dev server | `dune exec bin/server.exe` |
| Dev worker | `dune exec bin/worker.exe` |
| Run tests | `dune runtest --no-buffer && dune exec tests/integration/main.exe && npx playwright test` |
| Run tests (unit only) | `dune runtest --no-buffer` |
| Run tests (integration only) | `dune exec tests/integration/main.exe` |
| E2E tests | `npx playwright test` |
| Lint/type/static checks | `dune build @check` |
| Format | `dune build @fmt --auto-promote` |
| Build | `dune build @all` |
| Golden replay | `dune exec bin/replay_bench.exe -- --fixture tests/fixtures/replay/golden_12_month.parquet` |
| Solver smoke | `dune exec bin/solver_smoke.exe` |

## Shared Foundation — Directory-Per-Primitive Pointers

Read `.agent/knowledge/foundation/_index.md`, then the relevant item in full. Create/index each planned item only when its source primitive lands; never replace this with an accumulating knowledge table.

| Planned item | Contract | Planned source |
|---|---|---|
| `core-runtime-config.md` | Typed env/flags/startup validation | `config/` |
| `db-postgres-pool.md` | One Caqti pool, tenant queries, transactions | `src/shared/db_pool.ml` |
| `queue-redis.md` | Queue/lock/retry/shutdown policy | `src/shared/redis_queue.ml` |
| `http-dream-server.md` | Middleware, request IDs, errors | `bin/server.ml`, `src/shared/errors.ml` |
| `auth-tenant-context.md` | API-key/JWT/permissions | `src/shared/tenant_context.ml`, `src/auth/` |
| `http-outbound-client.md` | Timeouts/idempotency/redaction | `src/shared/http_client.ml` |
| `events-integration-outbox.md` | Transactional optional delivery | `src/shared/event_outbox.ml` |
| `solver-process-boundary.md` | Artifact/timeout/backend protocol | `src/solver/process_adapter.ml` |
| `ui-server-rendered-components.md` | Dream/HTMX/Tailwind state pattern | `src/ui/` |

## Knowledge and Deep References

- Patterns: `.agent/knowledge/patterns/_index.md`
- Gotchas: `.agent/knowledge/gotchas/_index.md` (only evidence-backed PostgreSQL/Docker items, one file each)
- Modules: `.agent/knowledge/modules/_index.md`
- Foundation: `.agent/knowledge/foundation/_index.md`
- Module/dependency deep references: `CODEBASE_CONTEXT_MODULES.md`
- Schema/data deep references: `CODEBASE_CONTEXT_SCHEMA.md`
- Binding product detail and acceptance: PRD §2–§15
- Tests: `tests/unit/`, `tests/integration/`, `tests/authorization/`, `tests/e2e/`, `tests/fixtures/`
