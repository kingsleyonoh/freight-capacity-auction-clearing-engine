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

The canonical tokens are implementation values, not mood-board approximations:

| Token | Value | Operational use |
|---|---|---|
| `--color-ink:` | `#14212B` | Primary text and dark control surfaces |
| `--color-paper:` | `#F4F0E6` | Warm long-session canvas and report ground |
| `--color-freight-blue:` | `#165D7A` | Primary action, selection, and cost series |
| `--color-amber:` | `#8A4B00` | Caution, pending approval, and policy relaxation |
| `--color-oxide-red:` | `#A52A2A` | Destructive actions and blocking failures only |
| `--color-signal-green:` | `#177245` | Verified feasible/success states and service series only |
| `--color-slate:` | `#5E6B73` | Neutral metadata, disabled integrations, and baseline series |

Chart colors are fixed by meaning, never assigned by row or response order: cost uses freight blue, service uses signal green, risk uses amber, baseline uses slate, and infeasible uses oxide red. This deterministic chart series mapping must survive filtering, replay comparison, and export; every series also has a text label and distinguishable dash/marker pattern.

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

The canonical state vocabulary is literal and shared with server responses and later UI tests:

| State | Required presentation and recovery |
|---|---|
| `loading` | Stable skeleton geometry with a named region; no invented totals |
| `empty` | State what is absent and offer the authorized first action |
| `import-error` | Preserve the ledger, name rejected rows, and link correction guidance |
| `validation-warning` | Keep the warning distinct from a blocker and name the consequence of continuing |
| `infeasible` | Show unsatisfied constraints and ranked relaxation paths; never imply an award |
| `solver-running` | Polite progress updates, elapsed time, and preserved table position |
| `approval-required` | Block publication/export and name the approver and expiry |
| `success` | Name the persisted outcome, timestamp, and next safe action |
| `offline` | Keep cached content read-only and disable mutations without implying a queue |
| `disabled-integration` | Separate optional adapter state from core auction readiness |
| `permission-denied` | Name the unavailable action without leaking the protected resource |
| `stale-data` | Keep values readable with source timestamp and explicit refresh |

- Approve, reject, export, rerun, and relaxation actions present consequences and require confirmation where state becomes externally meaningful.
- `focus-visible` treatment uses a two-layer ink/paper outline that remains visible on every semantic color. Focus returns to the initiating control after drawers/dialogs close; validation moves focus to the first error and provides a summary.
- Hover, active, disabled, busy, and error treatments preserve labels, geometry, and status meaning rather than relying on opacity alone.
- Motion is sparse and functional: state transitions and newly arrived rows only, with no layout-jank animation; `prefers-reduced-motion` removes nonessential transitions.

## Responsive rules

- **1440px:** full comparison tables, evidence drawer, and constraint rail may coexist.
- **768px:** filters and secondary evidence move to drawers; primary status and action remain fixed in reading order.
- **390px:** support login, dashboard status, approve/reject, and carrier explanation without precision gestures. Use stacked clearance strips and sticky labels; keep 44px minimum touch targets.
- Horizontal scrolling is acceptable for dense matrices/frontiers only when the first column is sticky and an equivalent summary is available.

## Accessibility baseline

Target WCAG 2.1 AA. Use semantic headings, landmarks, captions, native controls, visible focus, skip links, keyboard-operable tables/dialogs/import steps, and descriptive error summaries. Charts require ARIA summaries and equivalent tabular values. Status streams must not repeatedly interrupt screen readers. Confirmations must identify auction, load/award, consequence, and resulting state.

## Privacy and redaction cues

Show the active viewer scope (`Tenant admin`, `Auction manager`, `Procurement analyst`, or `Carrier viewer`) near explanation and export surfaces. Mark sealed and redacted fields explicitly. Never reveal hidden values through tooltips, chart scales, sort order, DOM text, downloadable payloads, logs, or analytics. Export confirmation names the redaction scope and frozen snapshot timestamp. The role and surface outcomes are governed by `docs/frontend/privacy-matrix.md`; absence from a visible table is not enough if the value remains in markup or a payload.

## Performance baseline

First-load JavaScript stays below 200KB gzipped. Replay/frontier visualization is dynamically imported only on replay and clearing-result routes; core status, tables, explanations, and confirmations remain server-rendered and usable without chart code. Prefer CSS and native browser behavior over decorative JavaScript.

## Anti-patterns

- Purple/blue gradients, glass panels, generic KPI card grids, or AI sparkle motifs.
- Excessive rounded cards that fragment a single decision chain.
- Unlabeled color-only risk, confidence, or feasibility signals.
- Hidden policy versions, stale timestamps, or live/replay context.
- Decorative motion, auto-advancing evidence, or dense tables collapsed into unusable mobile thumbnails.
- “Success” language before persistence, required approval, and export eligibility are confirmed.
