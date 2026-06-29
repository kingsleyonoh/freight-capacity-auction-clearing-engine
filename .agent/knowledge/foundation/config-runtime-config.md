# Runtime Config Foundation

## What it establishes

Central environment parsing for the freight auction app, using safe local defaults and empty optional integration credentials.

## Files

- `config/runtime_config.ml` — typed runtime configuration loader.
- `.env.example` — committed env-var names and safe placeholders only.
- `tests/unit/main.ml` — unit tests for defaults and invalid numeric env values.
- `tests/integration/main.ml` — integration check that `.env.example` keeps safe placeholders.

## When to read this

Before writing code that:
- Reads environment variables.
- Adds application, database, queue, solver, replay, integration, or observability config.
- Needs a default value documented in `.env.example`.

## Contract

- Use `Runtime_config.load` instead of reading env vars directly in entrypoints or shared modules.
- Optional ecosystem API keys and secrets default to empty strings and are documented as env-var names only.
- Numeric and boolean env vars fail fast with `Invalid_argument` when malformed.
- `.env` / `.env.local` stay local-only; committed docs use placeholders such as `change-me-in-local-env`.

## Cross-references

- `docs/freight-capacity-auction-clearing-engine_prd.md` §14 Environment Variables.
- `.agent/rules/CODING_STANDARDS_DOMAIN.md` Secrets Management.
