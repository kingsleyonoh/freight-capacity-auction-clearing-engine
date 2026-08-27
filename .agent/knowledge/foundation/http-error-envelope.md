# Canonical Error Envelope

## What it establishes

All transport-facing errors use validated stable upper-snake-case codes, non-empty safe messages, deterministic details, and the exact nested JSON shape `{error:{code,message,details}}`.

## Files

- `src/shared/errors.ml` / `src/shared/errors.mli` — abstract codes, details, envelopes, typed construction failures, and JSON serialization
- `tests/unit/errors_test.ml` — grammar, message validation, exact nesting, deterministic detail order, and escaping

## When to read this

Before writing code that:
- Creates or serializes an API/HTMX error
- Introduces a stable error code or client-facing detail
- Maps domain/infrastructure failures at an HTTP boundary

## Contract

- Construct `Errors.Code.t` with `Errors.Code.of_string`; invalid code text is a typed error and cannot enter an envelope.
- Construct details and envelopes with `Errors.detail` and `Errors.make`; empty messages and fields return typed validation errors.
- `Errors.to_yojson` always includes the nested `error` object and an array-valued `details`, including when empty.
- Detail ordering is caller ordering. Details may contain safe client facts only—never stack traces, raw adapter/Caqti errors, URIs, SQL, credentials, hashes, or cross-tenant existence.
- HTTP status mapping belongs to future Dream middleware/handlers, not this transport-neutral serializer.

## Cross-references

- `.agent/knowledge/modules/src-shared.md`
- `.agent/rules/CODING_STANDARDS_DOMAIN.md`
- `docs/freight-capacity-auction-clearing-engine_prd.md` §8b
