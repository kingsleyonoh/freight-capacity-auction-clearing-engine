import type { APIRequestContext, Page, TestInfo } from '@playwright/test';
import { test, expect } from './helpers/test';
import { loadTenantFixture, publicIdentityLiterals, type Tenant } from './helpers/tenant-fixture';

const fixture = loadTenantFixture();

function baseURL(): string {
  const value = process.env.FCA_E2E_BASE_URL;
  if (!value) throw new Error('FCA_E2E_BASE_URL_REQUIRED');
  return value;
}

async function probeTenant(page: Page, request: APIRequestContext, tenant: Tenant, other: Tenant) {
  await page.setExtraHTTPHeaders({ 'X-FCA-Test-Tenant': tenant.id });
  const response = await page.goto(`${baseURL()}/__test/tenants/${tenant.id}`, { waitUntil: 'domcontentloaded' });
  expect(response?.status()).toBe(200);
  const body = await response!.json();
  expect(body.schema_version).toBe(1);
  expect(body.tenant).toEqual({ id: tenant.id, name: tenant.name, display_name: tenant.display_name, overlap: tenant.overlap });
  const serialized = JSON.stringify(body);
  for (const literal of publicIdentityLiterals(other)) expect(serialized).not.toContain(literal);
  const worker = await request.post(`${baseURL()}/__test/tenants/${tenant.id}/validate`, {
    headers: { 'X-FCA-Test-Tenant': tenant.id, 'Content-Type': 'application/json' },
    data: {},
  });
  expect(worker.status()).toBe(200);
  expect((await worker.json()).worker).toMatchObject({ protocolVersion: 1, status: 'validated', validated_tenant_id: tenant.id, tenant_count: 2, overlap_validated: true });
  return body.tenant;
}

async function assertCrossTenantNonDisclosure(request: APIRequestContext, current: Tenant, other: Tenant) {
  const response = await request.get(`${baseURL()}/__test/tenants/${other.id}`, {
    headers: { 'X-FCA-Test-Tenant': current.id },
  });
  expect(response.status()).toBe(404);
  const body = await response.text();
  expect(JSON.parse(body)).toEqual({
    error: { code: 'TEST_RESOURCE_NOT_FOUND', message: 'The requested test resource was not found.', details: [] },
  });
  for (const literal of publicIdentityLiterals(other)) expect(body).not.toContain(literal);
}

async function attachPassState(page: Page, testInfo: TestInfo) {
  const screenshotPath = testInfo.outputPath(`pass-state-${testInfo.project.name}.png`);
  await page.screenshot({ path: screenshotPath, fullPage: true });
  await testInfo.attach(`pass-state-${testInfo.project.name}`, { path: screenshotPath, contentType: 'image/png' });
}

test('test-only two-tenant HTTP and worker infrastructure journey', async ({ page, request }, testInfo) => {
  const [first, second] = fixture.tenants;
  const firstObserved = await probeTenant(page, request, first, second);
  const secondObserved = await probeTenant(page, request, second, first);
  expect(firstObserved.id).not.toBe(secondObserved.id);
  expect(firstObserved.display_name).not.toBe(secondObserved.display_name);
  expect(firstObserved.overlap.carrier.public_name).toBe(secondObserved.overlap.carrier.public_name);
  expect(firstObserved.overlap.load.public_ref).toBe(secondObserved.overlap.load.public_ref);
  expect(firstObserved.overlap.auction.public_name).toBe(secondObserved.overlap.auction.public_name);
  await assertCrossTenantNonDisclosure(request, first, second);
  await attachPassState(page, testInfo);
});
