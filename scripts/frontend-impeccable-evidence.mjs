import { existsSync } from "node:fs";
import { isAbsolute } from "node:path";
import { spawnSync } from "node:child_process";
import {
  asArray,
  commandArgv,
  existingPath,
  invalid,
  parseArgs,
  productRouteForbidden,
  productSubjectForbidden,
  readConfig,
  readJson,
  writeJson,
} from "./frontend-evidence-common.mjs";

class InvalidInput extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

const requireProductRoutes = (manifestArgument) => {
  const manifestPath = existingPath(manifestArgument);
  if (!manifestPath || productSubjectForbidden(manifestArgument)) throw new InvalidInput("NO_PRODUCT_ROUTE_MANIFEST", "product audit requires a real route manifest");
  const manifest = readJson(manifestPath);
  if (!Array.isArray(manifest.routes) || manifest.routes.length === 0) throw new InvalidInput("EMPTY_PRODUCT_ROUTES", "product routes must be non-empty");
  const routes = manifest.routes.map((route) => typeof route === "string" ? route : route?.path);
  if (routes.some(productRouteForbidden)) throw new InvalidInput("INVALID_PRODUCT_ROUTE", "product route manifest contains fixture/data/file/invalid routes");
  return routes;
};

const validateScope = (scope) => {
  if (!["fixture", "product"].includes(scope)) throw new InvalidInput("INVALID_SCOPE", "--scope must be fixture or product");
};

const rawPathFor = (out) => out.endsWith(".json") ? out.slice(0, -5) + ".raw.json" : `${out}.raw.json`;

const runAudit = (args) => {
  validateScope(args.scope);
  const paths = asArray(args.paths);
  if (!args.out || paths.length === 0) throw new InvalidInput("EMPTY_AUDIT_PATHS", "audit requires explicit non-empty --paths and --out");
  for (const path of paths) {
    if (!existingPath(path)) throw new InvalidInput("AUDIT_PATH_UNAVAILABLE", `audit path is unavailable: ${path}`);
    if (args.scope === "product" && productSubjectForbidden(path)) throw new InvalidInput("PRODUCT_PATH_FORBIDDEN", `product audit rejects fixture/data/file subject: ${path}`);
  }
  const executable = args["detector-executable"];
  const detectorVersion = args["detector-version"];
  if (!executable || !detectorVersion) throw new InvalidInput("DETECTOR_UNRESOLVED", "detector executable and exact version are required");
  if (args.scope === "product" && (!isAbsolute(executable) || !existsSync(executable))) {
    throw new InvalidInput("DETECTOR_NOT_EXPLICITLY_RESOLVED", "product detector executable must be an existing absolute path");
  }
  const routes = args.scope === "product" ? requireProductRoutes(args["routes-manifest"]) : [];
  const detectorArgv = [...asArray(args["detector-prefix"]), "detect", "--fast", "--json", ...paths];
  const detector = spawnSync(executable, detectorArgv, {
    cwd: process.cwd(),
    encoding: "utf8",
    shell: false,
    windowsHide: true,
  });
  if (detector.error || detector.status !== 0) {
    throw new InvalidInput("DETECTOR_UNAVAILABLE", detector.error?.message ?? `detector exited ${detector.status}`);
  }
  let payload;
  try {
    payload = JSON.parse(detector.stdout);
  } catch {
    throw new InvalidInput("MALFORMED_DETECTOR_OUTPUT", "detector stdout was not JSON");
  }
  if (!payload || typeof payload !== "object" || !Array.isArray(payload.findings)) {
    throw new InvalidInput("MALFORMED_DETECTOR_OUTPUT", "detector JSON requires a findings array");
  }
  const findings = payload.findings.map((item) => ({
    severity: item.severity,
    code: item.code,
    message: item.message,
  }));
  if (findings.some((item) => !["P0", "P1", "P2", "P3"].includes(item.severity) || !item.code || !item.message)) {
    throw new InvalidInput("MALFORMED_DETECTOR_FINDING", "detector findings require severity, code, and message");
  }
  writeJson(rawPathFor(args.out), payload);
  const blocking = new Set(readConfig().impeccable.blockingSeverities);
  const status = findings.some((item) => blocking.has(item.severity)) ? "failed" : "passed";
  writeJson(args.out, {
    schemaVersion: 1,
    kind: "impeccable-audit",
    scope: args.scope,
    status,
    subject: { paths, routes },
    command: commandArgv(),
    detectorCommand: [executable, ...detectorArgv],
    toolVersions: { node: process.version, impeccableDetector: detectorVersion },
    productRoutesEvaluated: args.scope === "product",
    checks: [{ id: "detector-findings", status, evidence: [rawPathFor(args.out)] }],
    metrics: { findingCount: findings.length, blockingFindingCount: findings.filter((item) => blocking.has(item.severity)).length },
    findings,
    artifacts: [args.out, rawPathFor(args.out)],
  });
  return status === "passed" ? 0 : 1;
};

