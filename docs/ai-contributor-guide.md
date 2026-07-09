# AI Contributor Guide

Use this guide when contributing with Claude Code, Codex, Cursor, Pi, or another AI coding tool.

## Start Here

1. Work from `dev` and create a feature branch: `feature/<short-slug>`.
2. Read `docs/progress.md` and choose one unchecked task.
3. Create a claim in `docs/claims/<slug>.json` before editing.
4. Read `.agent/rules/_index.md` and the core rules it lists.
5. Use TDD: RED, GREEN, regression.
6. Run secret scan before opening a PR.

## Claim Shape

```json
{
  "schemaVersion": 1,
  "task": "[FEATURE] Add carrier-safe award explanation — PRD §5",
  "operator": "contributor:alice",
  "tool": "claude-code",
  "branch": "feature/carrier-award-explanation",
  "status": "active",
  "startedAt": "2026-07-09T15:30:00Z",
  "expectedFiles": [
    "src/clearing/award_explanation.ml",
    "src/clearing/award_explanation.mli",
    "tests/unit/clearing/award_explanation_test.ml"
  ]
}
```

## Do Not

- Do not edit another active claim's expected files.
- Do not work directly on `main`.
- Do not bypass tests or secret scanning.
- Do not rewrite shared remote history.
- Do not change `.agent/rules/`, `.agent/agents/`, `.agent/workflows/`, or `.agent/guides/` unless the task is explicitly about governance.

## PR Evidence

Include:

- task/progress item
- claim file path
- tests run and output summary
- E2E evidence if API/UI/JOB/INTEGRATION changed
- secret scan result
- notes on any scope changes
