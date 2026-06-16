# Freight Capacity Auction Clearing Engine — Design System Brief

## Visual Tone
High-density freight operations console with clear hierarchy for auction status, solver confidence, cost/service frontier, and risk badges.

## UI Principles
- Data tables are compact but readable, with sticky headers/labels for dense matrices.
- Status, risk, and approval states pair color with text/icon labels.
- Critical approve/reject/export actions require confirmation.
- Carrier-facing views explicitly label redaction and never expose competitor bid amounts.

## Responsive Baselines
Test at 1440px, 768px, and 390px. Mobile-critical flows: login, dashboard status, approve/reject, carrier bid explanation.

## Accessibility
WCAG 2.1 AA, keyboard-accessible tables/dialogs/import wizard, ARIA chart summaries, visible focus, reduced motion, and at least 44px touch targets.

## Performance
First-load JS under 200KB gzipped. Replay/result charts are dynamically imported only on routes that need them.

## Evidence Flags
`MOBILE_VIEWPORT_PASS`, `PRIVACY_MATRIX_PASS`, `BUNDLE_DYNAMIC_IMPORT_AUDIT_PASS`, `FRONTEND_IMPECCABLE_AUDIT_PASS`, `FRONTEND_IMPECCABLE_POLISH_PASS`, `A11Y_KEYBOARD_TABLE_PASS`.
