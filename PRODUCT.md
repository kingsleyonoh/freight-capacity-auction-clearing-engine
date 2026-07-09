# Product Baseline — Freight Capacity Auction Clearing Engine

## Product promise

Give freight procurement teams a defensible way to award spot capacity: optimize landed cost inside explicit service, capacity, fairness, reserve, and reliability constraints, then show why every bid won or lost.

The product is an operations console, not a public marketplace or a full transportation management system. Its core auction, replay, approval, explanation, and export flows must work without optional portfolio services.

## Primary users

- **Tenant admin:** governs tenant identity, users, policies, retention, and optional integrations.
- **Auction manager:** creates auctions, validates imports, runs clearing, reviews awards, approves exceptions, and exports results.
- **Procurement analyst:** evaluates imports, scenarios, constraints, replays, and reports without approval authority.
- **Carrier viewer:** sees only their carrier's bids and privacy-safe explanations.

## Core operating journeys

1. Set up a tenant and authenticate with an API key or short-lived UI session.
2. Import carriers, lanes, loads, and bids; preview validation and quarantine evidence before commit.
3. Close bidding, run clearing, and follow solver progress without losing context.
4. Review awards, rejected bids, binding constraints, service risk, and infeasibility relaxations.
5. Approve or reject high-value/exception awards before publication or export.
6. Replay historical auctions against baselines and decide whether a policy is safe to promote.
7. Export frozen, redacted evidence that remains consistent with the reviewed decision.

## Product personality

**Calm dispatch authority.** Dense, exact, and operational rather than celebratory. The console should feel like a well-run control desk: time-sensitive facts are visible, risk is explicit, and every irreversible action asks for evidence.

## Trust contract

- Never imply that “lowest price” alone is the winning rationale.
- Distinguish hard constraints, weighted tradeoffs, operator overrides, and missing evidence.
- Show the policy version, input snapshot, solver backend, timestamps, and freshness with each decision.
- Treat infeasibility as an explainable result, never as a silent fallback.
- Block export/publication until required approval and solver artifacts exist.
- Keep optional integration degradation separate from core readiness.
- Label fixture, replay, and live-auction contexts unambiguously.

## Privacy and tenant boundaries

- Sealed bids, competitor amounts, carrier reliability, tenant identity, and export contents are sensitive.
- Carrier views expose only the carrier's own bids plus generalized rejection explanations.
- Tenant context must remain visible on authenticated screens and exports.
- Exports require confirmation, state their redaction scope, and use frozen report snapshots.
- Analytics must avoid bid amounts, carrier identities, API keys, solver payloads, and uploaded row contents.

## Responsive scope

Desktop is primary for auction tables, replay comparisons, and constraint evidence. Tablet moves filters and secondary detail into drawers. At 390px, the required flows are login, dashboard status, approve/reject, and carrier bid explanation. Dense matrices may scroll horizontally with sticky row labels; critical actions remain at least 44px and require confirmation.

## Required product states

Loading, empty, import error, validation warning, solver running, infeasible, approval required, success, offline/read-only, disabled integration, degraded integration, permission denied, and stale data must each have distinct language and recovery guidance.

## Evidence baseline

Frontend work is not complete without evidence for:

- `MOBILE_VIEWPORT_PASS` at 1440px, 768px, and 390px
- `PRIVACY_MATRIX_PASS` across operator, analyst, admin, and carrier scopes
- `BUNDLE_DYNAMIC_IMPORT_AUDIT_PASS` with first-load JavaScript under 200KB gzipped
- `FRONTEND_IMPECCABLE_AUDIT_PASS` and `FRONTEND_IMPECCABLE_POLISH_PASS`
- `A11Y_KEYBOARD_TABLE_PASS` for tables, dialogs, imports, and approval actions

## Explicit anti-references

- No generic gradient-heavy SaaS dashboard or decorative “AI optimization” imagery.
- No unlabeled red/green signals, unexplained confidence scores, or success confetti.
- No card wall that hides comparison tables and decision evidence.
- No competitor bid leakage, live/replay ambiguity, or optimistic success before canonical state is committed.
- No mobile claim that merely shrinks desktop tables; required mobile decisions must remain usable.
