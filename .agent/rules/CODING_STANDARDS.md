# Freight Capacity Auction Clearing Engine — Core Coding Standards

These rules are always active. Load `.agent/rules/_index.md` first and then the domain files governing the touched surface.

## Workflow Discipline

- Implement only the explicit request or earliest eligible `docs/progress.md` work; no silent scope expansion.
- Honor approval gates in conversation. Never use another tool's plan-mode files as a substitute.
- After a workflow, read `.agent/workflows/PIPELINE.md` and state the next applicable workflow.
- New/removed workflows must be reflected in `.agent/workflows/_index.md` and `PIPELINE.md`.
- Keep workflow count bounded. Extend an existing workflow before creating a near-duplicate.

## Project Architecture

Planned source roots are `bin/`, `config/`, and `src/`; tests live under `tests/`; SQL migrations live under `migrations/`.

Imports point downward only:

```text
shared → none
auth → shared
tenants, carriers, policies → shared, auth
imports → shared, auth, tenants, carriers, policies
auctions → shared, auth, tenants, carriers, policies, imports
solver → shared
clearing → shared, auctions, carriers, policies, solver
approvals → shared, auth, clearing
replays → shared, auctions, policies, clearing, solver
reports → shared, tenants, auctions, clearing, approvals
notifications → shared, auth, tenants, auctions, approvals, reports
integrations → shared, auth, auctions, approvals, notifications
jobs → shared plus owning domain services
ui → shared, auth, and domain service interfaces
```

`approvals` owns an integration-neutral workflow-approval port and depends only on `shared`, `auth`, and `clearing`. `integrations` depends downward on `approvals`, implements the port, and the executable composition layer injects that implementation; `approvals` never imports `integrations`.

- Domain modules never create their own PostgreSQL pool, Redis connection policy, outbound retry policy, or tenant resolver.
- Dream handlers are thin: resolve request/tenant, validate input, call one service boundary, render HTML/HTMX or serialize JSON.
- Business rules remain pure where practical and return typed results; side effects are performed by service/adaptor modules.
- MiniZinc, OR-Tools, DuckDB CLI, and external HTTP are typed process/HTTP boundaries. Never scatter shell commands through domain code.
- Server-rendered UI is not a SPA. HTMX enhances forms/fragments; authoritative state remains server/PostgreSQL backed.
- Read `CODEBASE_CONTEXT*.md` and the relevant domain rules before changing architecture.

## Imports, Naming, and OCaml Shape

- Order `open`/imports conceptually as standard library, third-party libraries, then project modules; prefer qualified module names over broad `open` at file scope.
- Every `.ml` with a reusable public contract has a deliberate `.mli`; hide constructors and internal solver/database representations.
- Files/modules and values use `snake_case`; modules/types/constructors use `PascalCase`; constants/env names use `UPPER_SNAKE_CASE`.
- Use explicit result/error types at boundaries. Do not use exceptions for expected validation, authorization, infeasibility, or adapter outcomes.
- Keep Lwt boundaries visible; do not block the Dream event loop with solver, DuckDB, or file processing.
- Use Dune libraries to enforce dependency direction. Cycles and upward imports are architecture defects.

## AI Discipline

### Scope and Dependencies
- Do not add features, helpers, packages, or abstractions absent from the PRD/task. Ask first.
- Search by name, path, exports, and foundation catalog before creating a file/function/module.
- Add dependencies to the `.opam`, Dune, or `package.json` manifest before import/use; verify the API for the pinned version.
- Do not abstract until two concrete consumers establish the contract.

### No Placeholder or Fabricated Code
- No final `TODO`, `FIXME`, `HACK`, ellipsis, placeholder implementation, unconditional success, or fake result.
- Never fabricate test output, logs, screenshots, solver artifacts, benchmark numbers, or external responses.
- Heuristic/recorded solver fixtures cannot satisfy production `single_round_spot` clearing success.

### No Silent Workarounds
- Never hardcode a value that belongs in schema, config, a snapshot, or an adapter response.
- Missing tenant/report token backing data is a schema gap: extend only when the PRD specifies it; otherwise stop and escalate.
- Do not swallow errors. Every caught error is typed/returned, logged with safe context, or re-raised at the proper boundary.
- Never truncate rules or knowledge to meet a size limit. Split bounded rules by concern; use directory-per-item knowledge.

