// Shared fixture for the gauntlet suites: a temp git workspace with a run spec, a
// fake herdr-capable hotline root, and PATH stubs for bd and herdr. Nothing here
// reaches a model, the network, herdr, or a browser.
import { spawnSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const PLUGIN = join(dirname(fileURLToPath(import.meta.url)), '..');
export const CLI = join(PLUGIN, 'scripts', 'gauntlet.mjs');
const FAKE = join(dirname(fileURLToPath(import.meta.url)), 'fixtures', 'fake-hotline.mjs');

// Every dir a suite makes comes from here and is removed when the suite's process exits.
const made = [];
process.on('exit', () => { for (const d of made) rmSync(d, { recursive: true, force: true }); });
export function scratch(prefix = 'gauntlet-test-') {
  const d = realpathSync(mkdtempSync(join(tmpdir(), prefix)));
  made.push(d);
  return d;
}

export function sh(cwd, cmd, env) {
  const r = spawnSync('sh', ['-c', cmd], { cwd, env, encoding: 'utf8' });
  if (r.status !== 0) throw new Error(`${cmd}: ${r.stderr}`);
  return r.stdout.trim();
}

export function makeFixture(opts = {}) {
  const T = scratch();
  const ws = join(T, 'site');
  const bin = join(T, 'bin');
  const hl = join(T, 'hotline');
  mkdirSync(bin, { recursive: true });
  mkdirSync(join(hl, 'skills/dial/scripts'), { recursive: true });
  mkdirSync(join(T, 'tmp'));
  // The fixture dial.sh must mention herdr to pass the locator's capability check.
  writeFileSync(join(hl, 'skills/dial/scripts/dial.sh'), `#!/usr/bin/env bash\n# fake hotline, herdr transport\nexec node "${FAKE}" dial "$@"\n`);
  writeFileSync(join(hl, 'skills/dial/scripts/wait-for-response.sh'), `#!/usr/bin/env bash\nexec node "${FAKE}" wait "$@"\n`);
  writeFileSync(join(bin, 'bd'), `#!/usr/bin/env bash\necho "$PWD $*" >> "${T}/bd.log"\ncase "$1" in create) echo '{"id":"site-g1"}';; esac\n`);
  writeFileSync(join(bin, 'herdr'), `#!/usr/bin/env bash
echo "$*" >> "${T}/herdr.log"
case "$1 $2" in
  "agent read") if [[ -f "${T}/trust-cleared" ]]; then echo "> ready"; else printf 'Do you trust the files in this folder?\\n1. No, exit\\n2. Yes, I trust this folder\\n'; fi ;;
  "agent send-keys") : > "${T}/trust-cleared" ;;
esac
`);
  for (const f of ['bd', 'herdr']) chmodSync(join(bin, f), 0o755);
  writeFileSync(join(T, 'gitconfig'), '[user]\n\tname = Test\n\temail = test@example.com\n[init]\n\tdefaultBranch = main\n');

  const env = {
    ...process.env,
    PATH: `${bin}:${process.env.PATH}`,
    TMPDIR: join(T, 'tmp'),
    HOME: T,
    CLAUDE_CONFIG_DIR: join(T, 'claude'),
    GIT_CONFIG_GLOBAL: join(T, 'gitconfig'),
    GIT_CONFIG_NOSYSTEM: '1',
    GAUNTLET_HOTLINE_ROOT: hl,
    FAKE_LOG: join(T, 'fake.jsonl'),
    FAKE_CALLS: join(T, 'calls'),
    FAKE_STATE: join(T, 'fake-state'),
    ...(opts.env ?? {}),
  };
  delete env.CLAUDE_PLUGIN_ROOT;

  mkdirSync(ws);
  sh(ws, 'git init -q && echo site > index.txt && git add . && git commit -q -m init', env);
  if (opts.beads) mkdirSync(join(ws, '.beads'));
  const runId = 'demo';
  const specDir = join(ws, '.gauntlet', runId);
  mkdirSync(join(specDir, 'refs'), { recursive: true });
  writeFileSync(join(specDir, 'refs', 'ref-a.txt'), 'REF the reference\n');
  const spec = {
    version: 1,
    run_id: runId,
    goal: 'A page that explains the service.',
    artifact: { workspace: ws },
    medium: 'text',
    capture: { command: 'cat piece-{piece}.txt > {out}', ext: 'txt' },
    bar: [{ id: 'ref-a', file: 'refs/ref-a.txt' }],
    criteria: [{ id: 'clarity', ask: 'Which is clearer?' }, { id: 'cta', ask: 'Which next step is more obvious?' }],
    ...(opts.spec ?? {}),
  };
  const specPath = join(specDir, 'gauntlet.json');
  writeFileSync(specPath, JSON.stringify(spec, null, 2));
  const worktree = `${ws}-gauntlet-${runId}`;
  return { T, ws, env, specPath, runId, worktree, runDir: join(worktree, '.gauntlet', runId) };
}

export function cli(fx, args, extraEnv = {}) {
  const r = spawnSync('node', [CLI, ...args], { env: { ...fx.env, ...extraEnv }, encoding: 'utf8' });
  let json = null;
  try { json = JSON.parse(r.stdout); } catch {
    try { json = JSON.parse(r.stdout.trim().split('\n').pop()); } catch { /* text */ }
  }
  return { rc: r.status, stdout: r.stdout, stderr: r.stderr, json };
}

export const fakeLog = (fx) => (existsSync(fx.env.FAKE_LOG) ? readFileSync(fx.env.FAKE_LOG, 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l)) : []);
export const ledger = (fx) => readFileSync(join(fx.runDir, 'ledger.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l));
export const events = (fx, name) => ledger(fx).filter((e) => e.event === name);

export function initAndSplit(fx, pieces = [{ id: 'hero' }]) {
  const i = cli(fx, ['init', fx.specPath]);
  if (i.rc !== 0) throw new Error(`init failed: ${i.stderr}${i.stdout}`);
  const s = cli(fx, ['split', '--run', fx.runDir, '--pieces', JSON.stringify(pieces)]);
  if (s.rc !== 0) throw new Error(`split failed: ${s.stderr}${s.stdout}`);
}
