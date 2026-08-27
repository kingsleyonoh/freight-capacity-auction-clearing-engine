# Frontend evidence tooling baseline

## Scope and honesty

These commands establish executable Phase 0 contracts only. Controlled subjects emit `scope: "fixture"` and `productRoutesEvaluated: false`; they cannot satisfy later product-route evidence. Product commands fail closed with exit code `2` for malformed or absent subjects and do not write a passing artifact.

The tooling does not set or imply any frontend completion flag. Actual Dream routes, built assets, privacy/authorization behavior, and reachable product journeys remain later owners.

## Commands

| Purpose | Command |
|---|---|
| Bundle controlled fixture | `npm run frontend:bundle:fixture` |
| Bundle product audit | `npm run frontend:bundle:product -- --manifest <build-manifest.json> --out <artifact.json>` |
| Impeccable controlled detector/parser plus polish dossier | `npm run frontend:impeccable:fixture` |
| Impeccable product audit | `npm run frontend:impeccable:audit -- --detector-executable <absolute-pinned-executable> --detector-version <resolved-version> --routes-manifest <routes.json> --paths <frontend-path> --out <artifact.json>` |
| Polish dossier validation | `npm run frontend:impeccable:polish -- --dossier <dossier.json> --out <artifact.json>` |
| Accessibility controlled Playwright fixture | `npm run frontend:a11y:fixture` |
| Accessibility product routes | `npm run frontend:a11y:product -- --base-url <http-url> --routes-manifest <routes.json> --out <artifact.json>` |
| Focused contract gate | `npm run frontend:evidence:contracts` |

Exit `0` means the declared scope passed, exit `1` means findings, and exit `2` means the subject or execution boundary was invalid. Fixture, `data:`, `file:`, empty route/path sets, and absent manifests are rejected in product mode.

## Bundle manifest contract

The auditor reads every asset file and calculates gzip bytes with Node `zlib` level 9. Declared byte totals are ignored. It walks each entry's transitive static `imports`, limits their summed gzip size to 204800 bytes, and verifies `chart` and `frontier` assets are dynamically reachable and assigned only to `/replays...` or `/auctions/:id/clearing...` routes.

A manifest has `entries`, `assets`, `assetRoot`, `generatedBy`, and `routes`. Each asset has `file`, `kind`, `imports`, and `dynamicImports`; heavy assets also have a non-empty `routes` list. Product manifests must be non-fixture build output with non-empty product routes.

## Impeccable detector and polish contracts

The repository deliberately does not download or execute an unpinned remote `latest` detector. The fixture command injects a deterministic local fake detector into the production parser/process contract. Product use must supply an existing absolute detector executable, an explicitly resolved version, a real route manifest, and real frontend paths. The detector receives a literal argv array:

```text
[...prefixArgs, "detect", "--fast", "--json", ...paths]
```

Execution uses `spawnSync` with `shell: false`. Malformed output, unavailable execution, or P0/P1 findings fail closed. A valid raw detector JSON file is preserved beside the normalized audit artifact.

Polish never mutates styles or source. It validates a dossier containing a passed same-scope audit, non-empty routes, final screenshots with rationale, findings, and interaction-state, typography, spacing, color, motion, copy, and token-drift reviews. Product screenshot paths must exist and cannot be fixture/data/file subjects. This preserves the Manifest Control Desk design stance without turning a detector into an aesthetic author.

## Accessibility route contract

The controlled fixture is served over local HTTP and exercised through Playwright; it does not use `page.setContent`. Reusable helpers cover:

- keyboard table-row/detail parity;
- dialog Escape and focus return;
- labelled import steps, inputs, and linked errors;
- an ARIA chart summary with an equivalent semantic table;
- visible focus;
- 4.5:1 body and 3:1 large-text/essential-graphic contrast;
- textual/icon status semantics rather than color alone;
- `prefers-reduced-motion` behavior.

A product route manifest contains a non-empty `routes` array. Each route is an object with a real relative HTTP path, a non-empty `checks` list, and the locator contract consumed by `tests/e2e/tooling/frontend-evidence-fixture.spec.ts`. Across the route set every configured required check must be covered. Product mode rejects fixture/data/file routes and requires an HTTP(S) base URL.

## Artifact shape

Normalized artifacts use schema version 1 and include `kind`, `scope`, `status`, `subject`, literal `command` argv, `toolVersions`, `productRoutesEvaluated`, `checks`, `metrics`, `findings`, and `artifacts`. Only path-backed product artifacts from actual built assets and reachable routes can later support product evidence.
