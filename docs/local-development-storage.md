# Local development storage

Local development uses **host compute** for OCaml processes and Docker Compose only for PostgreSQL 16 and Redis 7. PostgreSQL and Redis therefore remain on Docker-managed named volumes, while DuckDB replay data and solver evidence live in ignored, repository-bound host directories. Do not add unused DuckDB or solver volumes to `docker-compose.yml`.

## Initialize and verify

From the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/local-storage.ps1 -Action init
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/local-storage.ps1 -Action verify
```

```bash
bash scripts/local-storage.sh init
bash scripts/local-storage.sh verify
```

`init` is idempotent. It creates missing directories, applies private permissions, and creates `FORMAT_VERSION` only when absent. It never deletes data, resets a store, or replaces an incompatible format marker. `verify` is read-only and fails when layout, path, link, permission, ignore, schema, or format checks fail.

The default replay database is `REPLAY_STORE_PATH=./data/replays/replay.duckdb`. An explicit script override must remain a direct `.duckdb` child of `./data/replays/`; absolute paths, parent traversal, alternate roots, symlinks, and Windows reparse points fail closed.

## Host layout and ownership

```text
data/
├── replays/
│   ├── replay.duckdb
│   ├── replay.duckdb.wal
│   └── datasets/
│       ├── incoming/                 # untrusted operator drops
│       ├── frozen/<dataset_uuid>/    # immutable source + manifest
│       └── work/<replay_run_uuid>/   # regenerable work products
└── solver-artifacts/
    ├── FORMAT_VERSION                # exact bytes: 1 followed by LF
    └── v1/<tenant_uuid>/<clearing_job_uuid>/
        ├── manifest.json
        ├── input.json
        ├── model.mzn | request.json
        ├── output.json
        ├── evidence.json
        ├── stdout.bin
        └── stderr.bin
```

`data/` is ignored as a whole. No runtime database, WAL, dataset, manifest, solver input/output, or stream capture belongs in Git. On POSIX, initializer-owned directories are mode `0700` and the format marker is `0600`. On Windows, ACL inheritance is removed from initializer-owned paths; the current user, SYSTEM, and Administrators retain access, while broad `Everyone`, `Authenticated Users`, or built-in `Users` write grants are rejected.

DuckDB remains replay/analytics state and cannot authorize or replace PostgreSQL. Solver artifacts are internal evidence. They may contain hashes or solver diagnostics and must never enter carrier/public output, logs, URLs, or environment dumps.

## Solver artifact format v1

`config/solver-artifact-manifest-v1.schema.json` is the tracked manifest contract. Each terminal job manifest records format version 1, tenant/job UUIDs, backend, normalized solver version, UTC timestamps, terminal status, and at most 32 files. Inventory paths are basenames beneath the job directory; absolute paths, separators, `..`, extra properties, credentials, environment values, and external URLs are not valid.

A future clearing-worker consumer must schema-validate and atomically finalize `manifest.json`. This setup item establishes storage and format ownership only; it does not invent an unwired solver-artifact environment variable or claim a production clearing caller exists.

## Persistence lifecycle

`docker compose restart postgres redis` and `docker compose down` preserve the named `postgres_data` and `redis_data` volumes. Redis uses AOF (`appendonly yes`, `appendfsync everysec`) plus `save 60 1`; PostgreSQL remains canonical for job, award, and outbox truth. Compose lifecycle commands do not touch host-backed `data/replays` or `data/solver-artifacts`.

Use a unique `COMPOSE_PROJECT_NAME` for disposable probes. Cleanup may remove only resources whose `com.docker.compose.project` label exactly matches that probe. Never use `docker compose down -v` against current developer state or remove old similarly named volumes without separately establishing ownership.

## Backup and retention

- **PostgreSQL:** take a transactionally consistent logical `pg_dump` and prove restore. A copy of a live volume is not a verified backup.
- **Redis:** quiesce or stop before snapshotting when continuity matters. Redis is recoverable queue/cache state, not canonical auction truth.
- **DuckDB:** quiesce writers and back up the database together with frozen dataset manifests. Never copy only a live `.wal` and call it complete.
- **Solver evidence:** retain terminal artifacts for `SOLVER_ARTIFACT_RETENTION_DAYS` (default 90) unless tenant/audit policy extends it. Encrypt backups and link them to the canonical clearing job.

## Explicit reset boundary

The init/verify scripts intentionally provide no reset action. A reset is a separate operator procedure: stop relevant processes, identify the exact store and Compose project, inspect labels/paths, confirm a current backup or accepted loss, obtain typed confirmation, and then remove only that store. PostgreSQL removal loses canonical state; Redis removal loses queues, locks, progress, and cache; removing `data/replays` loses replay datasets/database; removing `data/solver-artifacts` loses internal solver evidence. Re-run `init` only after the intentional host reset.

## Windows and OneDrive

This checkout may be under OneDrive. Git ignore does not disable sync, and OneDrive is not a database backup. DuckDB/WAL writes and atomic solver-artifact renames must not race Files-On-Demand or concurrent synchronization. Prefer a non-synced local clone for durable data. Otherwise keep `data/` always local and pause or exclude synchronization while server/worker or replay/solver processes are active.