const validateScreenshots = (scope, screenshots) => {
  if (!Array.isArray(screenshots) || screenshots.length === 0) throw new InvalidInput("MISSING_POLISH_SCREENSHOTS", "polish dossier requires screenshots");
  const finals = screenshots.filter((shot) => shot.phase === "final" && shot.path && shot.rationale);
  if (finals.length === 0) throw new InvalidInput("MISSING_FINAL_SCREENSHOT", "a final screenshot with rationale is required");
  if (scope === "product") {
    for (const shot of screenshots) {
      if (productSubjectForbidden(shot.path) || !existingPath(shot.path)) throw new InvalidInput("INVALID_PRODUCT_SCREENSHOT", "product screenshots must be existing non-fixture files");
    }
  }
};

const runPolish = (args) => {
  validateScope(args.scope);
  const dossierPath = existingPath(args.dossier);
  if (!dossierPath || !args.out) throw new InvalidInput("NO_POLISH_DOSSIER", "polish requires an existing --dossier and explicit --out");
  if (args.scope === "product" && productSubjectForbidden(args.dossier)) throw new InvalidInput("PRODUCT_DOSSIER_FORBIDDEN", "product dossier cannot be fixture/data/file evidence");
  const dossier = readJson(dossierPath);
  if (dossier.scope !== args.scope) throw new InvalidInput("DOSSIER_SCOPE_MISMATCH", "dossier scope must match command scope");
  if (!Array.isArray(dossier.routes) || dossier.routes.length === 0) throw new InvalidInput("EMPTY_DOSSIER_ROUTES", "dossier routes must be non-empty");
  if (args.scope === "product" && dossier.routes.some(productRouteForbidden)) throw new InvalidInput("INVALID_DOSSIER_ROUTE", "product dossier routes must be real product paths");
  const auditPath = existingPath(dossier.auditArtifact);
  if (!auditPath) throw new InvalidInput("MISSING_AUDIT_ARTIFACT", "dossier audit artifact is unavailable");
  const audit = readJson(auditPath);
  if (audit.scope !== args.scope || audit.status !== "passed" || audit.productRoutesEvaluated !== (args.scope === "product")) {
    throw new InvalidInput("AUDIT_ARTIFACT_INELIGIBLE", "polish requires a passed audit artifact at the same scope");
  }
  validateScreenshots(args.scope, dossier.screenshots);
  const required = readConfig().impeccable.requiredPolishChecklist;
  if (!dossier.checklist || required.some((key) => typeof dossier.checklist[key] !== "string" || dossier.checklist[key].trim() === "")) {
    throw new InvalidInput("INCOMPLETE_POLISH_CHECKLIST", "polish checklist is incomplete");
  }
  if (!Array.isArray(dossier.findings)) throw new InvalidInput("INVALID_POLISH_FINDINGS", "polish findings must be an array");
  const blocking = new Set(readConfig().impeccable.blockingSeverities);
  const findings = dossier.findings;
  const status = findings.some((item) => blocking.has(item.severity)) ? "failed" : "passed";
  writeJson(args.out, {
    schemaVersion: 1,
    kind: "impeccable-polish",
    scope: args.scope,
    status,
    subject: { dossier: args.dossier, routes: dossier.routes },
    command: commandArgv(),
    toolVersions: { node: process.version, validator: "frontend-impeccable-dossier@1" },
    productRoutesEvaluated: args.scope === "product",
    checks: required.map((id) => ({ id, status: "passed", evidence: [dossier.checklist[id]] })),
    metrics: { screenshotCount: dossier.screenshots.length, findingCount: findings.length },
    findings,
    artifacts: [args.out, ...dossier.screenshots.map((shot) => shot.path)],
  });
  return status === "passed" ? 0 : 1;
};

const main = () => {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
    const mode = args._[0];
    if (mode === "audit") process.exitCode = runAudit(args);
    else if (mode === "polish") process.exitCode = runPolish(args);
    else if (mode === "fixture") {
      const auditCode = runAudit({ ...args, scope: "fixture", out: args["audit-out"] });
      if (auditCode !== 0) process.exitCode = auditCode;
      else process.exitCode = runPolish({ ...args, scope: "fixture", out: args["polish-out"] });
    } else throw new InvalidInput("INVALID_MODE", "mode must be audit, polish, or fixture");
  } catch (error) {
    invalid(error.code ?? "INVALID_IMPECCABLE_INPUT", error.message);
  }
};

main();
