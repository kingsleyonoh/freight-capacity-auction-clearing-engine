# Gotchas — Index

> **One file per gotcha.** This index is a human-readable catalog, rewritten by the AI whenever a sibling file is added, renamed, or removed. Never append to a single growing table — write a new sibling instead. See `.agent/rules/CODING_STANDARDS.md` — "Append-Only Knowledge Files Banned."

## Catalog

| File | Summary |
|------|---------|
| `2026-07-15-duckdb-cli-init-and-safety.md` | DuckDB CLI reads user init unless a controlled empty `-init` and fixed safety flags are supplied. |
| `2026-07-15-lwt-leading-nul-argv.md` | Lwt 5.10.1 reserves leading NUL for a Windows inline command representation; reject all argv NUL. |
| `2026-07-15-redis-0-8-stream-maxlen-token.md` | Redis 0.8 emits invalid `MAXCOUNT` for Stream trim encoders; isolate one private bounded XADD encoder. |
| `2026-07-15-redis-lwt-separate-package.md` | Redis 0.8 Lwt support requires the separately pinned `redis-lwt` opam package. |

## How to add a new gotcha

1. Filename pattern: `YYYY-MM-DD-short-slug.md` (date of discovery + kebab-case slug).
2. Use the Symptom / Cause / Solution / Discovered in / Affects shape used by existing sibling files so entries promote cleanly via `/harvest-gotchas`.
3. Add one row to the `## Catalog` table above.
4. If the gotcha is cross-project (would bite other projects on the same stack), queue it for harvest.

## Why directory-per-kind

A single `## Gotchas & Lessons Learned` table grows monotonically as every batch appends a row. The table hits 50 rows, then 200, then a size-limit platform truncates the file silently. New file per gotcha eliminates the problem — and git history per gotcha becomes atomic. See `MAINTAINING.md` — "Append-Only Knowledge Files Banned."
