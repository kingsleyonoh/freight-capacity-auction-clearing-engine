# Design Baseline — Freight Capacity Auction Clearing Engine

## Direction: Manifest Control Desk

An industrial, evidence-first freight operations console inspired by dispatch manifests, terminal boards, and audited procurement ledgers. The visual signature is a **clearance strip**: each clearing result reads left-to-right from load and bid facts through binding constraints to award/rejection, preserving the decision chain in one scan.

Clarity outranks spectacle. Density is deliberate; whitespace separates decision groups rather than inflating every control into a card.

## Information hierarchy

1. **Operational context:** tenant, auction mode, live/replay status, bid window, policy version, and data freshness.
2. **Decision state:** draft, validating, queued, solver running, infeasible, approval required, awarded, exported, or failed.
3. **Outcome:** landed cost, service score, unassigned loads, concentration, reserve exceptions, and approval burden.
4. **Evidence:** binding constraints, redacted explanation, input/output artifact references, timestamps, and actor.
5. **Recovery:** fix import, inspect infeasibility, compare relaxation, rerun, approve, or retry an optional integration.

The main action must never visually outrank an unresolved hard constraint or approval requirement.

## Typography

- **Display and operational headings:** IBM Plex Sans Condensed — narrow, authoritative, and suited to dense terminal-like labels.
- **Body and controls:** Atkinson Hyperlegible — optimized for legibility under dense, time-sensitive reading.
- **Identifiers, amounts, timestamps, and solver facts:** IBM Plex Mono with tabular numerals.
- Use sentence case for actions and headings. Reserve uppercase for short state stamps such as `LIVE`, `REPLAY`, and `SEALED`.

## Color system

- **Ink:** near-black navy for primary text and dark control surfaces.
- **Paper:** warm off-white for long-session comfort and report affinity.
- **Freight blue:** primary action and selected context.
- **Amber:** caution, pending approval, and policy relaxation.
- **Oxide red:** destructive actions and blocking failures only.
- **Signal green:** verified feasible/success states only.
- **Slate:** neutral metadata, disabled integrations, and secondary dividers.

Every semantic color is paired with an icon, label, or pattern. Red/green alone must never carry meaning. Body text meets 4.5:1 contrast; large text and essential graphical boundaries meet at least 3:1.

## Spacing and density

Use a compact 4px base rhythm with 8/12/16/24/32px steps. Tables favor stable columns, tabular numbers, sticky headers, and restrained row height. Group related facts with rules and alignment before adding containers. Reserve generous space for decision summaries, infeasibility explanations, and destructive confirmations.

## Core patterns

- **Auction masthead:** tenant and auction identity, mode, clock, policy version, freshness, and state in one persistent band.
- **Clearance strip:** load → eligible bid → constraints → score → decision; carrier-safe variants remove competitor facts without leaving suggestive gaps.
- **Evidence drawer:** source snapshots, solver artifacts, audit events, and export scope adjacent to the result they support.
- **Constraint rail:** hard constraints and weighted factors separated visually; violated or relaxed constraints name the exact policy term.
- **Cost/service frontier:** accessible summary first, chart second; selected points expose equivalent text and table data.
- **Import ledger:** preview counts, row-level errors, quarantine reasons, and commit boundary remain visible together.
- **State stamp:** shape + icon + text, never color alone.

## Interaction and state behavior

- Solver and import progress use polite live regions and preserve the user's table position.
- Approve, reject, export, rerun, and relaxation actions present consequences and require confirmation where state becomes externally meaningful.
- Focus returns to the initiating control after drawers/dialogs close; validation moves focus to the first error and provides a summary.
- Loading uses stable skeleton geometry; stale data remains readable with a timestamp and explicit refresh action.
- Offline mode is read-only. Mutations are disabled with an explanation; no queueing is implied.
- Motion is sparse and functional: state transitions and newly arrived rows only, disabled under reduced-motion preferences.

## Responsive rules

- **1440px:** full comparison tables, evidence drawer, and constraint rail may coexist.
- **768px:** filters and secondary evidence move to drawers; primary status and action remain fixed in reading order.
- **390px:** support login, dashboard status, approve/reject, and carrier explanation without precision gestures. Use stacked clearance strips and sticky labels; keep 44px minimum touch targets.
- Horizontal scrolling is acceptable for dense matrices/frontiers only when the first column is sticky and an equivalent summary is available.

## Accessibility baseline

Target WCAG 2.1 AA. Use semantic headings, landmarks, captions, native controls, visible focus, skip links, keyboard-operable tables/dialogs/import steps, and descriptive error summaries. Charts require ARIA summaries and equivalent tabular values. Status streams must not repeatedly interrupt screen readers. Confirmations must identify auction, load/award, consequence, and resulting state.

## Privacy and redaction cues

Show the active viewer scope (`Operator`, `Analyst`, `Admin`, or `Carrier`) near explanation/export surfaces. Mark sealed and redacted fields explicitly. Never reveal hidden values through tooltips, chart scales, sort order, DOM text, downloadable payloads, or analytics. Export confirmation names the redaction scope and frozen snapshot timestamp.

## Performance baseline

First-load JavaScript stays below 200KB gzipped. Replay/frontier visualization loads only on replay and clearing-result routes; core status, tables, explanations, and confirmations remain server-rendered and usable without chart code. Prefer CSS and native browser behavior over decorative JavaScript.

## Anti-patterns

- Purple/blue gradients, glass panels, generic KPI card grids, or AI sparkle motifs.
- Excessive rounded cards that fragment a single decision chain.
- Unlabeled color-only risk, confidence, or feasibility signals.
- Hidden policy versions, stale timestamps, or live/replay context.
- Decorative motion, auto-advancing evidence, or dense tables collapsed into unusable mobile thumbnails.
- “Success” language before persistence, required approval, and export eligibility are confirmed.
