# Freight Capacity Auction Clearing Engine — Product Brief

## Users
- VP Logistics and freight procurement leads who own spot capacity spend and service risk.
- Freight broker operations leaders who need defensible award decisions under tight bid windows.
- Tenant admins, auction managers, procurement analysts, and carrier viewers.

## Positioning
Defensible freight spot-auction clearing that prices service risk instead of blindly choosing the cheapest bid. The product is standalone-first: imports, clearing, explanation, replay, and exports work without Notification Hub, Workflow Engine, or Webhook Engine.

## Product Personality
Dense, precise, operations-grade, explainable, privacy-aware, and audit-first. The UI should feel like a trusted freight operations console rather than generic SaaS.

## Trust Requirements
- Every award and rejection explains binding constraints, input facts, and tradeoff score.
- Sealed-bid privacy is visible in carrier views and export confirmations.
- Frozen report snapshots prove historical exports did not drift when tenant identity changes.
- Optional integrations are clearly disabled/degraded without blocking core auction work.
- Replay and solver artifacts are named product concepts, not hidden implementation details.

## Core UI Promises
- Operators can see auction status, solver readiness, risk caps, reserve enforcement, and replay readiness at a glance.
- Carrier-facing views only expose own-bid facts plus generalized constraints; competitor bid amounts never appear.
- Dense tables keep sticky labels and semantic captions so keyboard and screen-reader users can audit decisions.

## Anti-References
No generic purple gradients, card grids without operational hierarchy, unlabeled red/green risk-only colors, opaque solver "AI magic", hidden service-risk tradeoffs, or mobile flows that simply shrink desktop matrices.
