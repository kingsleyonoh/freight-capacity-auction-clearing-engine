# DuckDB CLI reads user init unless `-init` is controlled

## Symptom

A supposedly fixed DuckDB CLI query can execute user-local dot commands or SQL before the adapter's stdin protocol.

## Cause

The DuckDB CLI reads `~/.duckdbrc` at startup unless `-init <file>` points to a controlled alternative. A database symlink can also redirect storage unless `-nofollow` is used and paths are validated first.

## Solution

Always invoke the CLI with literal `-batch -bail -nofollow -init <controlled-empty> -json <canonical-.duckdb>` argv. Disable extension autoinstall/autoload/community behavior and external access in fixed typed stdin before locking configuration. Never retry with weaker flags or expose arbitrary SQL/INSTALL.

## Discovered in

- `.pi/agents/runs/mesh-2026-07-15T04-24-45-409Z-bpyoiz/workers/continue-phase0-solver-duckdb-compose-research/duckdb-cli-flag-evidence.txt`
- `tests/unit/duckdb_store_test.ml`

## Affects

Every DuckDB CLI replay-store or capability adapter.
