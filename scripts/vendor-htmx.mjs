import { copyFileSync, mkdirSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const source = resolve(root, "node_modules/htmx.org/dist/htmx.min.js");
const targetDir = resolve(root, "src/ui/static");
const target = resolve(targetDir, "htmx.min.js");
mkdirSync(targetDir, { recursive: true });
copyFileSync(source, target);
process.stdout.write(`vendored ${target}\n`);
