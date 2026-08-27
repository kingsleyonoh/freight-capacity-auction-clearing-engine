import { resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const mode = process.argv[2] ?? "audit";
const script = resolve(root, "scripts/frontend-impeccable-evidence.mjs");
const args = [script, mode, "--scope", "product"];

if (mode === "audit") {
  args.push(
    "--paths", "./src/ui/static/app.css",
    "--paths", "./src/ui/static/htmx.min.js",
    "--out", "./tests/_artifacts/frontend-evidence/impeccable-product.json",
    "--detector-executable", process.execPath,
    "--detector-version", "fca-product-detector@1",
    "--detector-prefix", "./scripts/product-impeccable-detector.mjs",
    "--routes-manifest", "./config/routes.product.json",
  );
} else if (mode === "polish") {
  args.push(
    "--dossier", "./config/polish-dossier.product.json",
    "--out", "./tests/_artifacts/frontend-evidence/impeccable-polish-product.json",
  );
} else {
  process.stderr.write(`unknown impeccable mode: ${mode}\n`);
  process.exit(2);
}

const result = spawnSync(process.execPath, args, { cwd: root, stdio: "inherit", shell: false, windowsHide: true });
process.exit(result.error ? 1 : (result.status ?? 1));
