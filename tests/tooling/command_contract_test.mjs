import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

const root = path.resolve(import.meta.dirname, '..', '..');
const dispatcherPath = path.join(root, 'scripts', 'project-command.mjs');
const expectedCommands = {
  unit: ['dune', 'runtest', '--no-buffer'],
  integration: ['dune', 'exec', 'tests/integration/main.exe'],
  e2e: ['npx', 'playwright', 'test'],
  lint: ['dune', 'build', '@check'],
  format: ['dune', 'build', '@fmt', '--auto-promote'],
  build: ['dune', 'build', '@all'],
  'replay-benchmark': ['dune', 'exec', 'bin/replay_bench.exe', '--', '--fixture', 'tests/fixtures/replay/golden_12_month.parquet'],
  'solver-smoke': ['dune', 'exec', 'bin/solver_smoke.exe'],
};

async function dispatcher() {
  return import(`${pathToFileURL(dispatcherPath).href}?contract=${Date.now()}`);
}

function runtime({ failAt = -1, cleanupFailure = false } = {}) {
  const calls = [];
  return {
    calls,
    commandExists: () => true,
    runProcess: async (file, args, options) => {
      calls.push({ kind: 'process', file, args: [...args], options: { ...options } });
      const processIndex = calls.filter(call => call.kind === 'process').length - 1;
      return processIndex === failAt ? 23 : 0;
    },
    inspectOwnedResources: async label => {
      calls.push({ kind: 'cleanup', label });
      return cleanupFailure ? { containers: ['leftover'], networks: [] } : { containers: [], networks: [] };
    },
    now: () => 1_721_143_740_000,
    pid: 4242,
  };
}

test('public inventory preserves every binding PRD tier and exact argv', async () => {
  const mod = await dispatcher();
  assert.deepEqual(mod.COMMANDS, expectedCommands);
  const pkg = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8'));
  assert.deepEqual(pkg.scripts['test:unit'], 'node ./scripts/project-command.mjs unit');
  assert.deepEqual(pkg.scripts['test:integration'], 'node ./scripts/project-command.mjs integration');
  assert.deepEqual(pkg.scripts['test:e2e'], 'node ./scripts/project-command.mjs e2e');
  assert.deepEqual(pkg.scripts['test:full'], 'node ./scripts/project-command.mjs full');
  assert.deepEqual(pkg.scripts.lint, 'node ./scripts/project-command.mjs lint');
  assert.deepEqual(pkg.scripts.format, 'node ./scripts/project-command.mjs format');
  assert.deepEqual(pkg.scripts.build, 'node ./scripts/project-command.mjs build');
  assert.deepEqual(pkg.scripts['replay:benchmark'], 'node ./scripts/project-command.mjs replay-benchmark');
  assert.deepEqual(pkg.scripts['solver:smoke'], 'node ./scripts/project-command.mjs solver-smoke');
});

test('every command is launched shell-free with literal argv', async () => {
  const mod = await dispatcher();
  for (const [action, argv] of Object.entries(expectedCommands)) {
    const fake = runtime();
    assert.equal(await mod.runAction(action, { runtime: fake, env: {} }), 0, action);
    const processCalls = fake.calls.filter(call => call.kind === 'process');
    assert.equal(processCalls.length, 1, action);
    assert.deepEqual([processCalls[0].file, ...processCalls[0].args], argv, action);
    assert.equal(processCalls[0].options.shell, false, action);
  }
});

test('full gate owns one valid run id, preserves tier order, and verifies success cleanup', async () => {
  const mod = await dispatcher();
  const fake = runtime();
  const exitCode = await mod.runAction('full', { runtime: fake, env: { FCA_TEST_RUN_ID: 'contract-success-001' } });
  assert.equal(exitCode, 0);
  const processes = fake.calls.filter(call => call.kind === 'process');
  assert.deepEqual(processes.map(call => [call.file, ...call.args]), [
    expectedCommands.unit,
    ['bash', 'tests/integration/run_all.sh', '--', ...expectedCommands.integration],
    expectedCommands.e2e,
  ]);
  for (const call of processes) {
    assert.equal(call.options.shell, false);
    assert.equal(call.options.env.FCA_FULL_TEST_RUN_ID, 'contract-success-001');
  }
  assert.deepEqual(fake.calls.at(-1), { kind: 'cleanup', label: 'fca.full-test.run=contract-success-001' });
});

test('full gate fails fast, propagates the exact tier status, and still verifies cleanup', async () => {
  const mod = await dispatcher();
  const fake = runtime({ failAt: 1 });
  const exitCode = await mod.runAction('full', { runtime: fake, env: { FCA_TEST_RUN_ID: 'contract-failure-001' } });
  assert.equal(exitCode, 23);
  assert.equal(fake.calls.filter(call => call.kind === 'process').length, 2);
  assert.deepEqual(fake.calls.at(-1), { kind: 'cleanup', label: 'fca.full-test.run=contract-failure-001' });
});

test('cleanup failure is fail-closed after either successful or failed tiers', async () => {
  const mod = await dispatcher();
  assert.equal(await mod.runAction('full', { runtime: runtime({ cleanupFailure: true }), env: { FCA_TEST_RUN_ID: 'cleanup-success-001' } }), 70);
  assert.equal(await mod.runAction('full', { runtime: runtime({ failAt: 0, cleanupFailure: true }), env: { FCA_TEST_RUN_ID: 'cleanup-failure-001' } }), 70);
});

test('run ids and action arguments fail closed without reaching a process', async () => {
  const mod = await dispatcher();
  for (const runId of ['', '../escape', 'space owned', 'x'.repeat(65)]) {
    const fake = runtime();
    assert.equal(await mod.runAction('full', { runtime: fake, env: { FCA_TEST_RUN_ID: runId } }), 64);
    assert.equal(fake.calls.length, 0);
  }
  const fake = runtime();
  assert.equal(await mod.runAction('unit;touch-untrusted', { runtime: fake, env: {} }), 64);
  assert.equal(fake.calls.length, 0);
});

test('POSIX and PowerShell wrappers share the dispatcher and reject appended command text', async t => {
  const shellSource = await readFile(path.join(root, 'scripts', 'project-command.sh'), 'utf8');
  const powerShellSource = await readFile(path.join(root, 'scripts', 'project-command.ps1'), 'utf8');
  assert.match(shellSource, /exec node \"\$SCRIPT_DIR\/project-command\.mjs\" \"\$@\"/);
  assert.match(powerShellSource, /& node \$dispatcher \$Action @Arguments/);
  assert.doesNotMatch(shellSource, /\beval\b/);
  assert.doesNotMatch(powerShellSource, /Invoke-Expression/);
  const shell = spawnSync('bash', [path.join(root, 'scripts', 'project-command.sh'), 'unit', 'semi;colon'], { cwd: root, env: process.env, encoding: 'utf8' });
  assert.equal(shell.status, 64, shell.stderr);
  const powerShellBinary = process.platform === 'win32' ? 'powershell' : 'pwsh';
  const ps = spawnSync(powerShellBinary, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'scripts', 'project-command.ps1'), '-Action', 'unit', '-Arguments', 'semi;colon'], { cwd: root, env: process.env, encoding: 'utf8' });
  if (ps.error?.code === 'ENOENT') return t.skip(`${powerShellBinary} unavailable`);
  assert.equal(ps.status, 64, ps.stderr);
});
