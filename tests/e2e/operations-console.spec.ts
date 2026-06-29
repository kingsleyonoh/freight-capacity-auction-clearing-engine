import { expect, test } from '@playwright/test';

test.describe('HTMX operations console baseline', () => {
  test('renders freight operations console with privacy and audit affordances', async ({ page }) => {
    await page.goto('/');
    await expect(page.getByRole('heading', { name: /Freight Capacity Auction Clearing/i })).toBeVisible();
    await expect(page.getByText(/sealed-bid privacy/i)).toBeVisible();
    await expect(page.getByRole('heading', { name: /solver evidence/i })).toBeVisible();
    await expect(page.getByRole('link', { name: /Open API key login/i })).toHaveAttribute('href', '/login');
  });

  test('keeps the mobile-critical dashboard summary usable at narrow width', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto('/');
    await expect(page.locator('[data-testid="ops-status-panel"]')).toBeVisible();
    await expect(page.locator('[data-privacy-scope="sealed-bid"]')).toContainText(/redacted carrier view/i);
  });

  test('exposes semantic landmarks for keyboard and screen-reader checks', async ({ page }) => {
    await page.goto('/');
    await expect(page.getByRole('main')).toBeVisible();
    await expect(page.locator('table caption')).toContainText(/Auction readiness/i);
    await expect(page.locator('[aria-live="polite"]')).toContainText(/No live auction selected/i);
  });
});
