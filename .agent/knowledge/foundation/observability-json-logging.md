# Structured JSON Logging

## What it establishes

Application logs are typed, allow-listed JSON events emitted as exactly one escaped line through one process reporter; untyped third-party `Logs` messages are never forwarded by this reporter.

## Files

- `src/shared/logging.ml` / `src/shared/logging.mli` — abstract context/event construction, validation, serialization, filtering, reporter, and emission
- `tests/unit/logging_test.ml` — deterministic time/sink, exact fields, escaping, filtering, idempotence, and untyped-message suppression

## When to read this

Before writing code that:
- Emits an application log event or adds logging context
- Configures the process `Logs` reporter or log level
- Adds an error, request, job, entity, or duration field to observability

## Contract

- Build contexts and events only through `Logging.context` and `Logging.event`; handle typed validation failures.
- Emit only allow-listed tenant/user/role/request/job/entity/status/duration/error data. Never pass payloads, credentials, URIs, SQL, adapter errors, exceptions, or bid bodies.
- Install `Logging.configure` once at executable composition with the validated level. Reconfiguration replaces rather than stacks a reporter.
- Use `Logging.emit` with a named `Logs.Src.t`; direct third-party or arbitrary `Logs` text is deliberately ignored by the structured reporter.
- Tests inject `now` and `write`; production uses Unix time and newline-terminated stdout.

## Cross-references

- `.agent/knowledge/modules/src-shared.md`
- `.agent/rules/CODING_STANDARDS_DOMAIN.md`
- `docs/freight-capacity-auction-clearing-engine_prd.md` §10b
