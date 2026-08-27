import { readFileSync } from "node:fs";

const jsonIndex = process.argv.indexOf("--json");
const paths = jsonIndex < 0 ? [] : process.argv.slice(jsonIndex + 1);
const findings = [];
for (const path of paths) {
  const source = readFileSync(path, "utf8");
  if (source.includes("lorem ipsum") || /TODO|FIXME/.test(source)) {
    findings.push({ severity: "P1", code: "PRODUCT_FILLER", message: `${path} contains forbidden filler` });
  }
}
process.stdout.write(JSON.stringify({ schemaVersion: 1, detector: "fca-product-style-gate", findings }));
