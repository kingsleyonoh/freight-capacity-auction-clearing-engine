# Freight Capacity Auction Clearing Engine — Collaboration Rules

## Branches

- `main`: production.
- `dev`: integration.
- `feature/<slug>`: contributor work targeting `dev`.
- `hotfix/<slug>`: emergency repair reconciled into both `main` and `dev`.

Do not work directly on another operator's branch or files without explicit approval.

## Claims

When operators may overlap, claim work in `docs/claims/<slug>.json` with:

```json
{
  "schemaVersion": 1,
  "task": "short task and PRD reference",
  "operator": "contributor:name",
  "tool": "pi-or-other-tool",
  "branch": "feature/slug",
  "status": "active",
  "startedAt": "ISO-8601 timestamp",
  "expectedFiles": ["path/to/file"]
}
```

- Do not claim active work owned by someone else.
- Do not edit another active claim's `expectedFiles`.
- Update expected paths when scope changes; mark claims `done` or `released` promptly.
- Claims do not replace Git isolation or review.

## Contributor Flow

1. Read task/spec and routed rules.
2. Check claims and use the correct branch.
3. Claim expected files before editing in concurrent work.
4. Follow RED/GREEN/regression with local PostgreSQL, local Redis as applicable.
5. Run static, secret, and browser gates for touched surfaces.
6. Open a review into `dev` with path-backed evidence.

## Delegated Agent Safety

- Assign disjoint file ownership and bounded permissions.
- Workers may inspect shared context but edit only assigned paths.
- Workers do not commit, push, merge, deploy, expose secrets, or start autonomous runtime controllers.
- The main agent resolves contradictory reports and approves any scope expansion.
- Preserve artifacts before recovery; never delete another worker's worktree/artifacts manually.
