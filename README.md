# Freight Capacity Auction Clearing Engine

The Freight Capacity Auction Clearing Engine is a tenant-scoped, sealed-bid freight procurement service. It accepts CSV/JSON/API-shaped intake, validates carrier and load eligibility, runs a solver-backed single-round clearing job, stores immutable decision evidence, and exposes redacted operator or carrier results. Notification Hub, Workflow Engine, and Webhook Engine adapters are optional and disabled by default.

## Local quick start

The supported local path uses Docker for PostgreSQL 16, Redis 7, and the exact OCaml 5.2 build environment. Keep all credentials local; `.env.example` contains names and safe placeholders only.

```powershell
Copy-Item .env.example .env.local
# Set a non-empty local POSTGRES_PASSWORD and DATABASE_URL/REDIS_URL as needed.
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/local-storage.ps1 -Action init
docker compose up -d postgres redis
docker build -t fca-release-gate:local .
```

Run the packaged commands separately so migration/setup failures are visible:

```powershell
docker run --rm --add-host host.docker.internal:host-gateway `
  -e DATABASE_URL=postgresql://postgres:local@host.docker.internal:55433/fca `
  -e APP_ENV=development -e SEED_SAMPLE_DATA=true `
  -e SECRET_KEY_BASE=local-development-secret-key-32-bytes `
  fca-release-gate:local /app/bin/setup.exe

docker run --rm --add-host host.docker.internal:host-gateway `
  -e DATABASE_URL=postgresql://postgres:local@host.docker.internal:55433/fca `
  -e REDIS_URL=redis://host.docker.internal:56379/0 `
  fca-release-gate:local /app/bin/migrate.exe
```

For a long-running local server and worker, use the same database/Redis environment with `/app/bin/server.exe` and `/app/bin/worker.exe` in separate containers. The server listens on `APP_PORT` (8080 in the image); `/health`, `/health/db`, and `/health/ready` are the liveness, database, and core-readiness probes. `GET /metrics` exposes the local Prometheus-style counters.

## Core workflow

1. Register a tenant or seed the local sample tenant and retain the one-time API key.
2. Create an auction with `mode: "single_round_spot"`, add loads, and submit carrier bids with an idempotency key.
3. Close bidding and request clearing. The worker claims the Redis job, invokes the configured MiniZinc backend, and persists solver input/output hashes and durable decisions.
4. Inspect `/api/auctions/:id/awards` and `/api/auctions/:id/explanations`. Approval-required awards remain blocked from export until canonical approval.
5. Export a frozen JSON, CSV, or HTML snapshot. PDF remains an explicit unavailable format rather than a false-ready artifact.

## Imports and CLI

The browser import wizard and the packaged `freight-auction` command use the same
staged validation path. CSV and Parquet rows are checked against the tenant's
carrier, lane, and load context; schema drift, duplicate references, unknown or
suspended carriers, and invalid values are retained as row-level errors. A
quarantined or partially invalid preview cannot be committed.

For a local packaged import, mount the source file read-only and provide the
same database, Redis, and API-key configuration as the server:

```powershell
docker run --rm --add-host host.docker.internal:host-gateway `
  -v "${PWD}:/workspace:ro" `
  -e DATABASE_URL=postgresql://postgres:local@host.docker.internal:55433/fca `
  -e REDIS_URL=redis://host.docker.internal:56379/0 `
  -e SECRET_KEY_BASE=local-development-secret-key-32-bytes `
  -e FCA_CLI_API_KEY='<local-api-key>' `
  fca-release-gate:local freight-auction import `
    --type replay_dataset --file /workspace/tests/fixtures/replay/golden_12_month.parquet
```

Parquet extraction is performed through the packaged DuckDB adapter with a
confined source path, bounded output, and the same row validation/quarantine
rules as CSV. Add `--commit` only after a validated preview.

All API responses are tenant-scoped. Carrier viewers receive only their own bids and generalized explanations; competitor amounts, raw solver coefficients, parser collision hashes, API keys, and signing material are not included in carrier/public outputs.

## Optional adapters

The three adapters are disabled unless explicitly enabled and validated. Tenant settings store non-secret environment-variable references, never secret values. Inbound Webhook Engine bid updates require the configured receiver secret and constant-time HMAC verification. Adapter failures do not make the standalone clearing path unavailable; outbox entries are idempotent and fixture-safe.

## Tests and release checks

On a host with the exact toolchain installed:

```bash
dune runtest --no-buffer
dune build @all
```

On Windows, use the repository's Docker wrapper instead:

```bash
bash scripts/exact-ocaml-command.sh runtest --no-buffer
```

After starting the packaged server and worker, the local release gate can be
run with environment-provided credentials and fixture IDs:

```powershell
$env:FCA_RELEASE_BASE_URL = 'http://localhost:18080'
$env:FCA_RELEASE_API_KEY = '<local-api-key>'
$env:FCA_RELEASE_TENANT_ID = '<tenant-uuid>'
$env:FCA_RELEASE_CARRIER_ID = '<carrier-uuid>'
$env:FCA_RELEASE_LANE_ID = '<lane-uuid>'
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/release-gate.ps1
```

The gate creates a disposable auction, proves deterministic solver clearing
and rejected-bid evidence, checks that export is blocked before approval, and
checks the frozen export after approval. It does not call a live external
service.

The integration harness covers PostgreSQL, Redis authentication/ACL, queue failure and drain recovery, HTTP behavior, migrations, replay Parquet fixtures, and the real server/worker lifecycle. Frontend evidence is run with:

```bash
npm install --ignore-scripts
npm run build:htmx
npm run build:css
npm run frontend:evidence:contracts
npm run frontend:bundle:product
npm run frontend:impeccable:audit
npm run frontend:impeccable:polish
npm run frontend:a11y:product
```

Generated local replay databases, solver artifacts, integration recordings, and runtime logs belong under ignored `data/` or test artifact directories. Do not use `docker compose down -v` against a working development database without an intentional backup/reset decision.

## Scope boundary

The production path currently implements and verifies `single_round_spot`. Multi-round bidding, emergency reclear, live external adapter delivery, managed-region deployment, OpenTelemetry/Sentry/analytics delivery, and high-volume production benchmarks require their exact external contracts or deployment hardware and are kept fail-closed or explicitly unavailable. No external service is required for the standalone import → bid → solver clear → explanation → approval → export workflow.
