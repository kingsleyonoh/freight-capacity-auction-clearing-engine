import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

const script = "scripts/frontend-impeccable-evidence.mjs";
const packageJson = JSON.parse(readFileSync("package.json", "utf8"));
const run = (args) => spawnSync(process.execPath, [script, ...args], {
  cwd: process.cwd(),
  encoding: "utf8",
  shell: false,
});

const detector = (payload, { exitCode = 0 } = {}) => {
  const root = mkdtempSync(join(tmpdir(), "fca-impeccable-detector-"));
  const detectorPath = join(root, "detector.mjs");
  const argvPath = join(root, "argv.json");
  writeFileSync(detectorPath, [
    "import { writeFileSync } from 'node:fs';",
    `writeFileSync(${JSON.stringify(argvPath)}, JSON.stringify(process.argv.slice(2)));`,
    `process.stdout.write(${JSON.stringify(JSON.stringify(payload))});`,
    `process.exitCode = ${exitCode};`,
  ].join("\n"));
  return { root, detectorPath, argvPath };
};

const auditArgs = ({ detectorPath, subjectPath, out }) => [
  "audit",
  "--scope", "fixture",
  "--detector-executable", process.execPath,
  "--detector-prefix", detectorPath,
  "--detector-version", "fixture-detector@1.0.0",
  "--paths", subjectPath,
  "--out", out,
];

const validDossier = (auditArtifact) => ({
  schemaVersion: 1,
  scope: "fixture",
  auditArtifact,
  routes: ["fixture://impeccable-contract"],
  screenshots: [{ phase: "final", path: "tests/fixtures/frontend-evidence/impeccable/final.fixture.png", rationale: "Schema-only fixture reference; not product visual proof." }],
  checklist: {
    interactionStates: "reviewed",
    typography: "reviewed",
    spacing: "reviewed",
    color: "reviewed",
    motion: "reviewed",
    copy: "reviewed",
    tokenDrift: "none",
  },
  findings: [],
});

test("package exposes fixture, product audit, and dossier-only polish commands", () => {
  for (const name of ["frontend:impeccable:fixture", "frontend:impeccable:audit", "frontend:impeccable:polish"]) {
    assert.equal(typeof packageJson.scripts[name], "string", `missing ${name}`);
  }
});

test("audit invokes an injected detector with exact argv and shell-free process semantics", () => {
  const fake = detector({ schemaVersion: 1, findings: [] });
  const subjectPath = join(fake.root, "subject.html");
  const out = join(fake.root, "audit.json");
  writeFileSync(subjectPath, "<!doctype html><title>fixture</title>");
  const result = run(auditArgs({ detectorPath: fake.detectorPath, subjectPath, out }));
  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.deepEqual(JSON.parse(readFileSync(fake.argvPath, "utf8")), ["detect", "--fast", "--json", subjectPath]);
  const artifact = JSON.parse(readFileSync(out, "utf8"));
  assert.equal(artifact.scope, "fixture");
  assert.equal(artifact.productRoutesEvaluated, false);
  assert.equal(artifact.toolVersions.impeccableDetector, "fixture-detector@1.0.0");
  assert.equal(artifact.status, "passed");
  assert.ok(existsSync(out.replace(/\.json$/, ".raw.json")));
});

test("malformed or unavailable detector output fails closed", () => {
  const fake = detector("not-json", { exitCode: 0 });
  const subjectPath = join(fake.root, "subject.html");
  const out = join(fake.root, "audit.json");
  writeFileSync(subjectPath, "fixture");
  const malformed = run(auditArgs({ detectorPath: fake.detectorPath, subjectPath, out }));
  assert.equal(malformed.status, 2, malformed.stderr || malformed.stdout);
  assert.equal(existsSync(out), false);

  const unavailableOut = join(fake.root, "unavailable.json");
  const unavailable = run(auditArgs({ detectorPath: join(fake.root, "missing-detector"), subjectPath, out: unavailableOut }));
  assert.equal(unavailable.status, 2, unavailable.stderr || unavailable.stdout);
  assert.equal(existsSync(unavailableOut), false);
});

test("P0/P1 detector findings fail the audit with normalized evidence", () => {
  const fake = detector({ schemaVersion: 1, findings: [{ severity: "P1", code: "FOCUS_MISSING", message: "Missing focus state" }] });
  const subjectPath = join(fake.root, "subject.html");
  const out = join(fake.root, "audit.json");
  writeFileSync(subjectPath, "fixture");
  const result = run(auditArgs({ detectorPath: fake.detectorPath, subjectPath, out }));
  assert.equal(result.status, 1, result.stderr || result.stdout);
  const artifact = JSON.parse(readFileSync(out, "utf8"));
  assert.equal(artifact.status, "failed");
  assert.equal(artifact.findings[0].severity, "P1");
});

test("product audit rejects fixture/data/file subjects and absent route/detector details", () => {
  const root = mkdtempSync(join(tmpdir(), "fca-impeccable-product-negative-"));
  const out = join(root, "must-not-exist.json");
  const fixtureSubject = "tests/fixtures/frontend-evidence/impeccable/subject.html";
  const fixtureResult = run(["audit", "--scope", "product", "--paths", fixtureSubject, "--out", out]);
  assert.equal(fixtureResult.status, 2, fixtureResult.stderr || fixtureResult.stdout);
  assert.equal(existsSync(out), false);

  const productSubject = join(root, "product.html");
  writeFileSync(productSubject, "<!doctype html><title>product-shaped negative probe</title>");
  const missingRoutes = run([
    "audit", "--scope", "product",
    "--detector-executable", process.execPath,
    "--detector-version", "explicit-negative-probe@1.0.0",
    "--paths", productSubject,
    "--out", out,
  ]);
  assert.equal(missingRoutes.status, 2, missingRoutes.stderr || missingRoutes.stdout);
  assert.equal(existsSync(out), false);
});

test("polish validates a complete dossier and never mutates aesthetic source", () => {
  const root = mkdtempSync(join(tmpdir(), "fca-impeccable-polish-"));
  const auditArtifact = join(root, "audit.json");
  const dossierPath = join(root, "dossier.json");
  const out = join(root, "polish.json");
  writeFileSync(auditArtifact, JSON.stringify({ scope: "fixture", status: "passed", productRoutesEvaluated: false, findings: [] }));
  writeFileSync(dossierPath, JSON.stringify(validDossier(auditArtifact)));
  const result = run(["polish", "--scope", "fixture", "--dossier", dossierPath, "--out", out]);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  const artifact = JSON.parse(readFileSync(out, "utf8"));
  assert.equal(artifact.kind, "impeccable-polish");
  assert.equal(artifact.scope, "fixture");
  assert.equal(artifact.productRoutesEvaluated, false);
  assert.equal(artifact.status, "passed");
});

test("polish rejects incomplete product dossiers with exit 2 and no pass artifact", () => {
  const root = mkdtempSync(join(tmpdir(), "fca-impeccable-polish-negative-"));
  const dossierPath = join(root, "dossier.json");
  const out = join(root, "must-not-exist.json");
  writeFileSync(dossierPath, JSON.stringify({ schemaVersion: 1, scope: "product", routes: [] }));
  const result = run(["polish", "--scope", "product", "--dossier", dossierPath, "--out", out]);
  assert.equal(result.status, 2, result.stderr || result.stdout);
  assert.equal(existsSync(out), false);
});
