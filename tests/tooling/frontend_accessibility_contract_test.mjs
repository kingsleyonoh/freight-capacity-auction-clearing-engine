import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

const script = "scripts/frontend-a11y-evidence.mjs";
const packageJson = JSON.parse(readFileSync("package.json", "utf8"));
const run = (args) => spawnSync(process.execPath, [script, ...args], {
  cwd: process.cwd(),
  encoding: "utf8",
  shell: false,
});

const requiredChecks = [
  "keyboard-table-detail-parity",
  "dialog-escape-focus-return",
  "import-steps-errors-labelled",
  "chart-summary-equivalent-table",
  "visible-focus",
  "wcag-contrast",
  "semantic-status-not-color-only",
  "reduced-motion",
];

test("configuration and package commands expose the complete accessibility contract", () => {
  const config = JSON.parse(readFileSync("config/frontend-evidence.json", "utf8"));
  assert.deepEqual(config.accessibility.requiredChecks, requiredChecks);
  assert.equal(config.accessibility.minimumContrast.body, 4.5);
  assert.equal(config.accessibility.minimumContrast.largeText, 3);
  assert.equal(config.accessibility.minimumContrast.essentialGraphics, 3);
  assert.equal(typeof packageJson.scripts["frontend:a11y:fixture"], "string");
  assert.equal(typeof packageJson.scripts["frontend:a11y:product"], "string");
});

test("Playwright fixture and reusable helpers exercise behavior, not static declarations", () => {
  const helper = readFileSync("tests/e2e/helpers/frontend-evidence.ts", "utf8");
  const spec = readFileSync("tests/e2e/tooling/frontend-evidence-fixture.spec.ts", "utf8");
  const fixture = readFileSync("tests/fixtures/frontend-evidence/a11y/fixture.html", "utf8");
  assert.doesNotMatch(spec, /page\.setContent\s*\(/, "page.setContent cannot be evidence");
  for (const token of ["press('Enter')", "press('Escape')", "toBeFocused", "emulateMedia", "assertVisibleFocus", "assertContrast", "assertEquivalentChartTable"]) {
    assert.ok(`${helper}\n${spec}`.includes(token), `missing executable helper/spec token ${token}`);
  }
  for (const token of ["<table", "<dialog", "aria-describedby", "aria-current", "role=\"img\"", "prefers-reduced-motion", "status-icon", "Import step"]) {
    assert.ok(fixture.includes(token), `fixture missing ${token}`);
  }
});

test("product mode rejects missing/empty manifests and fixture/data/file routes with exit 2", () => {
  const root = mkdtempSync(join(tmpdir(), "fca-a11y-product-negative-"));
  const absentOut = join(root, "absent-out.json");
  const absent = run(["--scope", "product", "--routes-manifest", join(root, "missing.json"), "--base-url", "http://127.0.0.1:8080", "--out", absentOut]);
  assert.equal(absent.status, 2, absent.stderr || absent.stdout);
  assert.equal(existsSync(absentOut), false);

  for (const [name, routes] of [
    ["empty", []],
    ["file", ["file:///tmp/fixture.html"]],
    ["data", ["data:text/html,fixture"]],
    ["fixture", ["/tests/fixtures/frontend-evidence/a11y/fixture.html"]],
  ]) {
    const manifest = join(root, `${name}.json`);
    const out = join(root, `${name}-out.json`);
    writeFileSync(manifest, JSON.stringify({ schemaVersion: 1, routes }));
    const result = run(["--scope", "product", "--routes-manifest", manifest, "--base-url", "http://127.0.0.1:8080", "--out", out]);
    assert.equal(result.status, 2, `${name}: ${result.stderr || result.stdout}`);
    assert.equal(existsSync(out), false, `${name} must not emit a product PASS artifact`);
  }
});

test("product runner source rejects page.setContent and uses literal argv with shell false", () => {
  const source = readFileSync(script, "utf8");
  assert.doesNotMatch(source, /page\.setContent\s*\(/);
  assert.match(source, /shell:\s*false/);
  assert.match(source, /spawnSync\s*\(/);
});
