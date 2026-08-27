# Freight Capacity Auction Clearing Engine — Collaboration Rules

These rules coordinate ordinary human and AI contributors. Legacy YOLO execution and runtime-owned branch/state conventions are retired and must not be recreated here.

## Branches

- `main`: production.
- `dev`: integration.
- `feature/<slug>`: contributor work targeting `dev`.
- `hotfix/<slug>`: emergency repair reconciled into both `main` and `dev`.

Do not work directly on another operator's branch or files without explicit approval. Runtime v2 owns no special branch namespace; an authorized AI or user chooses ordinary local Git mechanics under current project policy.

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

Claims coordinate humans and agents; they are not Runtime v2 acceptance packets, per-file read permits, or restrictions on unclaimed normal project access.

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

## Runtime v2 Boundary

Runtime v2 must not interpret collaboration claims, branches, progress state, test output, or worktree state as semantic acceptance. It may report literal facts to a full-rights parent Pi or nested Mesh agent. AI decides how to coordinate with active contributors, subject to ordinary system, user, and project instructions.

Legacy `.yolo/runtime-state.json`, `yolo/batch-*`, runtime claim skipping, and read-only-main-agent rules are historical conventions and are not active Runtime v2 authority. Use current Git status, collaboration claims, Mesh/Agency evidence, and explicit user instructions instead of reconstructing those conventions.
