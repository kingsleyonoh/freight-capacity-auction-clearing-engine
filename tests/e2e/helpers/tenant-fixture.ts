import fs from 'node:fs';
import path from 'node:path';

export type TenantFixture = {
  schema_version: 1;
  tenants: Tenant[];
};

export type Tenant = {
  id: string;
  name: string;
  legal_name: string;
  full_legal_name: string;
  display_name: string;
  address: Record<'line1' | 'city' | 'region' | 'postal_code' | 'country', string>;
  registration: Record<'jurisdiction' | 'broker_registration' | 'tax_id', string>;
  contact: Record<'email' | 'phone' | 'support_url' | 'operations_contact', string>;
  wordmark: string;
  brand_color: string;
  timezone: string;
  default_currency: string;
  operator_license: string;
  overlap: {
    carrier: { id: string; public_name: string };
    load: { id: string; public_ref: string; public_label: string };
    auction: { id: string; public_name: string };
  };
};

const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const FORBIDDEN_KEYS = ['api_key', 'jwt', 'cookie', 'signature', 'hash', 'password', 'credential', 'secret', 'authorization', 'connection_uri', 'bid_amount'];
const TENANT_KEYS = ['address', 'brand_color', 'contact', 'default_currency', 'display_name', 'full_legal_name', 'id', 'legal_name', 'name', 'operator_license', 'overlap', 'registration', 'timezone', 'wordmark'];

function assert(condition: unknown, code: string): asserts condition {
  if (!condition) throw new Error(code);
}

function exactKeys(value: unknown, expected: string[], code = 'FIXTURE_SCHEMA_INVALID'): asserts value is Record<string, unknown> {
  assert(typeof value === 'object' && value !== null && !Array.isArray(value), code);
  assert(JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...expected].sort()), code);
}

function rejectSecretKeys(value: unknown): void {
  if (Array.isArray(value)) return value.forEach(rejectSecretKeys);
  if (typeof value !== 'object' || value === null) return;
  for (const [key, nested] of Object.entries(value)) {
    const normalized = key.toLowerCase();
    assert(!FORBIDDEN_KEYS.some(fragment => normalized.includes(fragment)), 'FIXTURE_SECRET_KEY_FORBIDDEN');
    rejectSecretKeys(nested);
  }
}

function stringField(record: Record<string, unknown>, name: string): string {
  const value = record[name];
  assert(typeof value === 'string' && value.trim().length > 0, 'FIXTURE_SCHEMA_INVALID');
  return value;
}

function validateTenant(value: unknown): asserts value is Tenant {
  exactKeys(value, TENANT_KEYS);
  assert(UUID_V4.test(stringField(value, 'id')), 'FIXTURE_UUID_INVALID');
  for (const key of ['name', 'legal_name', 'full_legal_name', 'display_name', 'wordmark', 'brand_color', 'timezone', 'default_currency', 'operator_license']) stringField(value, key);
  exactKeys(value.address, ['line1', 'city', 'region', 'postal_code', 'country']);
  for (const key of Object.keys(value.address)) stringField(value.address, key);
  exactKeys(value.registration, ['jurisdiction', 'broker_registration', 'tax_id']);
  for (const key of Object.keys(value.registration)) stringField(value.registration, key);
  exactKeys(value.contact, ['email', 'phone', 'support_url', 'operations_contact']);
  for (const key of Object.keys(value.contact)) stringField(value.contact, key);
  exactKeys(value.overlap, ['auction', 'carrier', 'load']);
  exactKeys(value.overlap.carrier, ['id', 'public_name']);
  exactKeys(value.overlap.load, ['id', 'public_label', 'public_ref']);
  exactKeys(value.overlap.auction, ['id', 'public_name']);
  for (const entity of [value.overlap.carrier, value.overlap.load, value.overlap.auction]) assert(UUID_V4.test(stringField(entity, 'id')), 'FIXTURE_UUID_INVALID');
}

export function loadTenantFixture(fixturePath = path.join(process.cwd(), 'tests', 'fixtures', 'tenants.json')): TenantFixture {
  const parsed: unknown = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));
  rejectSecretKeys(parsed);
  exactKeys(parsed, ['schema_version', 'tenants']);
  assert(parsed.schema_version === 1, 'FIXTURE_SCHEMA_VERSION_UNSUPPORTED');
  assert(Array.isArray(parsed.tenants) && parsed.tenants.length === 2, 'FIXTURE_EXACTLY_TWO_REQUIRED');
  parsed.tenants.forEach(validateTenant);
  const [first, second] = parsed.tenants;
  assert(new Set(parsed.tenants.map(tenant => tenant.id)).size === 2, 'FIXTURE_TENANT_ID_DUPLICATE');
  const identityGroups = [
    parsed.tenants.map(tenant => tenant.name), parsed.tenants.map(tenant => tenant.legal_name),
    parsed.tenants.map(tenant => tenant.full_legal_name), parsed.tenants.map(tenant => tenant.display_name),
    parsed.tenants.map(tenant => tenant.registration.broker_registration), parsed.tenants.map(tenant => tenant.registration.tax_id),
    parsed.tenants.map(tenant => tenant.contact.email), parsed.tenants.map(tenant => tenant.contact.operations_contact),
    parsed.tenants.map(tenant => tenant.operator_license),
  ];
  assert(identityGroups.every(values => new Set(values).size === 2), 'FIXTURE_IDENTITY_NOT_DISTINCT');
  assert(first.overlap.carrier.public_name === second.overlap.carrier.public_name, 'FIXTURE_OVERLAP_REQUIRED');
  assert(first.overlap.load.public_ref === second.overlap.load.public_ref, 'FIXTURE_OVERLAP_REQUIRED');
  assert(first.overlap.load.public_label === second.overlap.load.public_label, 'FIXTURE_OVERLAP_REQUIRED');
  assert(first.overlap.auction.public_name === second.overlap.auction.public_name, 'FIXTURE_OVERLAP_REQUIRED');
  const entityIds = parsed.tenants.flatMap(tenant => [tenant.overlap.carrier.id, tenant.overlap.load.id, tenant.overlap.auction.id]);
  assert(new Set(entityIds).size === entityIds.length, 'FIXTURE_ENTITY_ID_DUPLICATE');
  return parsed as TenantFixture;
}

export function publicIdentityLiterals(tenant: Tenant): string[] {
  return [tenant.name, tenant.legal_name, tenant.full_legal_name, tenant.display_name, tenant.address.line1, tenant.address.city, tenant.address.region, tenant.registration.jurisdiction, tenant.registration.broker_registration, tenant.registration.tax_id, tenant.contact.email, tenant.contact.phone, tenant.contact.support_url, tenant.contact.operations_contact, tenant.wordmark, tenant.operator_license];
}
