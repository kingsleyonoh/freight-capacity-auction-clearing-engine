# Integration Event Outbox Port

## What it establishes

Domain services can construct a bounded, secret-denying typed integration event and enqueue it through a writer port inside the caller-owned canonical PostgreSQL transaction, without granting delivery or canonical-state authority.

## Files

- `src/shared/event_outbox.ml` / `src/shared/event_outbox.mli` — event validation, target metadata, payload protection, and the caller-transaction `WRITER` port
- `tests/unit/event_outbox_test.ml` — event grammar, idempotency, target metadata, payload cap, recursive secret-field denial, and writer contract

## When to read this

Before writing code that:
- Creates an optional-adapter integration event
- Implements the future PostgreSQL `integration_outbox` writer
- Adds delivery/retry workers or adapter-specific event serialization

## Contract

- Events carry one tenant, UUID event ID, `freight_auction.{noun}.{verb}` type, bounded idempotency key, closed target, exact target URL environment-variable metadata, and a capped JSON payload.
- Payload object keys are inspected recursively after punctuation-insensitive normalization and reject password, secret, token, authorization, cookie, API-key, private-key, signature, and credential-bearing names.
- `WRITER.enqueue` requires the caller's transaction token. It never opens, commits, or rolls back a transaction.
- `Inserted` and `Existing` describe only the outbox-row idempotency decision. They never mean delivered, accepted by an adapter, or canonically succeeded.
- This boundary performs no HTTP call, retry, status transition, notification callback, or canonical auction mutation.

## Cross-references

- `.agent/knowledge/modules/src-shared.md`
- `.agent/rules/jobs_rules.md`
- `.agent/rules/CODING_STANDARDS_DOMAIN.md`
- `docs/freight-capacity-auction-clearing-engine_prd.md` §5.7 and §6b
