# Freight Capacity Auction Clearing Engine — Logic and Correctness Testing

## Mandatory Two-Tenant Fixture

Every suite touching scoped data loads at least two records from `tests/fixtures/tenants.json`. Identity values must differ for `legal_name`, `full_legal_name`, `display_name`, address, registration, contact, wordmark, brand color, timezone, currency, and operator license.

For each scoped UI/API/query/job/report/integration test:

- prove Tenant A cannot read/mutate Tenant B and vice versa;
- include overlapping carrier/load/auction names to defeat accidental name scoping;
- parametrize report/template rendering over both tenants;
- scan each rendered artifact for every other-tenant literal and fail with `TENANT_IDENTITY_LEAK` plus field/path;
- test carrier viewers are restricted by both `tenant_id` and `carrier_id`.

## Business Correctness Matrix

| Area | Canonical rule / source of truth | Internal-only values | Observable paths to compare |
|---|---|---|---|
| Auth | resolved active tenant/user and `permission_matrix` | key/password hashes, JWT internals | UI, API, jobs, callbacks, audit |
| Intake | only eligible, timely, unique bids from active compatible carriers enter clearing | parser collision hashes | preview, DB, solver input, audit |
| Clearing | awards satisfy captured policy/input and real solver artifacts | variable names, matrix indexes, competitor prices | DB, UI, API, export, audit |
| Approval | approval-required awards cannot publish/export before canonical approval | workflow key/retry internals | UI, API, export, notifications |
| Replay | replay never mutates live awards or emits external carrier events | DuckDB temp names | replay UI/report/audit/outbox |
| Reports | explanation matches durable decision and frozen snapshot; role redaction holds | raw coefficients/competitor amounts | operator/carrier UI, API, CSV/JSON/HTML |
| Integrations | optional failures do not change canonical domain state | secrets/raw error bodies | health, outbox, logs, audit |
| Notifications | notifications mirror domain state and respect preferences/critical rules | API keys/retry internals | bell/settings/outbox/audit |

Every feature test names its rule, source of truth, observable paths, and a wrong-but-running failure mode.

## Auction/Solver Cases

- Exercise all status transitions and reject invalid transitions.
- Golden fixtures cover reserve, equipment, capacity, service risk, carrier share, sealed-bid redaction, unassigned loads, and deterministic ties.
- Production `single_round_spot` requires versioned model and output artifacts; solver timeout/non-zero fails closed.
- Infeasible cases persist unsat evidence and ranked relaxation suggestions; no silent relaxation or publication.
- Scenario replay may use heuristic baseline only under the PRD's explicit replay/benchmark allowance.
- Compare repeated runs using frozen input/policy hash and deterministic expected decisions.

## Import, Queue, and Adapter Cases

- Import preview persists staging/error/quarantine evidence before commit; commit is idempotent.
- Unknown/suspended carriers, late/duplicate bids, wrong equipment, oversized files, malformed rows, schema drift, and cross-tenant IDs are covered.
- Jobs test retry, duplicate delivery, lock expiry, worker restart, and exactly-once canonical outcome.
- Optional adapters test disabled, timeout, 429/retry, non-2xx, duplicate callback, malformed signature, and unknown event behavior.

## Boundary and Performance Awareness

- Numeric constraints cover zero, negative, exact boundary, and overflow/precision behavior.
- Timestamp tests include cutoff equality, tenant timezone rendering, invalid windows, and UTC persistence.
- UUID/resource-not-found tests must not reveal cross-tenant existence.
- After a route/page reaches three or more I/O operations, measure/query-count or trace the path. After five related features, run a compound-load check.

## Test Modularity

- One behavior/module focus per test file; maximum 800 lines.
- Helpers stay small; reusable factories/builders belong under `tests/fixtures` or dedicated test support modules.
- Tests are independent, order-free, and individually runnable through Dune aliases/executables.
- Names describe freight business outcomes, not implementation calls.
- Cleanup uses rollback or explicit tenant-scoped cleanup; no shared mutable fixture state.
