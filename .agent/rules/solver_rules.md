# Clearing, Solver, and Replay Rules

- `src/clearing/` owns freight policy/model/scoring/explanations; `src/solver/` owns process protocols. Domain code never invokes shell commands directly.
- Capture immutable eligible bid/load/carrier/lane and active policy snapshots before model construction. Awards are evaluated against those snapshots, not current mutable rows.
- Hard constraints include one award per load, capacity/equipment, reserve behavior, service risk, carrier share/fairness, and sealed-bid privacy. Keep constraint names stable for explanations.
- Production `single_round_spot` success requires a generated model artifact and parsed solver output artifact from MiniZinc or OR-Tools. Timeout, malformed output, missing artifacts, or non-zero exit fails closed.
- `heuristic_baseline` and recorded outputs are allowed only for scenario replay, explicit benchmark/local diagnostics, and unit contracts; they cannot mark production clearing succeeded.
- Solver invocations use explicit argv (no interpolated shell), bounded timeout, controlled env, unique tenant/job artifact directories, version capture, and safe error redaction.
- Every award/rejection/unassigned/relaxation result creates a durable `clearing_decisions` row with binding constraints and role-specific redaction scope.
- Infeasible runs store unsat/infeasibility evidence and ranked explicit relaxations; never relax a hard rule silently or publish an award.
- Determinism tests compare frozen input/policy hashes, model content, parsed output, awards, explanations, API/UI/export/audit paths.
- DuckDB replay uses isolated datasets, identical input hashes for policy/baseline comparison, and cannot mutate live awards or emit carrier-facing events.
- New auction-mode capabilities implement the PRD §2b registry/route/test reachability contract for their owning phase; future-phase cells are not fake placeholders.
