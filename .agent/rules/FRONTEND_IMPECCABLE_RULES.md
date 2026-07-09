# Freight Capacity Auction Clearing Engine — Frontend Quality Rules

Applies to Dream-rendered pages, HTMX fragments, Tailwind styles, static assets, copy, and browser interaction.

## Product Intent

Build a high-density freight operations console: sober, auditable, fast to scan, and explicit about solver confidence, cost/service tradeoffs, risk, infeasibility, and privacy. Avoid generic dashboard decoration, unexplained gradients, glass effects, nested card grids, random illustration/emoji, and placeholder copy.

Read `PRODUCT.md` and root `DESIGN.md` when present. If a UI task requires a missing baseline, derive it from PRD §5b before implementation within authorized scope.

## Server-Rendered Architecture

- Dream owns routing, authorization, validation, canonical state, and complete initial HTML.
- HTMX progressively enhances forms and fragments; every protected fragment uses the same server-side tenant/permission checks as its full page.
- Do not introduce SPA state or a client framework without explicit spec approval.
- Tailwind classes follow documented tokens/components. Repeated visual values become shared tokens/partials rather than per-page literals.
- Use semantic HTML first; use ARIA only to fill a semantic gap.

## Build Flow

1. State purpose, user, decision/action, content hierarchy, emotional tone, privacy risks, responsive constraints, and anti-reference.
2. Implement complete semantic structure and server states.
3. Refine density, spacing, typography, color, focus, interaction, responsive behavior, and motion.
4. Run integration tests plus Playwright at applicable viewports.
5. Audit and polish before claiming completion.

## Required States

Every relevant screen defines loading/solver-running, empty, validation error, warning, infeasible, approval-required, success, offline mutation-disabled, disabled integration, permission denied, and stale-data states. Interactive controls include hover, focus-visible, active, disabled, busy, and error behavior.

Do not use color alone for risk/status. Pair icon/color with a concise text label. Destructive or high-value approve/reject/export actions require clear confirmation and outcome messaging.

## Accessibility and Responsive Contract

- WCAG 2.1 AA; body contrast 4.5:1 and large text 3:1.
- All actions work with Tab/Shift+Tab/Enter/Space/Escape as appropriate; focus remains visible and returns logically after dialogs/fragments.
- Inputs have labels and linked errors; tables have captions/headers; clearing progress uses an appropriate live region; charts have text summaries.
- Honor `prefers-reduced-motion`; no layout-jank animation.
- Validate 1440px desktop, 768px tablet, and 390px mobile for critical flows. Touch targets are at least 44px.
- Dense matrices may scroll horizontally with sticky labels; ordinary pages must not overflow.

## Privacy and Performance

- Carrier views never reveal competitor amounts, identities, raw reliability details beyond policy, or operator-only constraints.
- Export/report actions state redaction scope and require confirmation where sensitive.
- Initial JavaScript target is under 200KB gzipped. Keep HTMX enhancements small; dynamically load heavy replay/frontier visualization only on routes that use it.
- Do not duplicate canonical data in browser storage. Offline mode is read-only; mutations are disabled.

## Verification Evidence

Frontend changes require production-path Dream/HTMX integration coverage and reachable Playwright evidence. Record screenshots on failure plus console/network diagnostics. Applicable completion flags are:

- `FRONTEND_IMPECCABLE_AUDIT_PASS`
- `FRONTEND_IMPECCABLE_POLISH_PASS`
- `MOBILE_VIEWPORT_PASS`
- `PRIVACY_MATRIX_PASS`
- `BUNDLE_DYNAMIC_IMPORT_AUDIT_PASS`
- `A11Y_KEYBOARD_TABLE_PASS`

Blocking failures: inaccessible labels/focus/keyboard flow, unreadable contrast, broken responsive layout, tenant/sealed-bid leakage, missing interaction states, token drift, placeholder copy, or motion that ignores reduced-motion.
