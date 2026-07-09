# Dream API and HTML Route Rules

- Register routes through the Dream server entry point; handlers are thin and call domain services.
- Protected routes resolve tenant/user/role and exact permission before tenant-scoped resource lookup.
- API errors use `{ "error": { "code": "STABLE_CODE", "message": "safe message", "details": [] } }`; no stack traces or secret/raw child-process output.
- Validate content type, UUIDs, enums, timestamp windows, numeric ranges, upload size, pagination, and state transitions at the boundary; database constraints remain defense in depth.
- List APIs use cursor pagination, default 25/max 100, and only documented filters/sorts.
- Mutating import/bid/job/callback routes enforce documented idempotency keys and return the existing canonical result for safe duplicates.
- JSON uses explicit Yojson codecs and stable field names. Never serialize internal records wholesale.
- Full HTML and HTMX fragments share authorization/validation/service paths. HTMX responses do not bypass page-level privacy or return an extra document shell.
- Carrier/public serializers apply sealed-bid redaction before rendering. Operator-only fields never enter a carrier response and are not merely hidden with CSS.
- Request IDs propagate into audit events, queues, logs, outbox calls, and error responses/headers where specified.
- Rate-limit registration, clear, import, approval, export, test-integration, and webhook routes per PRD §8b.
- Every changed endpoint gets Dream integration coverage and real-HTTP Playwright/API E2E, including 401/403, malformed input, cross-tenant ID, duplicate, and downstream failure.
