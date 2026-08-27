# Core Runtime Configuration

## What it establishes

One immutable, typed startup configuration snapshot validates all PRD §14 variables before infrastructure or adapters start, while effective feature flags remain disabled unless their validated parent adapter is enabled.

## Files

- `config/runtime_config.ml` / `config/runtime_config.mli` — injected environment lookup, grouped typed values, aggregated validation, abstract secrets, and redacted JSON diagnostics
- `config/feature_flags.ml` / `config/feature_flags.mli` — effective adapter and subordinate flags derived from the validated snapshot
- `config/dune` — composition-layer `fca_config` library with no project-library dependency
- `tests/unit/runtime_config_*_test.ml` and `tests/unit/feature_flags_test.ml` — inventory, parsing, invariant, non-leakage, and effective-flag contracts

## When to read this

Before writing any code that:
- Reads environment variables or adds a runtime setting
- Starts a server, worker, database, queue, solver, replay, or optional adapter
- Consumes or extends runtime feature flags
- Emits startup configuration diagnostics

## Contract

- Call `Runtime_config.load` with an injected lookup in tests or `Runtime_config.from_process_env` once at process startup; do not reload or read environment variables in domain modules.
- Refuse startup on the aggregated `validation_error list` before opening external resources.
- Keep secret constructors private. Use `Secret.with_value` only at the adapter/composition boundary that needs the credential.
- Serialize failures with `errors_to_yojson` and startup state with `redacted_summary`; never print supplied values or generic secret-bearing records.
- Derive flags with `Feature_flags.of_runtime_config`. Notification retry and workflow polling are ineffective while their parent adapter is disabled; heuristic fallback is effective only for typed `Scenario_replay` or `Local_diagnostic` scopes and never for `Production_clearing`.
- `SOLVER_TIMEOUT_SECONDS` is one strict integer from 1 through 3600 in both runtime configuration and the solver smoke parser; it becomes the process-runner deadline without accepting fractional/non-finite values.
- `ORTOOLS_WORKER_PATH` trims blank to `None`; selecting OR-Tools requires a non-empty path, while detection reports only stable normalized availability and never changes the selected backend.
- `REPLAY_MAX_ROWS` is a strict integer from 1 through 10,000,000 (default 1,000,000) injected into the replay adapter as a comparison budget, never a preallocation size. `REPLAY_ALLOW_EXTERNAL_EVENTS` must remain exactly `false` in every environment and has no enabling feature scope.
- Policy defaults are finite strict ratios: service risk is `[0,1]`, carrier share is `(0,1]`; invalid values fail startup and are never clamped.
- Approval expiry is a strict integer from 1 through 8,760 hours (default 24); audit retention is 1 through 36,500 days (default 365); solver-artifact retention is 1 through 3,650 days (default 90). Zero, negative, fractional, out-of-range, and overflowing values fail startup rather than clamp.
- Notification Hub is disabled by default. Its absolute HTTP(S) URL is validated even while disabled, and enabled production use must use HTTPS; effective notification retry remains false unless the validated parent Hub flag is enabled. The optional abstract API key normalizes blank to absent and is required only when the Hub is enabled.
- Workflow Engine is disabled by default. Its absolute HTTP(S) URL is validated even while disabled, enabled production use must use HTTPS, and its optional abstract API key normalizes blank to absent and is required only when the engine is enabled. `WORKFLOW_HIGH_VALUE_APPROVAL_ID` trims blank to absent and otherwise accepts at most 128 ASCII letters/digits/underscores/hyphens/periods beginning with a letter or digit; the PRD startup contract keeps it optional. Status polling is a strict boolean whose effective flag remains false unless the Workflow Engine is enabled.
- Webhook Engine is disabled by default. Its absolute HTTP(S) URL is validated even while disabled, enabled production use must use HTTPS, and its optional abstract API key normalizes blank to absent and is required only when the engine is enabled. Its abstract receiver secret also normalizes blank to absent and is required only when the engine is enabled.
- `INTEGRATION_HTTP_TIMEOUT_SECONDS` is a strict integer from 1 through 300 (default 5) and supplies the total outbound HTTP policy budget; an attempt deadline cannot exceed that total. Integration health checking is a strict boolean that defaults to true without changing core-readiness semantics.
- `SENTRY_DSN` is an optional abstract HTTP(S) URI that normalizes blank to absent and is exposed in summaries only as `unset`/`configured`. `OTEL_EXPORTER_OTLP_ENDPOINT` is an optional absolute HTTP(S) URI that normalizes blank to absent and must use HTTPS in production when configured.
- `METRICS_ENABLED` is a strict boolean that defaults to true; configuration alone does not claim a reachable metrics endpoint or readiness behavior. `POSTHOG_KEY` is an optional abstract secret that normalizes blank to absent and is never emitted. `POSTHOG_HOST` is an optional absolute HTTP(S) URI that normalizes blank to absent and requires HTTPS in production; a configured key requires a host, while a host without a key is valid inert configuration.
- Adapter and observability validation errors and startup summaries are value-free. These startup contracts do not claim authentication, delivery, telemetry or analytics export, consent handling, adapter availability, or readiness.
- `fca_config` is composition-layer code and imports no `fca_*` project library; inject typed values into lower layers.
- Add every future runtime variable to `known_variables`, `.env.example`, typed parsing, validation, and non-leakage tests in the same change.

## Cross-references

- `.agent/rules/CODEBASE_CONTEXT.md`
- `.agent/rules/CODEBASE_CONTEXT_MODULES.md`
- `.agent/rules/CODING_STANDARDS_DOMAIN.md`
- `docs/freight-capacity-auction-clearing-engine_prd.md` §9 and §14
