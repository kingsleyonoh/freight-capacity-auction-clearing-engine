import { spawn, spawnSync } from 'node:child_process';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const COMMANDS = Object.freeze({
  unit: Object.freeze(['dune', 'runtest', '--no-buffer']),
  integration: Object.freeze(['dune', 'exec', 'tests/integration/main.exe']),
  e2e: Object.freeze(['npx', 'playwright', 'test']),
  lint: Object.freeze(['dune', 'build', '@check']),
  format: Object.freeze(['dune', 'build', '@fmt', '--auto-promote']),
  build: Object.freeze(['dune', 'build', '@all']),
  'replay-benchmark': Object.freeze(['dune', 'exec', 'bin/replay_bench.exe', '--', '--fixture', 'tests/fixtures/replay/golden_12_month.parquet']),
  'solver-smoke': Object.freeze(['dune', 'exec', 'bin/solver_smoke.exe']),
});

const OCAML_ACTIONS = new Set(['unit', 'integration', 'lint', 'format', 'build', 'replay-benchmark', 'solver-smoke']);
const RUN_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;
const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

function spawnInherited(file, args, options) {
  return new Promise(resolve => {
    let executable = file;
    let literalArgs = args;
    if (process.platform === 'win32' && file === 'npx') {
      executable = process.execPath;
      literalArgs = [path.join(path.dirname(process.execPath), 'node_modules', 'npm', 'bin', 'npx-cli.js'), ...args];
    }
    const child = spawn(executable, literalArgs, { ...options, stdio: 'inherit', shell: false, windowsHide: true });
    child.once('error', error => {
      process.stderr.write(`COMMAND_SPAWN_FAILED:${error.code || 'UNKNOWN'}\n`);
      resolve(127);
    });
    child.once('exit', (code, signal) => resolve(signal ? 128 : (code ?? 127)));
  });
}

function captureLines(file, args) {
  const result = spawnSync(file, args, { cwd: projectRoot, encoding: 'utf8', shell: false, windowsHide: true });
  if (result.error || result.status !== 0) throw new Error('RESOURCE_INSPECTION_FAILED');
  return String(result.stdout || '').split(/\r?\n/).map(value => value.trim()).filter(Boolean);
}

export const defaultRuntime = Object.freeze({
  commandExists(command) {
    const locator = process.platform === 'win32' ? 'where' : 'which';
    return spawnSync(locator, [command], { cwd: projectRoot, stdio: 'ignore', shell: false, windowsHide: true }).status === 0;
  },
  runProcess: spawnInherited,
  async inspectOwnedResources(label) {
    return {
      containers: captureLines('docker', ['ps', '-a', '--filter', `label=${label}`, '--format', '{{.Names}}']),
      networks: captureLines('docker', ['network', 'ls', '--filter', `label=${label}`, '--format', '{{.Name}}']),
    };
  },
  async writeEvidence(directory, value) {
    await mkdir(directory, { recursive: true });
    await writeFile(path.join(directory, 'status.json'), `${JSON.stringify(value, null, 2)}\n`, 'utf8');
  },
  now: () => Date.now(),
  pid: process.pid,
});

function generatedRunId(runtime) {
  return `fca-full-${runtime.now()}-${runtime.pid}`;
}

function selectRunId(env, runtime) {
  const supplied = Object.prototype.hasOwnProperty.call(env, 'FCA_TEST_RUN_ID');
  const runId = supplied ? env.FCA_TEST_RUN_ID : generatedRunId(runtime);
  return typeof runId === 'string' && RUN_ID_PATTERN.test(runId) ? runId : null;
}

async function runLiteral(argv, runtime, env) {
  return runtime.runProcess(argv[0], argv.slice(1), { cwd: projectRoot, env, shell: false });
}

async function runOcaml(argv, runtime, env) {
  if (runtime.commandExists('dune')) return runLiteral(argv, runtime, env);
  return runtime.runProcess('bash', ['scripts/exact-ocaml-command.sh', ...argv], { cwd: projectRoot, env, shell: false });
}

async function runSingle(action, runtime, env) {
  const argv = COMMANDS[action];
  if (!argv) return 64;
  return OCAML_ACTIONS.has(action) ? runOcaml(argv, runtime, env) : runLiteral(argv, runtime, env);
}

function integrationInvocation(runtime) {
  const command = [...COMMANDS.integration];
  return runtime.commandExists('dune')
    ? ['bash', 'tests/integration/run_all.sh', '--', ...command]
    : ['bash', 'tests/integration/run_all.sh', '--', 'bash', 'scripts/exact-ocaml-command.sh', ...command];
}

async function writeStatus(runtime, env, runId, status) {
  if (!runtime.writeEvidence) return;
  const root = path.resolve(env.FCA_FULL_TEST_ARTIFACT_ROOT || path.join('.pi', 'full-test'));
  await runtime.writeEvidence(path.join(root, runId), { schemaVersion: 1, runId, ...status });
}

async function runFull(runtime, env) {
  const runId = selectRunId(env, runtime);
  if (!runId) return 64;
  const childEnv = { ...env, FCA_FULL_TEST_RUN_ID: runId, FCA_E2E_RUN_ID: `${runId}-e2e` };
  const label = `fca.full-test.run=${runId}`;
  const tiers = [
    { name: 'unit', run: () => runOcaml(COMMANDS.unit, runtime, childEnv) },
    { name: 'integration', run: () => runLiteral(integrationInvocation(runtime), runtime, childEnv) },
    { name: 'e2e', run: () => runLiteral(COMMANDS.e2e, runtime, childEnv) },
  ];
  let exitCode = 0;
  let failedTier = null;
  try {
    for (const tier of tiers) {
      exitCode = await tier.run();
      if (exitCode !== 0) {
        failedTier = tier.name;
        break;
      }
    }
  } finally {
    try {
      const leftovers = await runtime.inspectOwnedResources(label);
      if (leftovers.containers.length > 0 || leftovers.networks.length > 0) exitCode = 70;
      await writeStatus(runtime, env, runId, { exitCode, failedTier, cleanup: leftovers });
    } catch {
      exitCode = 70;
      await writeStatus(runtime, env, runId, { exitCode, failedTier, cleanup: { inspectionFailed: true } }).catch(() => {});
    }
  }
  return exitCode;
}

export async function runAction(action, { runtime = defaultRuntime, env = process.env } = {}) {
  if (typeof action !== 'string' || (!COMMANDS[action] && action !== 'full')) return 64;
  return action === 'full' ? runFull(runtime, env) : runSingle(action, runtime, env);
}

async function cli() {
  if (process.argv.length !== 3) return 64;
  return runAction(process.argv[2]);
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : '';
if (invokedPath === fileURLToPath(import.meta.url)) {
  const exitCode = await cli();
  if (exitCode === 64) process.stderr.write(`usage: node scripts/project-command.mjs <${[...Object.keys(COMMANDS), 'full'].join('|')}>\n`);
  process.exitCode = exitCode;
}
