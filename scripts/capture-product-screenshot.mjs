import { mkdirSync } from "node:fs";
import { resolve } from "node:path";
import { chromium } from "@playwright/test";

const output = resolve("tests/_artifacts/frontend-evidence/product-control-desk-1440.png");
mkdirSync(resolve("tests/_artifacts/frontend-evidence"), { recursive: true });
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, deviceScaleFactor: 1 });
  await page.goto(process.env.FCA_FRONTEND_BASE_URL ?? "http://localhost:18080", { waitUntil: "networkidle" });
  await page.screenshot({ path: output, fullPage: true });
} finally {
  await browser.close();
}
