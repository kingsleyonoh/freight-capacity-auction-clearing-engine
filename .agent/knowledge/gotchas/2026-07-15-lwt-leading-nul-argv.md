# Lwt 5.10.1 leading-NUL argv is not a literal argument

## Symptom

An argv value beginning with NUL can enter Lwt's Windows inline/unquoted command-line path instead of remaining a literal child argument.

## Cause

Lwt 5.10.1 uses a leading NUL as an internal Windows command representation marker. Passing caller data with that prefix through the process API conflicts with the marker contract.

## Solution

Reject both leading and embedded NUL in the executable, every argv value, and every environment value before spawn. Keep executable and argv separate and never expose a string/shell command API.

## Discovered in

- `.pi/agents/runs/mesh-2026-07-15T04-24-45-409Z-bpyoiz/workers/continue-phase0-solver-duckdb-compose-research/lwt-current-source-evidence.txt`
- `tests/unit/process_runner_test.ml` (`leading and embedded NUL`)

## Affects

Lwt 5.10.1 process adapters, especially cross-platform solver and CLI boundaries.
