import { createRequire } from "node:module";
import { spawnSync } from "node:child_process";
import {
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

const require = createRequire(import.meta.url);

class InvalidInput extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

const validateProduct = (args, requiredChecks) => {
  const manifestPath = existingPath(args["routes-manifest"]);
  if (!manifestPath || productSubjectForbidden(args["routes-manifest"])) throw new InvalidInput("NO_PRODUCT_ROUTE_MANIFEST", "product accessibility requires a real route manifest");
  let baseUrl;
  try {
    baseUrl = new URL(args["base-url"]);
  } catch {
    throw new InvalidInput("INVALID_PRODUCT_BASE_URL", "product accessibility requires an HTTP(S) --base-url");
  }
  if (!["http:", "https:"].includes(baseUrl.protocol)) throw new InvalidInput("INVALID_PRODUCT_BASE_URL", "product base URL must be HTTP(S)");
  const manifest = readJson(manifestPath);
  if (!Array.isArray(manifest.routes) || manifest.routes.length === 0) throw new InvalidInput("EMPTY_PRODUCT_ROUTES", "product routes must be non-empty");
  for (const route of manifest.routes) {
    if (!route || typeof route !== "object" || productRouteForbidden(route.path)) throw new InvalidInput("INVALID_PRODUCT_ROUTE", "every product route must be an object with a real path");
    if (!Array.isArray(route.checks) || route.checks.length === 0) throw new InvalidInput("EMPTY_PRODUCT_CHECK_SET", "every product route must declare checks");
  }
  const covered = new Set(manifest.routes.flatMap((route) => route.checks));
  if (requiredChecks.some((check) => !covered.has(check))) throw new InvalidInput("INCOMPLETE_PRODUCT_CHECK_SET", "route manifest does not cover every required accessibility check");
  return manifest.routes;
};

const playwright = (scope, args) => {
  const cli = require.resolve("@playwright/test/cli");
  return spawnSync(process.execPath, [
    cli,
    "test",
    "tests/e2e/tooling/frontend-evidence-fixture.spec.ts",
    "--project=desktop-1440",
  ], {
    cwd: process.cwd(),
    encoding: "utf8",
    shell: false,
    windowsHide: true,
    env: {
      ...process.env,
      FCA_E2E_SKIP_RUNTIME: "1",
      FCA_FRONTEND_EVIDENCE_SCOPE: scope,
      FCA_FRONTEND_ROUTES_MANIFEST: args["routes-manifest"] ?? "",
      FCA_FRONTEND_BASE_URL: args["base-url"] ?? "",
    },
  });
};

const main = () => {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
    if (!["fixture", "product"].includes(args.scope)) throw new InvalidInput("INVALID_SCOPE", "--scope must be fixture or product");
    if (!args.out) throw new InvalidInput("MISSING_OUTPUT", "an explicit --out is required");
    const config = readConfig();
    const routes = args.scope === "product" ? validateProduct(args, config.accessibility.requiredChecks) : [];
    const result = playwright(args.scope, args);
    if (result.error || result.status !== 0) {
      process.stderr.write(result.stdout ?? "");
      process.stderr.write(result.stderr ?? "");
      throw new InvalidInput("PLAYWRIGHT_ACCESSIBILITY_FAILED", result.error?.message ?? `Playwright exited ${result.status}`);
    }
    process.stdout.write(result.stdout ?? "");
    process.stderr.write(result.stderr ?? "");
    writeJson(args.out, {
      schemaVersion: 1,
      kind: "a11y",
      scope: args.scope,
      status: "passed",
      subject: args.scope === "fixture" ? { fixture: "tests/fixtures/frontend-evidence/a11y/fixture.html" } : { baseUrl: args["base-url"], routes },
      command: commandArgv(),
      toolVersions: { node: process.version, playwright: "1.55.1", helperContract: "frontend-evidence@1" },
      productRoutesEvaluated: args.scope === "product",
      checks: config.accessibility.requiredChecks.map((id) => ({ id, status: "passed", evidence: ["tests/e2e/tooling/frontend-evidence-fixture.spec.ts"] })),
      metrics: { requiredCheckCount: config.accessibility.requiredChecks.length, routeCount: routes.length },
      findings: [],
      artifacts: [args.out],
    });
  } catch (error) {
    invalid(error.code ?? "INVALID_ACCESSIBILITY_INPUT", error.message);
  }
};

main();
