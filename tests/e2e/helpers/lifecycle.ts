import { spawn, spawnSync, type ChildProcessWithoutNullStreams } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import readline from 'node:readline';

const IMAGE = 'fca-phase0-api-e2e-test:ocaml-5.2.0-dream-alpha7';
const MAX_DIAGNOSTIC = 32 * 1024;

type RuntimeEvent = { protocolVersion: 1; event: 'ready' | 'stopped' | 'error'; port?: number; code?: string };
type Identity = { runId: string; containerName: string; proxyName: string; networkName: string; hostPort: number; publishedPort: number; serverPort: number; evidencePath: string; projectRoot: string; buildExitCode: number | null };
type Running = { child: ChildProcessWithoutNullStreams; events: RuntimeEvent[]; waiters: Array<() => void>; stderr: () => string };

export type FixtureRuntime = { baseURL: string; hostPort: number; containerName: string; networkName: string; evidencePath: string; stop: () => Promise<void> };

function fullTestLabelArgs(): string[] {
  const runId = process.env.FCA_FULL_TEST_RUN_ID;
  if (!runId) return [];
  if (!/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(runId)) throw new Error('FULL_TEST_RUN_ID_INVALID');
  return ['--label', `fca.full-test.run=${runId}`];
}

function runDocker(args: string[], allowFailure = false) {
  const result = spawnSync('docker', args, { cwd: process.cwd(), encoding: 'utf8', windowsHide: true });
  if (!allowFailure && result.status !== 0) throw new Error(`DOCKER_COMMAND_FAILED:${args[0]}:${(result.stderr || '').slice(0, 512)}`);
  return result;
}

function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      if (!address || typeof address === 'string') return reject(new Error('LOOPBACK_PORT_ALLOCATION_FAILED'));
      server.close(error => error ? reject(error) : resolve(address.port));
    });
  });
}

function waitForEvent(events: RuntimeEvent[], waiters: Array<() => void>, name: RuntimeEvent['event'], timeoutMs: number): Promise<RuntimeEvent> {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + timeoutMs;
    const check = () => {
      const event = events.find(candidate => candidate.event === name);
      if (event) return resolve(event);
      const failure = events.find(candidate => candidate.event === 'error');
      if (failure) return reject(new Error(failure.code || 'FIXTURE_RUNTIME_ERROR'));
      if (Date.now() >= deadline) return reject(new Error(`FIXTURE_${name.toUpperCase()}_TIMEOUT`));
      const timer = setTimeout(check, Math.min(50, deadline - Date.now()));
      waiters.push(() => { clearTimeout(timer); check(); });
    };
    check();
  });
}

function waitForExit(child: ChildProcessWithoutNullStreams, timeoutMs: number): Promise<number | null> {
  if (child.exitCode !== null) return Promise.resolve(child.exitCode);
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('FIXTURE_CONTAINER_EXIT_TIMEOUT')), timeoutMs);
    child.once('exit', code => { clearTimeout(timer); resolve(code); });
  });
}

async function portIsClosed(port: number): Promise<boolean> {
  return new Promise(resolve => {
    const socket = net.connect({ host: '127.0.0.1', port });
    const done = (closed: boolean) => { socket.destroy(); resolve(closed); };
    socket.setTimeout(500);
    socket.once('connect', () => done(false));
    socket.once('timeout', () => done(true));
    socket.once('error', () => done(true));
  });
}

async function prepareIdentity(): Promise<Identity> {
  const projectRoot = process.cwd();
  const runId = (process.env.FCA_E2E_RUN_ID || `fca-e2e-${Date.now()}-${process.pid}`).replace(/[^a-zA-Z0-9_-]/g, '-').slice(0, 54);
  const artifactRoot = path.resolve(process.env.KLEVAR_MESH_WORKER_DIR || path.join(projectRoot, 'test-results', runId));
  fs.mkdirSync(artifactRoot, { recursive: true });
  const build = runDocker(['run', '--rm', '--name', `${runId}-build`, ...fullTestLabelArgs(), '-v', `${projectRoot}:/workspace`, '-w', '/workspace', '--entrypoint', 'opam', IMAGE, 'exec', '--', 'dune', 'build', 'tests/e2e/fixtures/http_fixture_server.exe', 'tests/e2e/fixtures/worker_fixture.exe', 'tests/e2e/fixtures/runtime_supervisor.exe']);
  const identity = { runId, containerName: `${runId}-runtime`, proxyName: `${runId}-loopback-proxy`, networkName: `${runId}-network`, hostPort: await freePort(), publishedPort: 18080, serverPort: 18081, evidencePath: path.join(artifactRoot, 'playwright-runtime-lifecycle.json'), projectRoot, buildExitCode: build.status };
  runDocker(['network', 'create', ...fullTestLabelArgs(), identity.networkName]);
  return identity;
}

