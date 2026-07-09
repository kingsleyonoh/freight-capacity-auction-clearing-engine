# Freight Capacity Auction Clearing Engine — Rules Index

> Routing map only. Read the files governing the touched surface; broad, cross-cutting, or safety-sensitive work reads the complete applicable set. Root pointer files reference this index.

## Core Context and Discipline

| File | Read when |
|---|---|
| `CODEBASE_CONTEXT.md` | Any implementation: stack, tenant model, env, exact commands, foundation pointers |
| `CODEBASE_CONTEXT_SCHEMA.md` | Schema, migrations, queries, persistence, data ownership |
| `CODEBASE_CONTEXT_MODULES.md` | Module boundaries, dependency direction, planned paths, deep references |
| `CODING_STANDARDS.md` | Every implementation/review task |
| `CODING_STANDARDS_META.md` | Skill/Mesh orchestration, environment, branches, evidence |
| `COLLABORATION_RULES.md` | Concurrent contributors, claims, branches, delegated lanes |

## Testing and Production

| File | Read when |
|---|---|
| `CODING_STANDARDS_TESTING.md` | Any tests or behavior change; RED/GREEN/regression and anti-cheat |
| `CODING_STANDARDS_TESTING_LOGIC.md` | Tenant/business correctness, edge cases, solver/import outcomes |
| `CODING_STANDARDS_TESTING_LIVE.md` | Dream integration, PostgreSQL/Redis, HTMX, solver/DuckDB/adapters |
| `CODING_STANDARDS_TESTING_E2E.md` | Real HTTP, Playwright, routes, pages, and downloads |
| `CODING_STANDARDS_DOMAIN.md` | Security, deployment, secrets, logging, performance, production readiness |

## Concentrated Domain Rules

| File | Read when |
|---|---|
| `auth_rules.md` | API keys, JWT, tenant resolution, roles, permissions |
| `db_rules.md` | PostgreSQL, Caqti, migrations, transactions, DuckDB/Redis ownership |
| `api_rules.md` | Dream routes, JSON, validation, HTMX responses, errors, pagination |
| `jobs_rules.md` | Redis queues/locks, workers, retries, schedules, outbox |
| `solver_rules.md` | Clearing models, MiniZinc/OR-Tools, artifacts, infeasibility, replay |
| `FRONTEND_IMPECCABLE_RULES.md` | Dream UI, HTMX, Tailwind, accessibility, responsive/privacy/performance |

## Knowledge Routing

Knowledge is read on demand and stored one item per file:

- `.agent/knowledge/patterns/_index.md`
- `.agent/knowledge/gotchas/_index.md`
- `.agent/knowledge/modules/_index.md`
- `.agent/knowledge/foundation/_index.md`
- `.agent/knowledge/checks/_index.md`

When a bounded rules file is added, removed, renamed, or split, update this index. When knowledge membership changes, rewrite that directory's own `_index.md`; do not add knowledge rows here.
