# `src/solver` Module

## Purpose

Own strict solver-only configuration parsing, normalized MiniZinc/OR-Tools process-health protocols, and strict MiniZinc terminal JSON parsing without choosing an implicit fallback or implementing clearing business logic.

## Key files

- `src/solver/solver_backend.ml` / `.mli` — four-variable fail-fast config parser, strict 1–3600 second integer deadline, executable resolution, bounded probes, normalized/redacted backend report, terminal status parser
- `src/solver/dune` — downward dependency on the shared process runner
- `bin/solver_smoke.ml` — selected-backend-only composition entrypoint with deterministic default-MiniZinc skip and stable configured-path failures

## Dependencies

- Upstream: `fca_process_runner`, `lwt.unix`, `yojson`, and `unix`.
- Downstream: future clearing and replay composition may consume the typed report/parser; no solver module imports a higher domain.

## Tests

- `tests/unit/solver_backend_test.ml` runs compiled process fixtures for normalized MiniZinc/OR-Tools health, hostile version/capability redaction, fractional/out-of-range timeout rejection, accurate path-presence reasons, official-style terminal statuses, malformed output, and selected-backend no-fallback behavior.
- `dune exec bin/solver_smoke.exe` records live available/missing/unhealthy state; absent binaries are an explicit skip.

## Cross-references

- `.agent/knowledge/foundation/solver-process-boundary.md`
- `.agent/rules/solver_rules.md`
