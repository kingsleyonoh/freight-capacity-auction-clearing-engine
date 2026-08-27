# Typed Outbound HTTP Client

## What it establishes

Optional adapters share one typed, redacted outbound HTTP boundary with bounded concurrency, request/response sizes, per-attempt deadlines, a total deadline, and idempotency-aware retries.

## Files

- `src/shared/http_client.ml` / `src/shared/http_client.mli` — URI/header/request validation, bounded client policy, incremental response reads, retry classification, and stable errors
- `tests/integration/http_client_test.ml` — pre-bound loopback HTTP fixture covering success, decoding, limits, timeouts, retries, cancellation, non-leakage, and socket cleanup

## When to read this

Before writing code that:
- Calls Notification Hub, Workflow Engine, Webhook Engine, or another HTTP adapter
- Adds retry, timeout, idempotency, body-decoding, or outbound concurrency behavior
- Maps outbound failures into adapter health or outbox retry state

## Contract

- Construct only absolute HTTP(S) requests with a host and no userinfo. Header names/values and idempotency keys are validated; callers cannot inject the managed `Idempotency-Key` header.
- Request and incrementally consumed response bodies have separate hard caps. Oversized or malformed responses are drained and fail with stable redacted errors.
- GET, HEAD, PUT, and DELETE may retry. POST and PATCH may retry only with a caller-provided validated idempotency key.
- Retry only attempt timeouts and statuses 408, 425, 429, 500, 502, 503, and 504. Decode failures, cancellation, other statuses, and unkeyed unsafe-method timeouts do not retry.
- Exponential and `Retry-After` delays are capped by policy and one total deadline. The concurrency token covers one attempt only and is released before retry sleep.
- Returned errors contain no URI query/userinfo, headers, body, credentials, protocol exception, or raw adapter response.

## Cross-references

- `.agent/knowledge/modules/src-shared.md`
- `.agent/rules/CODING_STANDARDS_DOMAIN.md`
- `.agent/knowledge/foundation/observability-json-logging.md`
- `docs/freight-capacity-auction-clearing-engine_prd.md` §6 and §9
