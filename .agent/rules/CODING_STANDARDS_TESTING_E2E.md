# Freight Capacity Auction Clearing Engine — E2E Testing

## Scope

E2E means a running Dream server over a real TCP port, PostgreSQL 16, Redis, production migrations, and Playwright. In-process Dream tests are integration tests, not E2E.

Run E2E whenever a batch changes an API route, middleware order, rendered page, HTMX fragment/form, auth flow, worker-visible UI state, download, or export. Pure domain/config work may skip with `SKIPPED_NO_ENDPOINTS`; a project without a server may use `SKIPPED_NO_SERVER`. Missing initial Playwright setup is a warning, not equivalent coverage.

## Commands

- Server: `dune exec bin/server.exe`
- Worker when journey needs async clearing/import/replay: `dune exec bin/worker.exe`
- Readiness: poll `/health/ready`
- Browser/API suite: `npx playwright test`
- Full gate: `dune runtest --no-buffer && dune exec tests/integration/main.exe && npx playwright test`

## Test Layout

```text
tests/e2e/api/        real-HTTP API journeys
tests/e2e/ui/         Playwright user journeys
tests/e2e/helpers/    server/worker lifecycle, production-path seed/import helpers
test-results/         failure screenshots, traces, videos; ignored
```

## Required Journeys

- setup/login → tenant dashboard;
- import preview/errors/commit → close bids → clear → explanation → export;
- auth denial and two-tenant isolation;
- solver running/failure/infeasible/approval-required UI states as their phases land;
- carrier own-bid redaction;
- replay, notification preferences, and optional integration health as their phases land.

For UI work test 1440px, 768px, and 390px where the PRD marks the route critical. Use role/label/text locators before test IDs. Verify keyboard flow, visible focus, semantic tables/dialogs, 44px mobile targets, textual risk labels, reduced motion, and no horizontal overflow except declared dense matrices.

## API and HTMX Assertions

- Assert status, headers, body/error envelope, request ID, pagination, and tenant scoping.
- For HTMX, assert fragment versus full-document response, swap/redirect headers, validation region, and browser-visible result.
- Verify downloads through the browser event and inspect frozen export content/redaction.
- Wait on URL/text/selector or job status rather than arbitrary sleeps.

## Environment Parity

E2E uses the same OCaml build, env loader, migrations, PostgreSQL major version, Redis protocol, solver path contract, template/static paths, and container image/system binaries as deployment. Behavior-shaping test overrides must be documented.

Optional portfolio services may use recorded/local fixture endpoints. Core Postgres/Redis/Dream may not be mocked. Production credentials and shared tenant data are forbidden.

## Cleanup and Evidence

- Seed through `bin/setup.exe`, API/import paths, or explicit production fixture adapters—not ad hoc schema shortcuts.
- Each test cleans tenant-scoped data and artifacts. Lifecycle helpers always stop worker/server/child processes.
- On failure retain screenshot, trace, console, and network diagnostics.
- Evidence records server/worker ports, endpoints/journeys, viewports, pass/fail/skip counts, artifact paths, and actual services.
- A passing integration suite never justifies skipping required E2E.
