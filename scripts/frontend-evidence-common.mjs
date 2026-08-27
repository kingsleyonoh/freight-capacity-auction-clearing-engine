import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

export const parseArgs = (argv) => {
  const values = { _: [] };
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith("--")) {
      values._.push(token);
      continue;
    }
    const key = token.slice(2);
    const next = argv[index + 1];
    if (!next || next.startsWith("--")) throw new Error(`missing value for --${key}`);
    index += 1;
    if (values[key] === undefined) values[key] = next;
    else if (Array.isArray(values[key])) values[key].push(next);
    else values[key] = [values[key], next];
  }
  return values;
};

export const asArray = (value) => value === undefined ? [] : Array.isArray(value) ? value : [value];

export const readJson = (path) => JSON.parse(readFileSync(path, "utf8"));

export const readConfig = () => readJson(resolve(projectRoot, "config/frontend-evidence.json"));

export const writeJson = (path, value) => {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
};

export const commandArgv = () => [process.execPath, ...process.argv.slice(1)];

export const productSubjectForbidden = (subject) => {
  if (typeof subject !== "string" || subject.trim() === "") return true;
  const normalized = subject.replaceAll("\\", "/").toLowerCase();
  if (/^(?:file|data):/.test(normalized)) return true;
  return /(?:^|\/)fixtures?(?:\/|$)/.test(normalized) || /(?:^|\/)data(?:\/|$)/.test(normalized);
};

export const productRouteForbidden = (route) => {
  if (typeof route !== "string" || route.trim() === "") return true;
  const normalized = route.toLowerCase();
  if (/^(?:file|data):/.test(normalized)) return true;
  return !normalized.startsWith("/") || /(?:^|\/)fixtures?(?:\/|$)/.test(normalized) || /(?:^|\/)data(?:\/|$)/.test(normalized);
};

export const existingPath = (path) => {
  if (typeof path !== "string" || path.trim() === "") return null;
  const resolved = isAbsolute(path) ? path : resolve(projectRoot, path);
  return existsSync(resolved) ? resolved : null;
};

export const invalid = (code, message) => {
  process.stderr.write(`${JSON.stringify({ status: "invalid", code, message })}\n`);
  process.exitCode = 2;
};
