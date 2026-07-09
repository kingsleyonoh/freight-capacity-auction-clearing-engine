# Project Feedback Inbox

> This tracked development document preserves operator feedback for Freight Capacity Auction Clearing Engine. The filename is retained for workflow compatibility; the document is not a launcher, queue, active-run marker, or source of runtime state.

Use this inbox to capture concerns that should influence a future, explicitly started implementation batch. Do not record credentials, sealed-bid values, carrier-sensitive payloads, production URLs containing tokens, or customer data.

## Priority guide

| Priority | Use when | Expected handling |
|---|---|---|
| **HIGH** | Tenant isolation, sealed-bid privacy, incorrect awards, unsafe exports, or data loss may occur | Stop before affected implementation and resolve with evidence |
| **MEDIUM** | Correctness, replay fidelity, approval, or maintainability needs planned work | Fold into the next relevant reviewed batch |
| **LOW** | Naming, copy, or non-blocking polish | Address in a later polish pass |

## Entry format

```markdown
### [HIGH|MEDIUM|LOW] Short title — YYYY-MM-DD

**Concern:** What was observed and why it matters.
**Suggested outcome:** Optional; describe the safe end state, not an unverified implementation.
**Affected area:** Auction/import/clearing/approval/replay/report/integration/UI.
**Evidence:** Project-relative file, test, trace, screenshot, or log path with secrets removed.
**PRD reference:** Section or success criterion when known.

Status: PENDING
```

---

## Pending

No pending feedback.

---

## Handled

When feedback is resolved, move its full entry here and add:

- implementation batch or reviewed change reference;
- evidence paths proving the outcome;
- date handled;
- any remaining risk.

No handled feedback yet.
