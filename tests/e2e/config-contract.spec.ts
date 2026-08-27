import { expect, test } from '@playwright/test';

const expected = {
  'desktop-1440': { width: 1440, height: 900, isMobile: false, hasTouch: false },
  'tablet-768': { width: 768, height: 1024, isMobile: false, hasTouch: true },
  'mobile-390': { width: 390, height: 844, isMobile: true, hasTouch: true },
} as const;

test('browserless Playwright project contract is exact and deterministic', async ({}, testInfo) => {
  const projects = testInfo.config.projects.map(project => project.name).sort();
  expect(projects).toEqual(Object.keys(expected).sort());

  const contract = expected[testInfo.project.name as keyof typeof expected];
  expect(contract).toBeDefined();
  expect(testInfo.project.use.browserName).toBe('chromium');
  expect(testInfo.project.use.viewport).toEqual({ width: contract.width, height: contract.height });
  expect(testInfo.project.use.screen).toEqual({ width: contract.width, height: contract.height });
  expect(testInfo.project.use.deviceScaleFactor).toBe(1);
  expect(testInfo.project.use.isMobile).toBe(contract.isMobile);
  expect(testInfo.project.use.hasTouch).toBe(contract.hasTouch);
  expect(testInfo.project.use.locale).toBe('en-GB');
  expect(testInfo.project.use.timezoneId).toBe('UTC');
  expect(testInfo.project.use.colorScheme).toBe('light');
  expect(testInfo.project.use.reducedMotion).toBe('reduce');
  expect(testInfo.project.use.trace).toBe('retain-on-failure');
  expect(testInfo.project.use.video).toBe('retain-on-failure');
  expect(testInfo.project.use.screenshot).toBe('only-on-failure');
  expect(testInfo.project.use.channel).toBeUndefined();
});
