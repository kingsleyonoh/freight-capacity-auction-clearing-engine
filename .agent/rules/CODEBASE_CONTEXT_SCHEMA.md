# Freight Capacity Auction Clearing Engine — Schema Context

> Companion to `CODEBASE_CONTEXT.md`. Planned schema from PRD §4; migrations are not implemented yet. Last updated: 2026-07-09.

## Global Data Contract

PostgreSQL 16 is canonical OLTP. All data-bearing rows have `tenant_id UUID NOT NULL`; tenant queries and useful composite indexes lead with `tenant_id`. IDs are UUIDs. Mutable tables have `created_at` and `updated_at`. Caqti requests are parameterized. Statuses/checks/indexes are implemented exactly from PRD §4.

DuckDB stores replay datasets/aggregates only. Redis stores queue/cache/lock state only. Neither authorizes or replaces canonical PostgreSQL auction state.

## Table Overview

| Table | Purpose / key relationships |
|---|---|
| `tenants` | Identity, API-key hash, timezone/currency, retention |
| `users` | Tenant role and optional carrier scope |
| `carriers` | Master data, equipment/regions, reliability/risk |
| `lanes` | Origin/destination/equipment, reserve/service target |
| `auction_policies` | Versioned constraints, fairness, relaxations, approvals |
| `auctions` | Mode/status/window/policy and clearing lifecycle |
| `loads` | Auction/lane demand and service requirements |
| `bids` | Idempotent carrier offer with frozen service score |
| `clearing_jobs` | Frozen policy/input, solver artifacts, infeasibility |
| `awards` | Winning bid/load/carrier and explanation |
| `clearing_decisions` | Durable decisions, constraints, redaction scope |
| `report_exports` | Frozen report/template/artifact/redaction snapshot |
| `approval_requests` | Immutable approval payload and decision state |
| `replay_runs` | Dataset, baseline, policy, frozen metrics |
| `audit_events` | Actor/entity/request-scoped audit trail |
| `integration_settings` | Non-secret adapter metadata/env-var names |
| `import_runs` | Preview/commit status, mapping and validation summary |
| `import_staging_rows` | Raw/normalized/quarantined rows |
| `import_row_errors` | Field/severity/quarantine evidence |
| `integration_outbox` | Idempotent delivery/retry state |
| `notifications` | Derived in-app and optional delivery state |
| `notification_preferences` | User event/channel preferences |

## High-Risk Invariants

- Bid uniqueness: `(tenant_id, auction_id, idempotency_key)`.
- Published/live award uniqueness: one approved/published/exported award per tenant/auction/load.
- Policy/input, explanation, report, import, approval, notification, and outbox payload snapshots remain durable for audit/retry.
- Every status transition is explicit; invalid transitions fail rather than coercing state.
- Tenant identity fields are `legal_name`, `full_legal_name`, `display_name`, `address`, `registration`, `contact`, `wordmark`, `brand_color`, `timezone`, `default_currency`, `operator_license`.
- Reports render from `report_exports.snapshot_json`; `clearing_decisions` is the explanation source of truth.
- Integration settings never store secret values.

## Detailed References

- Columns/checks/indexes/relationships: PRD §4.1–§4.20 and §4.T.
- Data conventions: `db_rules.md`.
- Auth scoping: `auth_rules.md`.
- Solver evidence: `solver_rules.md` and PRD §5.3.
- Import persistence: PRD §5.2 and §6.1.
- Deferred job data: PRD §7.
- Two-tenant fixture: `tests/fixtures/tenants.json`.
