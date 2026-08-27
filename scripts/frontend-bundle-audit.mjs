import { readFileSync } from "node:fs";
import { dirname, isAbsolute, resolve } from "node:path";
import { gzipSync } from "node:zlib";
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

const finding = (code, message, severity = "P1") => ({ severity, code, message });

const staticClosure = (entries, assets) => {
  const visited = new Set();
  const queue = [...entries];
  while (queue.length > 0) {
    const id = queue.shift();
    if (visited.has(id)) continue;
    const asset = assets[id];
    if (!asset) throw new Error(`manifest references missing asset ${id}`);
    visited.add(id);
    for (const imported of asset.imports ?? []) queue.push(imported);
  }
  return visited;
};

const dynamicReachable = (staticIds, assets) => {
  const reached = new Set();
  const queue = [];
  for (const id of staticIds) queue.push(...(assets[id].dynamicImports ?? []));
  while (queue.length > 0) {
    const id = queue.shift();
    if (reached.has(id)) continue;
    const asset = assets[id];
    if (!asset) throw new Error(`manifest references missing dynamic asset ${id}`);
    reached.add(id);
    queue.push(...(asset.imports ?? []), ...(asset.dynamicImports ?? []));
  }
  return reached;
};

const assetPath = (manifestPath, manifest, asset) => {
  const root = manifest.assetRoot ?? ".";
  const base = isAbsolute(root) ? root : resolve(dirname(manifestPath), root);
  return resolve(base, asset.file);
};

const validateSubject = (scope, manifestPath, manifest) => {
  if (!["fixture", "product"].includes(scope)) throw new Error("--scope must be fixture or product");
  if (!Array.isArray(manifest.entries) || manifest.entries.length === 0) throw new Error("manifest entries must be non-empty");
  if (!manifest.assets || Object.keys(manifest.assets).length === 0) throw new Error("manifest assets must be non-empty");
  if (scope === "product") {
    if (productSubjectForbidden(manifestPath)) throw new Error("product manifest cannot be a fixture/data/file subject");
    if (/fixture/i.test(String(manifest.generatedBy ?? ""))) throw new Error("product manifest cannot be fixture-generated");
    if (!Array.isArray(manifest.routes) || manifest.routes.length === 0) throw new Error("product manifest routes must be non-empty");
    if (manifest.routes.some(productRouteForbidden)) throw new Error("product manifest contains an invalid route");
  }
};

const main = () => {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (error) {
    invalid("INVALID_ARGUMENTS", error.message);
    return;
  }
  const scope = args.scope;
  const out = args.out;
  const manifestPath = existingPath(args.manifest);
  if (!out || !manifestPath) {
    invalid("NO_BUNDLE_MANIFEST", "an existing --manifest and explicit --out are required");
    return;
  }

  let manifest;
  let staticIds;
  let dynamicIds;
  try {
    manifest = readJson(manifestPath);
    validateSubject(scope, args.manifest, manifest);
    staticIds = staticClosure(manifest.entries, manifest.assets);
    dynamicIds = dynamicReachable(staticIds, manifest.assets);
  } catch (error) {
    invalid("INVALID_BUNDLE_MANIFEST", error.message);
    return;
  }

  const config = readConfig();
  const findings = [];
  const gzipByAsset = {};
  let initialGzipBytes = 0;
  try {
    for (const id of staticIds) {
      const path = assetPath(manifestPath, manifest, manifest.assets[id]);
      const bytes = gzipSync(readFileSync(path), { level: 9 }).length;
      gzipByAsset[id] = bytes;
      initialGzipBytes += bytes;
    }
  } catch (error) {
    invalid("BUNDLE_ASSET_UNAVAILABLE", error.message);
    return;
  }

  if (initialGzipBytes > config.bundle.maxInitialGzipBytes) {
    findings.push(finding("INITIAL_GZIP_LIMIT_EXCEEDED", `${initialGzipBytes} exceeds ${config.bundle.maxInitialGzipBytes}`));
  }

  const allowedRoutes = config.bundle.allowedDynamicRoutePatterns.map((pattern) => new RegExp(pattern));
  for (const [id, asset] of Object.entries(manifest.assets)) {
    if (!config.bundle.heavyKinds.includes(asset.kind)) continue;
    if (staticIds.has(id)) findings.push(finding("HEAVY_CHUNK_STATIC", `${id} (${asset.kind}) is in the initial static closure`));
    if (!dynamicIds.has(id)) findings.push(finding("HEAVY_CHUNK_NOT_DYNAMIC", `${id} (${asset.kind}) is not dynamically reachable`));
    if (!Array.isArray(asset.routes) || asset.routes.length === 0) {
      findings.push(finding("HEAVY_CHUNK_ROUTES_EMPTY", `${id} has no route assignments`));
      continue;
    }
    for (const route of asset.routes) {
      if (!allowedRoutes.some((pattern) => pattern.test(route))) {
        findings.push(finding("HEAVY_CHUNK_ROUTE_FORBIDDEN", `${id} is assigned to forbidden route ${route}`));
      }
    }
  }

  const status = findings.length === 0 ? "passed" : "failed";
  writeJson(out, {
    schemaVersion: 1,
    kind: "bundle",
    scope,
    status,
    subject: { manifest: args.manifest, entries: manifest.entries },
    command: commandArgv(),
    toolVersions: { node: process.version, gzip: "node:zlib level=9" },
    productRoutesEvaluated: scope === "product",
    checks: [
      { id: "computed-initial-gzip", status: initialGzipBytes <= config.bundle.maxInitialGzipBytes ? "passed" : "failed", evidence: Object.entries(gzipByAsset).map(([path, bytes]) => ({ path, bytes })) },
      { id: "static-import-closure", status: findings.some((item) => item.code === "HEAVY_CHUNK_STATIC") ? "failed" : "passed", evidence: [...staticIds] },
      { id: "route-only-heavy-chunks", status: findings.some((item) => item.code.startsWith("HEAVY_CHUNK_")) ? "failed" : "passed", evidence: [...dynamicIds] },
    ],
    metrics: { initialGzipBytes, maxInitialGzipBytes: config.bundle.maxInitialGzipBytes, gzipByAsset },
    findings,
    artifacts: [out],
  });
  process.exitCode = status === "passed" ? 0 : 1;
};

main();
