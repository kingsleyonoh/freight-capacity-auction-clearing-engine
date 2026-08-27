import { test as base, expect } from '@playwright/test';
import fs from 'node:fs';

const MAX_RECORDS = 200;
const MAX_MESSAGE = 2048;

type Diagnostic = { kind: string; message?: string; url?: string; status?: number };

function redact(value: string): string {
  return value
    .slice(0, MAX_MESSAGE)
    .replace(/(authorization|cookie|api[_-]?key|password|secret|token)\s*[:=]\s*[^\s,;]+/gi, '$1=[REDACTED]')
    .replace(/Bearer\s+[^\s]+/gi, 'Bearer [REDACTED]');
}

function safeURL(value: string): string {
  try {
    const url = new URL(value);
    url.search = '';
    url.hash = '';
    return url.toString();
  } catch {
    return '[invalid-url]';
  }
}

export const test = base.extend<{ _fixtureDiagnostics: void }>({
  _fixtureDiagnostics: [async ({ page }, use, testInfo) => {
    const records: Diagnostic[] = [];
    const push = (record: Diagnostic) => { if (records.length < MAX_RECORDS) records.push(record); };
    page.on('console', message => push({ kind: `console:${message.type()}`, message: redact(message.text()) }));
    page.on('pageerror', error => push({ kind: 'pageerror', message: redact(error.message) }));
    page.on('requestfailed', request => push({ kind: 'requestfailed', url: safeURL(request.url()), message: redact(request.failure()?.errorText || '') }));
    page.on('response', response => { if (response.status() >= 400) push({ kind: 'http-error', url: safeURL(response.url()), status: response.status() }); });
    await use();
    const diagnosticsPath = testInfo.outputPath('redacted-browser-diagnostics.json');
    fs.writeFileSync(diagnosticsPath, `${JSON.stringify({ records, cappedAt: MAX_RECORDS }, null, 2)}\n`, 'utf8');
    await testInfo.attach('redacted-browser-diagnostics', {
      path: diagnosticsPath,
      contentType: 'application/json',
    });
    const failures = records.filter(record => record.kind === 'pageerror' || record.kind === 'requestfailed' || record.kind === 'http-error' || record.kind === 'console:error');
    expect(failures, 'console/network diagnostics must be clean').toEqual([]);
  }, { auto: true }],
});

export { expect };
