import { expect, test } from './helpers/test';

const apiKey = process.env.FCA_PRODUCT_E2E_API_KEY || 'fca_demo_key_2026';
const baseURL = () => process.env.FCA_E2E_BASE_URL || 'http://localhost:18080';

test('standalone console login, data surfaces, and optional-state surfaces', async ({ page }) => {
  await page.goto(`${baseURL()}/login`, { waitUntil: 'domcontentloaded' });
  await page.locator('#api-key').fill(apiKey);
  await page.getByRole('button', { name: 'Continue' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);
  await expect(page.locator('h1')).toContainText('Decision readiness');
  await page.waitForLoadState('networkidle');

  await page.goto(`${baseURL()}/auctions`, { waitUntil: 'domcontentloaded' });
  await expect(page.locator('#auction-state')).toContainText(/auctions loaded|No auctions found|Offline/);
  await page.goto(`${baseURL()}/settings/integrations`, { waitUntil: 'domcontentloaded' });
  await expect(page.locator('#integration-table')).toContainText('notification_hub');
  await page.goto(`${baseURL()}/settings/notifications`, { waitUntil: 'domcontentloaded' });
  await expect(page.locator('#notification-stream')).toBeVisible();
});
