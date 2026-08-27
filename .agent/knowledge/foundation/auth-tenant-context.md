# Explicit Tenant Context

## What it establishes

Every request, job, and integration action can carry one immutable validated tenant and exactly one typed actor without introducing credential lookup, authorization, persistence, or process-global current context.

## Files

- `src/shared/tenant_context.ml` / `src/shared/tenant_context.mli` — abstract UUID identities, user/system/integration actors, role and carrier-scope invariants, and request correlation
- `tests/unit/tenant_context_test.ml` — UUID, two-tenant identity, actor, and carrier-viewer scope behavior

## When to read this

Before writing code that:
- Constructs or consumes tenant-scoped request/job/integration context
- Adds API-key/JWT resolution or permission checks in `src/auth`
- Introduces carrier-viewer, system, or integration actor behavior

## Contract

- Tenant, user, and carrier IDs are abstract validated UUID values; a context contains exactly one tenant and one actor.
- User actors always have a user ID and role. `Carrier_viewer` requires one carrier ID; all other roles reject carrier scope.
- System and integration actors have a validated name and no user, role, or carrier scope.
- Request IDs are validated correlation metadata. They do not authorize access.
- This module performs no credential lookup, permission decision, database access, logging, or global current-context mutation. Authentication and fail-closed permission checks remain in `src/auth`.

## Cross-references

- `.agent/knowledge/modules/src-shared.md`
- `.agent/rules/auth_rules.md`
- `.agent/rules/CODING_STANDARDS_DOMAIN.md`
- `docs/freight-capacity-auction-clearing-engine_prd.md` §5.1
