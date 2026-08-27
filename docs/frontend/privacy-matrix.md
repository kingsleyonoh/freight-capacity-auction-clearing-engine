# Frontend Privacy Matrix — Freight Auction Evidence Baseline

This baseline translates PRD §2b, §5.6, §5b, §8, and §15 into a reviewable contract for later Dream/HTMX authorization and Playwright work. It defines intended outcomes; it is **not** `PRIVACY_MATRIX_PASS` or evidence that a product UI exists.

## Outcome legend

- **Allowed** — the named role and tenant may receive the field because the task requires it. Server authorization still applies before rendering or serialization.
- **Generalized** — replace the sensitive value with a policy band, count, category, or approved explanation that cannot be used to reconstruct it.
- **Hidden** — do not fetch or serialize the value for that viewer or surface. Hidden means absent from HTML, DOM attributes, HTMX fragments, API payloads, exports, logs, analytics, chart domains, sort keys, and client storage—not merely visually concealed.

Every outcome is fail-closed. Tenant mismatch, unknown role, missing redaction policy, or missing frozen snapshot resolves to **Hidden** and blocks the action where a safe generalized form is unavailable.

## Role outcome matrix

| Sensitive data | Tenant admin | Auction manager | Procurement analyst | Carrier viewer | Required label or confirmation | Future owner / evidence pointer |
|---|---|---|---|---|---|---|
| Sealed competitor bids | Generalized before bid close; Allowed after close for authorized review | Generalized before bid close; Allowed after close for clearing review | Generalized before bid close; Allowed after close for analysis | Hidden | `SEALED` before close; after close, internal views show viewer scope and auction phase | P1 authorization owner: `tests/authorization/`; future evidence: role × auction-phase response assertions |
| Own bid | Allowed in tenant scope | Allowed in tenant scope | Allowed in tenant scope | Allowed for authenticated own carrier only | `OWN BID` in Carrier viewer scope; never imply access to the bid set | P1 tenant-scope owner: `tests/authorization/`; future evidence: own-carrier and cross-carrier denial cases |
| Reliability score detail | Allowed with policy version and source freshness | Allowed for carrier management and clearing review | Generalized to policy-approved service/risk band unless detail permission is granted | Generalized to own-carrier policy band; raw history Hidden | `POLICY BAND` for generalized values; `DETAIL` plus policy version for Allowed values | P1 operator owner: `tests/authorization/`; P2 carrier owner: `tests/e2e/ui/carrier-bid-privacy.spec.ts` (future) |
| Frozen export snapshot | Allowed after eligibility checks and confirmation | Allowed after eligibility checks and confirmation | Allowed for authorized reports, but cannot bypass approval-required state | Generalized to own-bid report with carrier-safe explanation | Confirmation names tenant, auction, viewer scope, redaction scope, format, and frozen snapshot timestamp | P2 report owner: `tests/e2e/ui/export-confirmation.spec.ts` (future); frozen snapshot parity with API/export tests |
| Redacted carrier explanation | Allowed with internal binding constraints | Allowed with internal binding constraints | Allowed for report analysis | Generalized to own bid, policy-safe reason, and no competitor facts | Carrier surface is persistently labeled `REDACTED · CARRIER VIEW`; internal surface names viewer scope | P2 carrier owner: `tests/e2e/ui/carrier-bid-privacy.spec.ts` (future); compare UI/API/export generalized text |
| Raw solver internals and hashes | Hidden | Hidden | Hidden | Hidden | No UI label exposes the value; use a generalized `solver artifact retained` state only | P1 API/authorization owner: `tests/authorization/`; future evidence: forbidden-key scans over role responses |

`Allowed` never overrides the PRD authority matrix: Procurement analyst cannot approve, Carrier viewer cannot run clearing, and only a role authorized for the current tenant may receive internal auction data.

## Surface boundary matrix

