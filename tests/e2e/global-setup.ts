import type { FullConfig } from '@playwright/test';
import { startFixtureRuntime } from './helpers/lifecycle';

export default async function globalSetup(_config: FullConfig) {
  if (process.env.FCA_E2E_SKIP_RUNTIME === '1') return;
  const runtime = await startFixtureRuntime();
  process.env.FCA_E2E_BASE_URL = runtime.baseURL;
  process.env.FCA_E2E_LIFECYCLE_EVIDENCE = runtime.evidencePath;
  return async () => {
    await runtime.stop();
  };
}
