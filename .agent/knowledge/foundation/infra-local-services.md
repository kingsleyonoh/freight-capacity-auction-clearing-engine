# Local Service Infrastructure Foundation

## What it establishes

Local service boundary for PostgreSQL, Redis, DuckDB replay storage, and solver process adapter readiness.

## Files

- `docker-compose.yml` — local Postgres/Redis services plus replay-store tooling profile.
- `src/shared/service_infrastructure.ml` — typed service summary used by server, solver smoke, and tests.
- `data/replay/.gitkeep` — durable replay directory placeholder; generated DuckDB files stay ignored.
- `tests/integration/main.ml` — compose/env/replay infrastructure checks.

## When to read this

Before writing code that:
- Starts or validates local database/cache/replay/solver dependencies.
- Adds health/readiness outputs for service dependencies.
- Extends worker, replay, clearing, or solver bootstrap behavior.

## Contract

- Postgres is exposed on local port `15439`; Redis is exposed on local port `16439`.
- DuckDB replay state is file-backed under `data/`; generated `.duckdb` and WAL files are ignored.
- Solver binaries are process-boundary dependencies (`MINIZINC_BINARY_PATH` or `ORTOOLS_WORKER_PATH`), optional for unit tests but required for production clearing success in later batches.
- Entrypoints consume `Service_infrastructure.readiness_summary` rather than duplicating service naming and endpoint logic.

## Cross-references

- `docs/freight-capacity-auction-clearing-engine_prd.md` §3 Tech Stack and §6.2 Solver Process Connector.
- `.agent/rules/CODING_STANDARDS_TESTING_LIVE.md` Mock Policy.
