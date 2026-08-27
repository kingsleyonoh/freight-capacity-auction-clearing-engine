import { createServer, type Server } from 'node:http';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { expect, test, type Page } from '@playwright/test';
import { assertContrast, assertEquivalentChartTable, assertReducedMotion, assertVisibleFocus } from '../helpers/frontend-evidence';

const scope = process.env.FCA_FRONTEND_EVIDENCE_SCOPE === 'product' ? 'product' : 'fixture';
let server: Server | undefined;
let fixtureUrl = '';

const listen = (target: Server) => new Promise<number>((resolvePort, reject) => {
  target.once('error', reject);
  target.listen(0, '127.0.0.1', () => {
    const address = target.address();
    if (!address || typeof address === 'string') reject(new Error('fixture server did not expose a TCP port'));
    else resolvePort(address.port);
  });
});

const close = (target: Server) => new Promise<void>((resolveClose, reject) => target.close((error) => error ? reject(error) : resolveClose()));

test.beforeAll(async () => {
  if (scope !== 'fixture') return;
  const html = readFileSync(resolve('tests/fixtures/frontend-evidence/a11y/fixture.html'));
  server = createServer((request, response) => {
    if (request.url !== '/frontend-evidence') {
      response.writeHead(404).end('not found');
      return;
    }
    response.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
    response.end(html);
  });
  const port = await listen(server);
  fixtureUrl = `http://127.0.0.1:${port}/frontend-evidence`;
});

test.afterAll(async () => {
  if (server) await close(server);
});

const exerciseFixture = async (page: Page) => {
  await page.goto(fixtureUrl);

  const rowAction = page.getByRole('button', { name: 'Open Lane A details' });
  await rowAction.focus();
  await rowAction.press('Enter');
  await expect(page.getByRole('region', { name: 'Lane A detail' })).toContainText('Lane A · Carrier North · 1200 USD');

  const dialogOpener = page.getByRole('button', { name: 'Review import warning' });
  await dialogOpener.focus();
  await dialogOpener.press('Enter');
  const dialog = page.getByRole('dialog', { name: 'Import warning review' });
  await expect(dialog).toBeVisible();
  await expect(dialog.getByRole('button', { name: 'Acknowledge warning' })).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(dialog).toBeHidden();
  await expect(dialogOpener).toBeFocused();

  await expect(page.getByRole('list', { name: 'Import steps' })).toBeVisible();
  await expect(page.getByText('Import step 2: Map columns')).toHaveAttribute('aria-current', 'step');
  const equipment = page.getByLabel('Equipment column');
  await expect(equipment).toHaveAttribute('aria-describedby', 'equipment-error');
  await expect(page.locator('#equipment-error')).toHaveAttribute('role', 'alert');

  await expect(page.getByRole('img', { name: 'Cost and service frontier' })).toHaveAttribute('aria-describedby', 'chart-summary');
  await assertEquivalentChartTable(page, '#chart-summary', '#chart-data');
  await assertVisibleFocus(rowAction);
  await assertContrast(page, 'body', 4.5);
  await assertContrast(page, '.large-copy', 3);
  await assertContrast(page, '.essential-graphic', 3);

  const status = page.locator('.risk-status');
  await expect(status).toContainText('High service risk');
  await expect(status.locator('.status-icon')).toHaveAttribute('aria-hidden', 'true');
  await assertReducedMotion(page, '.motion-probe');
};

const exerciseProductRoute = async (page: Page, route: any) => {
  await page.goto(new URL(route.path, process.env.FCA_FRONTEND_BASE_URL).toString());
  const locators = route.locators ?? {};
  if (route.checks.includes('keyboard-table-detail-parity')) {
    const action = page.locator(locators.rowAction);
    await action.focus();
    await action.press('Enter');
    await expect(page.locator(locators.detailPanel)).toContainText(locators.expectedDetailText);
  }
  if (route.checks.includes('dialog-escape-focus-return')) {
    const opener = page.locator(locators.dialogOpener);
    await opener.press('Enter');
    await expect(page.locator(locators.dialog)).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(opener).toBeFocused();
  }
  if (route.checks.includes('import-steps-errors-labelled')) {
    await expect(page.locator(locators.importSteps)).toHaveAttribute('aria-label', /.+/);
    await expect(page.locator(locators.currentImportStep)).toHaveAttribute('aria-current', 'step');
    await expect(page.locator(locators.importInput)).toHaveAttribute('aria-describedby', /.+/);
  }
  if (route.checks.includes('chart-summary-equivalent-table')) await assertEquivalentChartTable(page, locators.chartSummary, locators.chartTable);
  if (route.checks.includes('visible-focus')) await assertVisibleFocus(page.locator(locators.focusTarget));
  if (route.checks.includes('wcag-contrast')) {
    for (const item of locators.contrast ?? []) await assertContrast(page, item.selector, item.minimum);
  }
  if (route.checks.includes('semantic-status-not-color-only')) await expect(page.locator(locators.semanticStatus)).toContainText(/\w+/);
  if (route.checks.includes('reduced-motion')) await assertReducedMotion(page, locators.motionTarget);
};

if (scope === 'fixture') {
  test('controlled fixture executes the complete keyboard, semantic, contrast, and motion contract', async ({ page }) => {
    await exerciseFixture(page);
  });
} else {
  const manifest = JSON.parse(readFileSync(resolve(process.env.FCA_FRONTEND_ROUTES_MANIFEST!)), 'utf8');
  for (const route of manifest.routes) {
    test(`product accessibility contract: ${route.path}`, async ({ page }) => {
      await exerciseProductRoute(page, route);
    });
  }
}
