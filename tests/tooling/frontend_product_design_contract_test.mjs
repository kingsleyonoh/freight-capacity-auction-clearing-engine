import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (path) => readFileSync(path, "utf8");
const product = read("PRODUCT.md");
const design = read("DESIGN.md");

const assertIncludesAll = (text, values, label) => {
  for (const value of values) {
    assert.ok(text.includes(value), `${label} must include ${JSON.stringify(value)}`);
  }
};

const assertNoFillerOrInflatedEvidence = (text, label) => {
  assert.doesNotMatch(text, /\b(?:TODO|FIXME|lorem ipsum|template placeholder)\b/i, `${label} contains filler`);
  assert.doesNotMatch(text, /modern,? clean,? (?:and )?intuitive dashboard/i, `${label} uses generic dashboard filler`);
  assert.doesNotMatch(
    text,
    /(?:MOBILE_VIEWPORT_PASS|PRIVACY_MATRIX_PASS|BUNDLE_DYNAMIC_IMPORT_AUDIT_PASS|FRONTEND_IMPECCABLE_(?:AUDIT|POLISH)_PASS|A11Y_KEYBOARD_TABLE_PASS)\s*(?::|=|—|-)?\s*(?:true|passed|complete)/i,
    `${label} must not claim unimplemented frontend evidence flags`,
  );
};

test("PRODUCT baseline is freight-specific and honest", () => {
  assertIncludesAll(product, [
    "## Product promise",
    "## Primary users",
    "## Core operating journeys",
    "## Product personality",
    "## Trust contract",
    "## Privacy and tenant boundaries",
    "## Explicit anti-references",
    "Tenant admin",
    "Auction manager",
    "Procurement analyst",
    "Carrier viewer",
    "landed cost",
    "service",
    "constraint",
    "solver",
    "replay",
    "approval",
    "frozen",
    "Sealed bids",
    "competitor",
    "export",
    "public marketplace",
    "transportation management system",
  ], "PRODUCT.md");
  assert.match(product, /Import[\s\S]*Close bidding[\s\S]*Review awards[\s\S]*Approve or reject[\s\S]*Replay[\s\S]*Export frozen/i);
  assertNoFillerOrInflatedEvidence(product, "PRODUCT.md");
});

test("DESIGN baseline specifies a complete Manifest Control Desk system", () => {
  assertIncludesAll(design, [
    "## Direction: Manifest Control Desk",
    "clearance strip",
    "Auction masthead",
    "Constraint rail",
    "Cost/service frontier",
    "Import ledger",
    "IBM Plex Sans Condensed",
    "Atkinson Hyperlegible",
    "IBM Plex Mono",
    "--color-ink:",
    "--color-paper:",
    "--color-freight-blue:",
    "#",
    "deterministic chart series",
    "dynamically imported",
    "4px base rhythm",
    "1440px",
    "768px",
    "390px",
    "44px",
    "WCAG 2.1 AA",
    "4.5:1",
    "3:1",
    "focus-visible",
    "prefers-reduced-motion",
    "loading",
    "empty",
    "import-error",
    "validation-warning",
    "infeasible",
    "solver-running",
    "approval-required",
    "success",
    "offline",
    "disabled-integration",
    "permission-denied",
    "stale-data",
  ], "DESIGN.md");
  assert.match(design, /chart colors[^\n]*fixed|fixed[^\n]*chart colors/i, "DESIGN.md must make chart colors deterministic");
  assertNoFillerOrInflatedEvidence(design, "DESIGN.md");
});

test("PRODUCT and DESIGN share role, privacy, state, and evidence vocabulary", () => {
  for (const role of ["Tenant admin", "Auction manager", "Procurement analyst", "Carrier viewer"]) {
    assert.ok(product.includes(role), `PRODUCT.md missing role ${role}`);
    assert.ok(design.includes(role), `DESIGN.md missing role ${role}`);
  }
  for (const term of ["sealed", "competitor", "frozen", "redacted", "live", "replay"]) {
    assert.match(product, new RegExp(term, "i"), `PRODUCT.md missing shared term ${term}`);
    assert.match(design, new RegExp(term, "i"), `DESIGN.md missing shared term ${term}`);
  }
  for (const flag of [
    "MOBILE_VIEWPORT_PASS",
    "PRIVACY_MATRIX_PASS",
    "BUNDLE_DYNAMIC_IMPORT_AUDIT_PASS",
    "FRONTEND_IMPECCABLE_AUDIT_PASS",
    "FRONTEND_IMPECCABLE_POLISH_PASS",
    "A11Y_KEYBOARD_TABLE_PASS",
  ]) {
    assert.ok(product.includes(flag), `PRODUCT.md missing evidence vocabulary ${flag}`);
  }
});

test("privacy matrix covers sensitive data, roles, boundaries, and future evidence", () => {
  const matrix = read("docs/frontend/privacy-matrix.md");
  assertIncludesAll(matrix, [
    "Allowed",
    "Generalized",
    "Hidden",
    "Tenant admin",
    "Auction manager",
    "Procurement analyst",
    "Carrier viewer",
    "Sealed competitor bids",
    "Own bid",
    "Reliability score detail",
    "Frozen export snapshot",
    "Redacted carrier explanation",
    "Raw solver internals and hashes",
    "UI",
    "DOM",
    "API/HTMX",
    "Export/report",
    "Logs",
    "Analytics",
    "confirmation",
    "redaction scope",
    "P1",
    "P2",
    "tests/authorization/",
    "tests/e2e/",
    "future evidence",
  ], "privacy matrix");
  assert.match(matrix, /Sealed competitor bids[^\n]*Hidden/i, "carrier outcome must hide competitor bids");
  assert.match(matrix, /Raw solver internals and hashes[^\n]*(?:Hidden[^\n]*){4}/i, "raw internals/hashes must be hidden from every role");
  assert.match(matrix, /competitor bids[^\n]*Hidden[^\n]*Hidden[^\n]*Hidden/i, "competitor bids must not cross DOM/export/telemetry boundaries");
  assert.match(matrix, /Export\/report[^\n]*confirmation/i, "export boundary must require confirmation");
  assertNoFillerOrInflatedEvidence(matrix, "privacy matrix");
});
