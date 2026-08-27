# Example Check — Delete Me

> Template shape for an advisory project-local check file. Delete this file once an evidence-backed AI/Mesh review adds a real check.
>
> Filename convention: `{failure_type}-{slug}.md` (lowercase, hyphenated). The `{failure_type}` is a stable descriptive category such as `tests-wont-green`, `silent-workaround`, or `regression-failure`; it is not a Runtime-owned enum. The `{slug}` is a 2-4 word descriptor of the specific pattern.

**Trigger pattern:** A precise description of when this check applies. Be specific enough that an implementation lane can review its plan against it. Examples:
- "Plan touches `tests/integration/**` AND uses any of: `vi.mock('pg')`, `jest.mock('postgres')`, `MockDB`."
- "Plan creates a route handler under `src/api/payments/` AND does NOT import from `src/payments/registry.ts`."
- "Plan modifies a Drizzle migration AND adds a column to `tenants` table without a backfill."

**Guidance:** REVISE. The responsible AI must not proceed with the triggering approach; it reviews the path-backed evidence and chooses a compliant alternative. Runtime v2 does not enforce or accept this decision.

**Recovery procedure:** What the implementation lane should do instead. Be concrete — name the file / function / pattern that should be used.
- Example: "Use the real Postgres test container per `.agent/knowledge/foundation/db-test-container.md`. Mocks in integration tests are banned by check-induced rule (see provenance below)."
- Example: "Register the new payment processor in `src/payments/registry.ts` instead of importing it directly. See `.agent/knowledge/foundation/feature-payments.md` for the registry pattern."

**Provenance:**
- **Failure type:** `{failure_type}`
- **First seen:** {YYYY-MM-DD} in `{evidence path}`
- **Recurrence evidence:** list every path-backed command/report/source artifact supporting the pattern
- **Review decision:** responsible AI/human, date, and rationale
- **Stack-class candidate:** [yes / no] — if yes, review through `/harvest-gotchas`. Stack tags detected: [list, e.g. Postgres, Drizzle].

**Retirement criteria:**
- Recent evidence shows the pattern no longer recurs, AND
- The trigger pattern's referenced files / code patterns no longer exist in the codebase (for example, the module was refactored away or the dependency removed).

Retirement is an ordinary reviewed project edit: remove the check file and its `_index.md` row. It is not a Runtime lifecycle action.
