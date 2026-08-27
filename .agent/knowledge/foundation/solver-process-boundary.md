# Solver Process Boundary

## What it establishes

One shell-free, bounded child-process primitive for solver and replay CLI adapters, plus explicit configured-backend health reporting with no silent fallback.

## Files

- `src/shared/process_runner.ml` / `.mli`
- `src/solver/solver_backend.ml` / `.mli`
- `bin/solver_smoke.ml`

## When to read

Read before adding a child process, solver backend, replay CLI call, timeout/cancellation path, or solver artifact capture.

## Contract

- Callers pass one resolved executable and literal argv; shell/string command paths are forbidden.
- Environment names are caller-allowlisted and NUL-bearing executable, argv, env, or oversized stdin is rejected before spawn.
- POSIX children run in a private `setsid` process group; timeout, cancellation, and cap failure share TERM → bounded grace → group-presence check/KILL → leader reap → bounded group-absence verification, even when the leader exits during TERM grace.
- Stdout and stderr drain concurrently under independent caps; success is exit 0 only, while exact exit/signal/stop outcomes remain typed and errors remain stable/redacted.
- Capture roots and namespaces reject traversal and symlinks; private artifacts use same-directory exclusive temporary files and atomic no-overwrite links.
- MiniZinc and optional OR-Tools health are reported independently as available, missing, or unhealthy. Only strict bounded semantic versions and safe capability identifiers are normalized into reports; hostile/raw child metadata is never serialized. The configured selection never changes automatically.
- Solver smoke uses the solver boundary's injected four-variable parser, accepts only integer deadlines from 1 through 3600 seconds, and never requires unrelated application/database configuration.
- The smoke executable resolves and probes only the explicitly selected backend; it does not probe or expose an unselected OR-Tools fallback surface.
- Live smoke reports a deterministic skip when default binaries are absent; configured-but-missing paths have distinct stable reasons, and fixture health is not production solver readiness.
- Windows tree termination remains unproven by the POSIX fixture and cleanup inability remains the typed `PROCESS_TERMINATION_UNAVAILABLE` result; no Windows success claim follows from POSIX evidence.

## Cross-references

- `tests/unit/process_runner_test.ml`
- `tests/unit/solver_backend_test.ml`
- `.agent/rules/solver_rules.md`
- `.agent/knowledge/modules/src-shared.md`
- `.agent/knowledge/modules/src-solver.md`