function launchRuntime(identity: Identity): Running {
  const { projectRoot, containerName, networkName, hostPort, publishedPort, serverPort, runId } = identity;
  const args = ['run', '--rm', '-i', '--name', containerName, ...fullTestLabelArgs(), '--network', networkName, '--publish', `127.0.0.1:${hostPort}:${publishedPort}`, '-v', `${projectRoot}:/workspace`, '-w', '/workspace', '--entrypoint', 'opam', IMAGE, 'exec', '--', '_build/default/tests/e2e/fixtures/runtime_supervisor.exe', '--server', '/workspace/_build/default/tests/e2e/fixtures/http_fixture_server.exe', '--worker', '/workspace/_build/default/tests/e2e/fixtures/worker_fixture.exe', '--fixture', '/workspace/tests/fixtures/tenants.json', '--control', `/tmp/${runId}`, '--port', String(serverPort)];
  const child = spawn('docker', args, { cwd: projectRoot, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
  const events: RuntimeEvent[] = [];
  const waiters: Array<() => void> = [];
  let stderr = '';
  child.stderr.on('data', chunk => { if (stderr.length < MAX_DIAGNOSTIC) stderr += String(chunk).slice(0, MAX_DIAGNOSTIC - stderr.length); });
  readline.createInterface({ input: child.stdout }).on('line', line => {
    try {
      const event = JSON.parse(line) as RuntimeEvent;
      if (event.protocolVersion === 1 && ['ready', 'stopped', 'error'].includes(event.event)) events.push(event);
    } catch { /* bounded non-protocol child output is ignored */ }
    waiters.splice(0).forEach(wake => wake());
  });
  return { child, events, waiters, stderr: () => stderr };
}

async function exposeLoopback(identity: Identity, running: Running): Promise<void> {
  await waitForEvent(running.events, running.waiters, 'ready', 15_000);
  runDocker(['run', '--rm', '-d', '--name', identity.proxyName, ...fullTestLabelArgs(), '--network', `container:${identity.containerName}`, 'alpine:3.20', 'nc', '-lk', '-p', String(identity.publishedPort), '-e', 'nc', '127.0.0.1', String(identity.serverPort)]);
  const response = await fetch(`http://127.0.0.1:${identity.hostPort}/__test/ready`, { signal: AbortSignal.timeout(5_000) });
  if (!response.ok) throw new Error('FIXTURE_PUBLISHED_READY_FAILED');
  await response.body?.cancel();
}

async function verifyAndRecordCleanup(identity: Identity, running: Running): Promise<void> {
  const containerAbsent = runDocker(['inspect', identity.containerName], true).status !== 0;
  const proxyAbsent = runDocker(['inspect', identity.proxyName], true).status !== 0;
  const networkAbsent = runDocker(['network', 'inspect', identity.networkName], true).status !== 0;
  const portClosed = await portIsClosed(identity.hostPort);
  const evidence = { protocolVersion: 1, buildExitCode: identity.buildExitCode, events: running.events, containerName: identity.containerName, proxyName: identity.proxyName, networkName: identity.networkName, hostPort: identity.hostPort, dreamBind: `127.0.0.1:${identity.serverPort}`, publishedProxy: `127.0.0.1:${identity.hostPort}`, containerAbsent, proxyAbsent, networkAbsent, portClosed, stderr: running.stderr() ? '[redacted bounded diagnostics present]' : '' };
  fs.writeFileSync(identity.evidencePath, `${JSON.stringify(evidence, null, 2)}\n`, 'utf8');
  if (!containerAbsent || !proxyAbsent || !networkAbsent || !portClosed) throw new Error('FIXTURE_RUNTIME_CLEANUP_INCOMPLETE');
}

async function stopRuntime(identity: Identity, running: Running): Promise<void> {
  runDocker(['rm', '-f', identity.proxyName], true);
  running.child.stdin.write('{"protocolVersion":1,"command":"stop"}\n');
  try {
    await waitForEvent(running.events, running.waiters, 'stopped', 8_000);
    const exitCode = await waitForExit(running.child, 8_000);
    if (exitCode !== 0) throw new Error(`FIXTURE_CONTAINER_EXIT_${exitCode}`);
  } catch {
    runDocker(['stop', '--time', '2', identity.containerName], true);
    runDocker(['rm', '-f', identity.containerName], true);
  } finally {
    runDocker(['network', 'rm', identity.networkName], true);
  }
  await verifyAndRecordCleanup(identity, running);
}

export async function startFixtureRuntime(): Promise<FixtureRuntime> {
  const identity = await prepareIdentity();
  const running = launchRuntime(identity);
  try {
    await exposeLoopback(identity, running);
  } catch (error) {
    runDocker(['rm', '-f', identity.proxyName], true);
    runDocker(['rm', '-f', identity.containerName], true);
    runDocker(['network', 'rm', identity.networkName], true);
    throw new Error(`${String(error)}:${running.stderr().slice(0, 512)}`);
  }
  let stopped = false;
  return {
    baseURL: `http://127.0.0.1:${identity.hostPort}`,
    hostPort: identity.hostPort,
    containerName: identity.containerName,
    networkName: identity.networkName,
    evidencePath: identity.evidencePath,
    stop: async () => { if (!stopped) { stopped = true; await stopRuntime(identity, running); } },
  };
}
