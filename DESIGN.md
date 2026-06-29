# Freight Capacity Auction Clearing Engine — Design System Brief

## Visual Tone
High-density freight operations console with clear hierarchy for auction status, solver confidence, cost/service frontier, and risk badges. The baseline palette uses deep navy for operational chrome, amber for decision urgency, sky blue for focus/evidence, and green only when paired with text labels.

## UI Principles
- Data tables are compact but readable, with sticky headers/labels for dense matrices.
- Status, risk, and approval states pair color with text or icon labels; color is never the only signal.
- Critical approve/reject/export actions require confirmation and show the audit consequence.
- Carrier-facing views explicitly label redaction and never expose competitor bid amounts.
- HTMX progressive enhancement is allowed for forms and route fragments; core content renders server-side.

## Responsive Baselines
Test at 1440px, 768px, and 390px. Mobile-critical flows: login, dashboard status, approve/reject, and carrier bid explanation. Dense matrices become horizontally scrollable cards with sticky row labels and 44px minimum touch targets.

## Accessibility
WCAG 2.1 AA, keyboard-accessible tables/dialogs/import wizard, ARIA chart summaries, visible focus, reduced motion, semantic headings/landmarks, live regions for solver/clearing job status, and captions for operational tables.

## State Hierarchy
Required states: loading, empty, import-error, validation-warning, infeasible, solver-running, approval-required, success, offline, disabled integration, permission-denied, and stale-data. Warning and failure states must include remediation text, not only status labels.

## Performance
First-load JS under 200KB gzipped. Replay/result charts are dynamically imported only on routes that need them. Baseline pages should function without custom client-side JavaScript beyond HTMX.

## Evidence Flags
`MOBILE_VIEWPORT_PASS`, `PRIVACY_MATRIX_PASS`, `BUNDLE_DYNAMIC_IMPORT_AUDIT_PASS`, `FRONTEND_IMPECCABLE_AUDIT_PASS`, `FRONTEND_IMPECCABLE_POLISH_PASS`, `A11Y_KEYBOARD_TABLE_PASS`.
