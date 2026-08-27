import { defineConfig } from '@playwright/test';

const runId = process.env.FCA_E2E_RUN_ID ||= `fca-e2e-${Date.now()}-${process.pid}`;
const shared = {
  browserName: 'chromium' as const,
  deviceScaleFactor: 1,
  locale: 'en-GB',
  timezoneId: 'UTC',
  colorScheme: 'light' as const,
  reducedMotion: 'reduce' as const,
  trace: 'retain-on-failure' as const,
  video: 'retain-on-failure' as const,
  screenshot: 'only-on-failure' as const,
};

export default defineConfig({
  testDir: './tests/e2e',
  outputDir: `test-results/${runId}`,
  reporter: [['line'], ['html', { outputFolder: `playwright-report/${runId}`, open: 'never' }]],
  globalSetup: './tests/e2e/global-setup.ts',
  fullyParallel: true,
  forbidOnly: true,
  retries: 0,
  workers: 3,
  projects: [
    {
      name: 'desktop-1440',
      use: {
        ...shared,
        viewport: { width: 1440, height: 900 },
        screen: { width: 1440, height: 900 },
        isMobile: false,
        hasTouch: false,
      },
    },
    {
      name: 'tablet-768',
      use: {
        ...shared,
        viewport: { width: 768, height: 1024 },
        screen: { width: 768, height: 1024 },
        isMobile: false,
        hasTouch: true,
      },
    },
    {
      name: 'mobile-390',
      use: {
        ...shared,
        viewport: { width: 390, height: 844 },
        screen: { width: 390, height: 844 },
        isMobile: true,
        hasTouch: true,
      },
    },
  ],
});
