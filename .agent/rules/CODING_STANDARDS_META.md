# Freight Capacity Auction Clearing Engine — Meta Rules

## Skill Selection and Orchestration

- Before implementation, inspect available skills and choose the most specific match for OCaml, PostgreSQL, security, testing, frontend design, browser QA, or deployment.
- Read the selected `SKILL.md` before acting; its current guardrails override remembered generic advice.
- State the selected skill briefly. If no relevant skill exists, proceed using project rules and verified upstream documentation.
- Use focused Mesh lanes for source/config discovery, implementation, and evidence when available. The main agent remains responsible for scope, approvals, and synthesis.
- Delegate by capability and bounded files, require path-backed evidence, and never let a worker commit/push or cross another lane's file ownership.
- Research unfamiliar or version-sensitive APIs before coding. Verify OCaml 5.2, Dream, Caqti, Lwt, DuckDB adapter, solver CLI, and Playwright behavior against installed/pinned versions.

## Environment

- Primary shell may be PowerShell or Git Bash on Windows. Use commands exactly as documented in `CODEBASE_CONTEXT.md`; do not translate them into a different package/runtime ecosystem.
- Use the project-local opam switch. Run `opam switch create . 5.2.0 --deps-only --with-test` for initial dependencies and `opam exec -- <command>` when shell activation is uncertain.
- npm is restricted to Tailwind/HTMX asset tooling and Playwright support. Application and OCaml tests use Dune.
- Local integration tests use local PostgreSQL, local Redis. Do not point tests at shared production data.
- Never embed complex programs in shell one-liners. Create an explicit project script only when the task authorizes that path.
- Keep solver binaries optional for unit tests but explicit for live solver smoke. A missing binary is a skip for the smoke only, not proof of production clearing.

## Branch and Operator Strategy

- `main`: production only.
- `dev`: integration and local service testing.
- `feature/<slug>`: isolated contributor work targeting `dev`.
- `hotfix/<slug>`: emergency production repair, reconciled into both `main` and `dev`.
- Read active `docs/claims/*.json` before overlapping work. If ownership is uncertain, stop and resolve rather than editing concurrently.
- Never initialize, commit, push, merge, or deploy unless the current user request explicitly authorizes it and the relevant gate is satisfied.

## Evidence Discipline

- Save noisy command/browser output to durable artifacts and cite paths.
- Report actual command, exit status, service set, and skipped conditions.
- Separate unit fixture proof, local integration proof, browser proof, live-solver proof, and optional external-adapter proof.
- No generated runtime controller, legacy launcher, wrapper, or autonomous agent is part of this project architecture.
