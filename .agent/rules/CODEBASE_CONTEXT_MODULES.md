# Freight Capacity Auction Clearing Engine — Module Context

> Companion to `CODEBASE_CONTEXT.md`. Planned architecture from PRD §5 and §9. Last updated: 2026-07-09.

## Dependency Hierarchy

```text
shared → none
auth → shared
tenants, carriers, policies → shared, auth
imports → shared, auth, tenants, carriers, policies
auctions → shared, auth, tenants, carriers, policies, imports
solver → shared
clearing → shared, auctions, carriers, policies, solver
approvals → shared, auth, clearing, integrations
replays → shared, auctions, policies, clearing, solver
reports → shared, tenants, auctions, clearing, approvals
notifications → shared, auth, tenants, auctions, approvals, reports
integrations → shared, auth, auctions, approvals, notifications
jobs → shared and owning domain services
ui → shared, auth, and domain service interfaces
```

`shared` alone owns DB/Redis/HTTP/event infrastructure. Dream handlers validate/authenticate, call a service, and render/serialize. Solver, DuckDB CLI, and external HTTP stay behind typed adapters.

## Planned Modules

| Module | Responsibility | Deep reference |
|---|---|---|
| Shared/config | Pools, env, errors, HTTP, tenant context, outbox | `config/`, `src/shared/` |
| Auth/tenants | API key/JWT, permissions, tenant identity/users | `src/auth/`, `src/tenants/` |
| Carriers/lanes/policies | Master data and versioned policy | `src/carriers/`, `src/policies/`, auction lane code |
| Imports | Preview, normalize, stage, quarantine, commit | `src/imports/` |
| Auctions | Lifecycle, loads, bids, close/clear requests | `src/auctions/` |
| Clearing | Capability registry, model, score, explanation, persistence | `src/clearing/` |
| Solver | Process protocol, MiniZinc, OR-Tools, replay-only heuristic | `src/solver/` |
| Approvals | Local canonical approval state and optional workflow bridge | `src/approvals/` |
| Replays | DuckDB dataset, baseline/policy runner, metrics | `src/replays/` |
| Reports | Frozen tenant/auction snapshot, renderer, export | `src/reports/` |
| Notifications | In-app derived state and preferences | `src/notifications/` |
| Integrations | Optional Hub/Workflow/Webhook adapters and health | `src/integrations/` |
| Jobs | Clearing/import/replay/notification/retry/scheduled work | `src/jobs/`, `bin/worker.ml` |
| UI | Dream pages, fragments, layouts, and assets | `src/ui/` |

## Business Deep References

| Topic | Binding source |
|---|---|
| Architecture invariants and coverage matrices | PRD §2–§2b |
| Auth and tenant correctness | PRD §5.1, §8b; `auth_rules.md` |
| Intake/import correctness | PRD §5.2, §6.1 |
| Solver/clearing correctness | PRD §5.3, §6.2; `solver_rules.md` |
| Approval and override | PRD §5.4 |
| Replay isolation | PRD §5.5 |
| Explanation/report snapshot and token mapping | PRD §5.6 |
| Optional integrations | PRD §5.7, §6.3–§6.5, §6b |
| Notifications | PRD §5.8, §7b |
| UI journeys/routes/accessibility | PRD §5b, §8, §8b; `FRONTEND_IMPECCABLE_RULES.md` |
| Jobs/frequencies/persisted inputs | PRD §7; `jobs_rules.md` |
| API inventory/errors/pagination | PRD §8b; `api_rules.md` |
| Performance/health/observability | PRD §10b |
| Build order and acceptance | PRD §13 and §15 |

## Import and Boundary Conventions

- OCaml imports: standard library, third-party, then project modules; prefer qualified modules and explicit `.mli` contracts.
- Modules import only downward. Domain logic does not import Dream/Caqti/Redis/process implementations.
- Expected errors are typed results. Blocking process/file work stays off the Dream event loop.
- New route/job/adapter modules are registered from `bin/server.ml` or `bin/worker.ml` in the same change.
- HTMX is progressive enhancement over server authority, not a second state mechanism.
