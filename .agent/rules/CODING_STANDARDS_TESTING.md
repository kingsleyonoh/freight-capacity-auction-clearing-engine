# Freight Capacity Auction Clearing Engine — Core TDD Rules

## Required Sequence

1. Write the smallest behavioral tests first.
2. Run them and capture genuine RED output.
3. Implement minimum production code.
4. Re-run the same tests to GREEN.
5. Run the applicable integration and full regression commands.
6. Run Playwright when endpoints, pages, or interactions changed.

Setup-only work may omit RED only when no behavior exists; document the reason and still verify the setup command.

## Exact Test Tiers

| Tier | Command | Services |
|---|---|---|
| Unit/domain | `dune runtest --no-buffer` | No external services; solver fixtures allowed where PRD permits |
| Integration | `dune exec tests/integration/main.exe` | local PostgreSQL, local Redis |
| Browser/E2E | `npx playwright test` | running Dream server/worker plus local PostgreSQL, local Redis |
| Full | `dune runtest --no-buffer && dune exec tests/integration/main.exe && npx playwright test` | all above |
| Static/type | `dune build @check` | none unless generated code requires it |

Alcotest is preferred for table-driven domain/adapter contracts; OUnit2 is acceptable for existing suites. Tests live under `tests/unit`, `tests/integration`, `tests/authorization`, and `tests/e2e`.

## Anti-Cheat

Never:

- change, weaken, delete, skip, or mark expected-failure solely to make a test pass;
- mock the production code under test;
- hardcode outputs/statuses/tenant identity/solver awards for an assertion;
- fabricate command output or claim a suite ran when it did not;
- use direct SQL fixture insertion to bypass the production setup/import path when that path is under test;
- use SQLite/in-memory cache in place of PostgreSQL 16/Redis for integration claims;
- use recorded or heuristic solver output as production `single_round_spot` success evidence;
- swallow exceptions/errors or accept an unspecified error response;
- run tenant-sensitive rendering with one tenant only.

Mock only an uncontrolled external boundary or irreversible side effect. Notification Hub, Workflow Engine, and Webhook Engine use recorded contract fixtures unless an explicitly configured local/live endpoint is under test. MiniZinc/OR-Tools unit tests may use recorded process fixtures; adapter contracts must still execute production parser/model code.

## Coverage Contract

Every meaningful surface includes:

- valid happy path;
- at least one specific unhappy-path companion, and two edge cases for non-trivial behavior;
- required/malformed/boundary input;
- uniqueness, foreign-key, check, and status-transition behavior where applicable;
- authorization and tenant isolation;
- downstream timeout/non-zero/error behavior;
- idempotency for imports, bids, jobs, callbacks, outbox, approvals, and exports;
- observable business correctness across every affected UI/API/job/event/report path;
- non-leakage of internal-only or other-tenant values.

Assertions must verify exact typed result, status/error code, durable state, and relevant headers/output—not merely non-null or process completion.

## Production-Path Rules

- Apply all real PostgreSQL migrations in order.
- Resolve tenant via the real auth/middleware path for endpoint tests.
- Derive fixtures from canonical seed/import/config sources rather than parallel schemas.
- Exercise Dream routing/middleware/serialization for integration tests and real HTTP for E2E.
- Preserve immutable policy/input/report snapshots and compare hashes/artifacts where determinism matters.
- Use the actual model builder and process-adapter parser for solver contract tests.

## Validation Tiers

When a feature exposes multiple validation strictness levels, default tests to the strictest production-supported tier. A lenient test requires an explicit production-use justification. This does not create tiers where the feature has only one validator.

## RED/GREEN Evidence

Record test paths, test counts, command, actual local services, mocks with rationale, and the business rule/source of truth. RED must fail for the missing behavior rather than environment breakage. GREEN must show the same tests passing. Regression evidence states passed/failed/skipped counts and reasons.
