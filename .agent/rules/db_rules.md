# PostgreSQL and Data Rules

- PostgreSQL 16 is canonical OLTP. Integration tests use local PostgreSQL, never SQLite or an alternate simplified schema.
- IDs are UUID. Every data-bearing table has `tenant_id UUID NOT NULL REFERENCES tenants(id)`; every tenant query and useful composite index leads with `tenant_id`.
- Mutable tables have `created_at` and `updated_at`; persist UTC instants and render in tenant timezone.
- Use ordered forward migrations in `migrations/`; apply all migrations through `dune exec bin/migrate.exe`. No runtime auto-DDL.
- Use parameterized Caqti requests and typed row codecs. No SQL string concatenation with request/domain values.
- Enforce status enums/check constraints, non-negative/range checks, FKs, and idempotency uniqueness in PostgreSQL as specified in PRD §4.
- Multi-row domain transitions use transactions and lock/compare current state to reject illegal races.
- Frozen evidence (`policy_snapshot`, `input_snapshot`, explanations, report snapshot, import mapping/errors, notification payload) is immutable after terminal transition except explicit retention/archive metadata.
- Query helpers require tenant context as an argument; unscoped `get_by_id` helpers are forbidden outside bootstrap lookup of tenant by credential hash.
- Prefer joins/batches over N+1 loops. Select explicit columns and paginate lists by cursor with max 100 rows.
- DuckDB is replay/analytics only; it cannot authorize or become canonical for live auctions/awards. Use temporary isolated DBs for replay tests.
- Redis contains queues, locks, and short-lived progress/cache; canonical job/award/outbox state remains PostgreSQL. Locks have ownership and expiry semantics.
- Migration tests verify constraints/indexes/statuses and both-tenant isolation after applying migrations in order.
