# Tests — API and E2E Infrastructure

## Purpose

Reusable test infrastructure for canonical two-tenant fixture validation, the production migration catalog/runner against isolated PostgreSQL 16 schemas, registered in-process Dream requests, compiled real-HTTP server/worker lifecycle proof, and deterministic three-viewport Playwright journeys. It does not establish production route, auth, job, product-journey, or Phase 1/3 application-schema coverage.

## Key files

- `tests/fixtures/tenants.json`, `tenants.schema.json`, `tenant_fixture.{ml,mli}` — one canonical identity/overlap source and OCaml structural/semantic validation.
- `tests/fixtures/dream_tenant_probe_app.{ml,mli}` — explicitly test-only `Dream.catch` + fixture middleware + typed field + router builder.
- `tests/integration/dream_request_harness.{ml,mli}`, `dream_request_test.ml` — reusable `Dream.request`/`Dream.test` harness and registered-chain behavior.
- `tests/integration/postgres_schema_harness.{ml,mli}`, `migration_runner_test.ml`, `run_migrate_cli.sh` — isolated validated schemas that invoke the exact production catalog/runner and compiled CLI for ledger, parser, concurrency, drift, rollback, tenant-leading fixture mechanics, and cleanup proof.
- `tests/fixtures/lifecycle_protocol.{ml,mli}` — bounded versioned atomic file-spool records.
- `tests/e2e/fixtures/{http_fixture_server,worker_fixture,runtime_supervisor}.ml` — compiled test-only processes; supervisor owns `Process_runner` cancellation/reaping.
- `playwright.config.ts`, `tests/e2e/global-setup.ts`, `tests/e2e/helpers/` — exact Chromium projects, isolated Docker lifecycle, shared JSON loader, and capped redacted diagnostics.
- `tests/e2e/test-infrastructure.spec.ts` — both-tenant overlap/isolation, worker validation, non-disclosing 404, and pass-state screenshot attachments.
- `scripts/project-command.mjs` plus `.sh`/`.ps1` wrappers — literal-argv unit/integration/E2E/static/build/replay/solver dispatch and one fail-fast full lifecycle with a validated ownership label.
- `scripts/exact-ocaml-command.sh` — cached exact OCaml 5.2.0 fallback that joins only the disposable PostgreSQL/Redis test networks supplied by their harnesses.
- `tests/tooling/command_contract_test.mjs` — inventory, exact argv, shell-free execution, wrapper parity, fail-fast propagation, and success/failure cleanup contracts.

## Dependencies

Test libraries depend on `fca_shared` only for typed `Tenant_context`, and on `fca_process_runner` only in the compiled supervisor. They also use pinned Dream 1.0.0~alpha7, Lwt, Yojson, Cohttp for readiness, Alcotest, and Playwright 1.55.1 Chromium revision 1193. No production executable imports a test library.

## Tests

- `dune runtest tests/unit --force --no-buffer`
- `FCA_INTEGRATION_SUITE=dream dune exec tests/integration/main.exe`
- `FCA_INTEGRATION_SUITE=e2e-lifecycle dune exec tests/integration/main.exe`
- `FCA_INTEGRATION_SUITE=postgres FCA_POSTGRES_SCENARIO=migrations tests/integration/run_postgres16.sh -- bash scripts/exact-ocaml-command.sh dune exec tests/integration/main.exe`
- `FCA_E2E_SKIP_RUNTIME=1 npx playwright test tests/e2e/config-contract.spec.ts`
- `npx playwright test tests/e2e/test-infrastructure.spec.ts`
- `node --test tests/tooling/command_contract_test.mjs`
- `npm run test:full` (owns unique labelled dependency/runtime resources and verifies zero leftovers)

## Cross-references

- `tests/fixtures/README.md`
- `.agent/rules/CODING_STANDARDS_TESTING_LIVE.md`
- `.agent/rules/CODING_STANDARDS_TESTING_E2E.md`
- `.agent/knowledge/foundation/auth-tenant-context.md`
- `.agent/knowledge/foundation/solver-process-boundary.md`