### Verify Before Claiming
- Read the binding PRD/rule section before claiming compliance.
- Run the exact relevant command and retain output before saying tests/checks pass.
- Distinguish planned paths, fixture evidence, and live production-path evidence.
- A created module is incomplete until reachable from a registered entry point.

## Tenant and Security Invariants

- Every data-bearing record belongs to exactly one tenant; UUID lookup alone never authorizes access.
- Tenant context is explicit in UI/API/jobs/replays/reports/integrations. Every query and useful composite index leads with `tenant_id`.
- Permissions fail closed; carrier viewers are constrained to their own `carrier_id`.
- Sealed competitor bids, key hashes, password hashes, secrets, raw adapter errors, and solver internals never leak through carrier/public views.
- Reports and exports render from immutable snapshots with strict missing-field behavior.
- Secrets are environment-only. Never write real credentials in source, tests, fixtures, docs, reports, or local agent artifacts.
- Use parameterized Caqti queries; escape output through the server-rendering layer; validate upload size/type and all boundary input.
- Full security rules: `CODING_STANDARDS_DOMAIN.md`, `auth_rules.md`, `db_rules.md`, `api_rules.md`.

## TDD and Anti-Cheat

- Tests first: demonstrate RED, implement the minimum GREEN, then run regression. A setup-only item may document why no behavioral RED exists.
- Never weaken/delete/skip a failing test or modify expected behavior merely to go green.
- Test production paths. Do not replace PostgreSQL with SQLite, Redis with memory, migrations with hand-built schemas, or production seed/import paths with direct inserts.
- Every happy path has an unhappy-path companion. Tenant-scoped suites use both tenants in `tests/fixtures/tenants.json`.
- Use Alcotest/OUnit2 for OCaml logic, the PostgreSQL/Redis integration harness for boundaries, and Playwright for real HTTP/browser journeys.
- Full testing rules: `CODING_STANDARDS_TESTING*.md`.

## Shared Foundation and Knowledge

Before creating shared code:

1. Read `CODEBASE_CONTEXT*.md`.
2. Read `.agent/knowledge/foundation/_index.md`.
3. Read the matching foundation item in full.
4. Reuse the established primitive or create one bounded primitive plus index entry when the task requires it.

Unbounded knowledge is directory-per-item:

- `.agent/knowledge/patterns/NNN-slug.md`
- `.agent/knowledge/gotchas/YYYY-MM-DD-slug.md`
- `.agent/knowledge/modules/<source-path>.md`
- `.agent/knowledge/foundation/category-slug.md`
- `.agent/knowledge/checks/failure-type-slug.md`
- `docs/build-journal/NNN-batch.md`

Rewrite each directory's `_index.md` when membership changes. Never create a flat accumulating knowledge table.

## File and Function Limits

- Every `.agent/rules/*.md` file: fewer than 10,000 characters.
- Source/test file: max 800 lines; reassess at 700.
- Function: max 50 lines; keep Dream handlers substantially smaller.
- One module responsibility per file. Split by responsibility before adding another concern.
- Public module contracts must remain smaller than implementations and expose only required types/functions.

## Git and Collaboration

- `main` is production; `dev` is integration; contributor work uses `feature/<slug>`; emergency work uses `hotfix/<slug>`.
- Never commit/push without explicit approval. Never use `git add -f`; respect `.gitignore`.
- Commit format: `type(scope): imperative summary`, max 72 characters. Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `style`.
- One cohesive completed item per commit; do not mix unrelated edits.
- Respect active `docs/claims/*.json`; do not edit another operator's expected files.

## Production Readiness

Before merge to `main`:

1. `dune build @check`, `dune build @all`, unit, integration, and applicable Playwright suites pass.
2. Migrations are ordered, committed, and exercised against PostgreSQL 16.
3. New env vars are documented with safe empty/example values.
4. No debug output, unresolved markers, silent catches, unwired modules, or secrets remain.
5. UI work includes keyboard, responsive, privacy/redaction, state, and accessibility evidence.
6. Production clearing proves real solver model/output artifacts; optional adapter failures cannot change canonical auction state.