| Data class | UI | DOM | API/HTMX | Export/report (confirmation required) | Logs | Analytics |
|---|---|---|---|---|---|---|
| Sealed competitor bids | Generalized before close; Allowed only to authorized internal roles after close | Hidden before close and always Hidden for Carrier viewer | Generalized/Allowed only after tenant, role, auction-phase, and field-policy checks | Hidden from carrier-safe files; internal Allowed only after confirmation and frozen-snapshot creation | Hidden | Hidden |
| Own bid | Allowed in authenticated own-carrier or internal tenant scope | Allowed only in the scoped rendered response; no duplicate client storage | Allowed after tenant + carrier ownership check | Generalized carrier-safe snapshot or Allowed internal snapshot after confirmation | Hidden amounts and row contents; Allowed request/result counts | Generalized event name and outcome only |
| Reliability score detail | Allowed or Generalized by role matrix | Hidden when Generalized; do not embed raw history in attributes, tooltips, or chart scales | Return only the authorized detail/band schema | Generalized for carrier exports; Allowed internal only when the report policy declares it | Hidden raw score/history; Generalized policy band only when operationally necessary | Generalized band/count only; no carrier identity |
| Frozen export snapshot | Generalized preview of scope, timestamp, and format | Hidden payload; preview carries identifiers needed for confirmation, not report contents | Allowed only after approval/export eligibility and idempotent confirmation | Allowed immutable snapshot at confirmed redaction scope; re-render never reads live values | Generalized export ID, role, format, outcome, and timestamp | Generalized export event, format, and outcome; no file contents or identity |
| Redacted carrier explanation | Generalized and labeled for Carrier viewer; Allowed internal | Generalized text only in carrier DOM; hidden fields must not be sort keys or accessibility text | Role-specific response schema; carrier payload omits internal constraints and competitor facts | Generalized in carrier-safe files; internal Allowed after confirmation | Generalized reason code only | Generalized reason category only |
| Raw solver internals and hashes | Hidden | Hidden | Hidden from product responses; artifact references are Generalized | Hidden | Hidden; log only generalized artifact ID/status where operationally required | Hidden |

## Confirmation and labeling behavior

1. **Sealed state:** before bid close, internal tables show `SEALED` plus close time and aggregate import/validation status; they do not render bid amounts in the UI, DOM, or API/HTMX fragment. Carrier viewer never receives competitor rows before or after close.
2. **Viewer scope:** every explanation and export surface displays one exact scope label: `Tenant admin`, `Auction manager`, `Procurement analyst`, or `Carrier viewer`. A carrier-safe surface also displays `REDACTED · CARRIER VIEW` beside the result and in the generated report header.
3. **Export confirmation:** the modal and non-JavaScript confirmation page identify tenant, auction, viewer scope, redaction scope, output format, approval state, and frozen snapshot timestamp. The confirm action says `Create frozen <scope> export`; cancel performs no mutation. Approval-required or missing-solver-artifact state blocks creation.
4. **Outcome message:** success identifies the immutable export ID, frozen timestamp, and applied redaction scope. Failure names a safe reason code without echoing bid data, carrier identity, uploaded rows, hashes, or raw solver internals.
5. **No side channels:** hidden data cannot influence row count, blank gaps, chart axes, order, CSS classes, element IDs, accessible names, timing copy, downloadable metadata, log context, or analytics properties in a way that reveals competitor facts.

## Future test ownership and evidence

This Phase 0 matrix is the contract source. The paths below are ownership pointers, not claims that tests or flags currently pass.

| Phase | Owner surface | Required future evidence |
|---|---|---|
| P1 | `tests/authorization/` and Dream route tests | Tenant × role × auction-phase table tests; forbidden-key scans for competitor amounts, hashes, and raw solver internals; UI/API response parity for internal roles |
| P1 | Clearing/import integration tests | Sealed-before-close serialization, post-close authorized access, missing-artifact export block, and approval-required export block |
| P2 | `tests/e2e/ui/carrier-bid-privacy.spec.ts` (future) | Carrier own-bid journey at 1440px and 390px; labeled redacted explanation; DOM, HTMX, download, console, and captured-request non-leakage |
| P2 | `tests/e2e/ui/export-confirmation.spec.ts` (future) | Keyboard-operable confirmation and cancellation; exact scope label; frozen timestamp; carrier-safe versus internal export assertions |
| P2 | API/export parity tests | Operator UI, carrier UI, role-scoped API, and frozen CSV/JSON/HTML use the same decision snapshot and expected redaction outcome |

Only production-path authorization plus the applicable P1/P2 tests may later support `PRIVACY_MATRIX_PASS`. Documentation, viewport configuration, or this validator alone cannot set that evidence flag.
