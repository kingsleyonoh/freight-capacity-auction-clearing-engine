import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { gzipSync } from "node:zlib";

const script = "scripts/frontend-bundle-audit.mjs";
const packageJson = JSON.parse(readFileSync("package.json", "utf8"));

const run = (args) => spawnSync(process.execPath, [script, ...args], {
  cwd: process.cwd(),
  encoding: "utf8",
  shell: false,
});

const pseudoRandomBytes = (() => {
  let value = 0x12345678;
  const bytes = Buffer.alloc(205000);
  for (let index = 0; index < bytes.length; index += 1) {
    value ^= value << 13;
    value ^= value >>> 17;
    value ^= value << 5;
    bytes[index] = value & 0xff;
  }
  return bytes;
})();

const bytesWithExactGzipSize = (target) => {
  for (let length = target - 500; length <= target; length += 1) {
    const bytes = pseudoRandomBytes.subarray(0, length);
    if (gzipSync(bytes, { level: 9 }).length === target) return bytes;
  }
  throw new Error(`could not construct deterministic gzip size ${target}`);
};

const subject = ({ gzipBytes = 64, staticHeavy = false, heavyRoute = "/replays/run-1" } = {}) => {
  const root = mkdtempSync(join(tmpdir(), "fca-bundle-contract-"));
  const assets = join(root, "assets");
  mkdirSync(assets);
  writeFileSync(join(assets, "app.js"), gzipBytes > 1000 ? bytesWithExactGzipSize(gzipBytes) : "export const app = true;\n");
  writeFileSync(join(assets, "shell.js"), "export const shell = true;\n");
  writeFileSync(join(assets, "chart.js"), "export const chart = true;\n");
  const manifest = {
    schemaVersion: 1,
    generatedBy: "controlled-fixture",
    assetRoot: "assets",
    entries: ["app"],
    assets: {
      app: { file: "app.js", kind: "entry", imports: staticHeavy ? ["chart"] : [], dynamicImports: staticHeavy ? [] : ["chart"] },
      shell: { file: "shell.js", kind: "shared", imports: [], dynamicImports: [] },
      chart: { file: "chart.js", kind: "chart", imports: [], dynamicImports: [], routes: [heavyRoute] },
    },
  };
  const manifestPath = join(root, "manifest.json");
  const out = join(root, "artifact.json");
  writeFileSync(manifestPath, JSON.stringify(manifest));
  return { root, manifestPath, out };
};

test("package exposes fixture/product bundle commands and the combined contract gate", () => {
  assert.equal(typeof packageJson.scripts["frontend:bundle:fixture"], "string");
  assert.equal(typeof packageJson.scripts["frontend:bundle:product"], "string");
  assert.equal(typeof packageJson.scripts["frontend:evidence:contracts"], "string");
});

test("audit computes the exact 204800-byte gzip boundary from the asset", () => {
  const exact = subject({ gzipBytes: 204800 });
  const result = run(["--scope", "fixture", "--manifest", exact.manifestPath, "--out", exact.out]);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  const artifact = JSON.parse(readFileSync(exact.out, "utf8"));
  assert.equal(artifact.scope, "fixture");
  assert.equal(artifact.productRoutesEvaluated, false);
  assert.equal(artifact.metrics.initialGzipBytes, 204800);
  assert.equal(artifact.status, "passed");
});

test("audit fails at 204801 computed gzip bytes", () => {
  const over = subject({ gzipBytes: 204801 });
  const result = run(["--scope", "fixture", "--manifest", over.manifestPath, "--out", over.out]);
  assert.equal(result.status, 1, result.stderr || result.stdout);
  const artifact = JSON.parse(readFileSync(over.out, "utf8"));
  assert.equal(artifact.metrics.initialGzipBytes, 204801);
  assert.ok(artifact.findings.some((finding) => finding.code === "INITIAL_GZIP_LIMIT_EXCEEDED"));
});

test("audit walks static closure and rejects statically imported chart code", () => {
  const invalid = subject({ staticHeavy: true });
  const result = run(["--scope", "fixture", "--manifest", invalid.manifestPath, "--out", invalid.out]);
  assert.equal(result.status, 1, result.stderr || result.stdout);
  const artifact = JSON.parse(readFileSync(invalid.out, "utf8"));
  assert.ok(artifact.findings.some((finding) => finding.code === "HEAVY_CHUNK_STATIC"));
});

test("dynamic chart/frontier chunks are restricted to replay/results routes", () => {
  const invalid = subject({ heavyRoute: "/dashboard" });
  const result = run(["--scope", "fixture", "--manifest", invalid.manifestPath, "--out", invalid.out]);
  assert.equal(result.status, 1, result.stderr || result.stdout);
  const artifact = JSON.parse(readFileSync(invalid.out, "utf8"));
  assert.ok(artifact.findings.some((finding) => finding.code === "HEAVY_CHUNK_ROUTE_FORBIDDEN"));
});

test("product mode fails closed without a real non-empty build/route manifest and emits no artifact", () => {
  const root = mkdtempSync(join(tmpdir(), "fca-bundle-product-negative-"));
  const out = join(root, "must-not-exist.json");
  const absent = run(["--scope", "product", "--manifest", join(root, "absent.json"), "--out", out]);
  assert.equal(absent.status, 2, absent.stderr || absent.stdout);
  assert.throws(() => readFileSync(out));

  mkdirSync(join(root, "assets"));
  writeFileSync(join(root, "assets", "app.js"), "export const app = true;");
  const emptyRoutesManifest = join(root, "product-manifest.json");
  writeFileSync(emptyRoutesManifest, JSON.stringify({
    schemaVersion: 1,
    generatedBy: "pinned-builder@1.0.0",
    assetRoot: "assets",
    entries: ["app"],
    routes: [],
    assets: { app: { file: "app.js", kind: "entry", imports: [], dynamicImports: [] } },
  }));
  const emptyRoutes = run(["--scope", "product", "--manifest", emptyRoutesManifest, "--out", out]);
  assert.equal(emptyRoutes.status, 2, emptyRoutes.stderr || emptyRoutes.stdout);
  assert.throws(() => readFileSync(out));
});
