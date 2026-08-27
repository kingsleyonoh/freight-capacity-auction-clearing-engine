# `src/replays` Module

## Purpose

Own the typed, read-only DuckDB CLI capability boundary for replay storage. It does not own live auction state, arbitrary SQL, replay policy execution, or external events.

## Key files

- `src/replays/duckdb_store.ml` / `.mli` — canonical replay/database paths, fixed CLI argv, controlled empty init, fixed health/CSV/Parquet queries, capped output, typed errors, and an injected 1..10,000,000 row comparison budget
- `bin/replay_bench.ml` — read-only golden-fixture entry point that runs the fixed Parquet aggregate twice through the shared process boundary, checks the sibling expected cardinalities, and emits deterministic bounded JSON without live mutations or events
- `src/replays/dune` and `bin/dune` — downward dependencies on the shared process runner and replay library

## Dependencies

- Upstream: `fca_process_runner`, `lwt.unix`, `yojson`, and `unix`.
- Downstream: future replay dataset and policy services consume this adapter; live clearing never does.

## Tests

- `tests/unit/duckdb_store_test.ml` executes the production adapter against a compiled CLI fixture and verifies argv, stdin safety settings, fixed benchmark query/output parsing, canonical `.duckdb` and Parquet paths, traversal/symlink rejection, redacted process errors, and rejection at configured row-budget plus one without allocating the configured row count.
- `dune exec bin/replay_bench.exe -- --fixture tests/fixtures/replay/golden_12_month.parquet` is the live DuckDB benchmark. It requires a real DuckDB executable (or `FCA_DUCKDB_BINARY`) and fails closed rather than treating fixture output as live readiness.

## Cross-references

- `.agent/rules/db_rules.md`
- `.agent/rules/solver_rules.md`
- `.agent/knowledge/gotchas/2026-07-15-duckdb-cli-init-and-safety.md`
