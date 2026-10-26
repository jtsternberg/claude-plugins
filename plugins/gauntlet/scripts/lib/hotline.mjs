import { spawn, spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const DIAL = 'skills/dial/scripts/dial.sh';
const WAIT = 'skills/dial/scripts/wait-for-response.sh';

function installedRoot(env) {
  const f = join(env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'plugins', 'installed_plugins.json');
  try { return JSON.parse(readFileSync(f, 'utf8')).plugins?.['hotline@jtsternberg']?.[0]?.installPath ?? null; }
  catch { return null; }
}

// A capability check, not a path check: an older hotline without the herdr
// transport can still sit in the plugin cache. Override first, dev checkout last
// so a stale checkout never shadows a released plugin.
export function locateHotline(env = process.env) {
  const cands = [
    env.GAUNTLET_HOTLINE_ROOT,
    installedRoot(env),
    env.CLAUDE_PLUGIN_ROOT && join(env.CLAUDE_PLUGIN_ROOT, '..', 'hotline'),
    join(homedir(), 'Code/claude-plugins/plugins/hotline'),
  ];
  for (const c of cands) {
    if (!c) continue;
    try { if (readFileSync(join(c, DIAL), 'utf8').includes('herdr')) return c; } catch { /* next */ }
  }
  return null;
}

// dial.sh prints one pretty-printed JSON object; anything else on stdout is chatter.
function parseLastJson(out) {
  try { return JSON.parse(out ?? ''); } catch { /* fall through */ }
  const lines = (out ?? '').trim().split('\n').reverse();
  for (const l of lines) { try { return JSON.parse(l); } catch { /* keep looking */ } }
  return null;
}

// opts: { root, target, cwd, label, promptFile, fresh, env }
export function dialOnce(opts) {
  const args = [join(opts.root, DIAL), '--target', opts.target, '--transport', 'herdr', '--detached',
    '--mode', 'work_order', '--label', opts.label, '--prompt-file', opts.promptFile];
  if (opts.fresh) args.push('--fresh');
  const r = spawnSync('bash', args, { cwd: opts.cwd, env: { ...process.env, ...opts.env }, encoding: 'utf8' });
  return { rc: r.status ?? 1, json: parseLastJson(r.stdout), stderr: r.stderr };
}

const TRUST_PATTERNS = /Quick safety check|trust the files in this|I trust this folder/;
const herdr = (args) => spawnSync('herdr', args, { encoding: 'utf8' });

// Claude Code's startup trust dialog, answered where it is. hotline refuses to answer
// it and fails the dial at deliver/boot/fire with nothing delivered, so answering and
// re-dialing cannot double-run the order. Logic copied from agentic-dev's
// .claude/skills/agentic-run/scripts/dial-phase.sh (answer_trust_dialog): the dialog
// lists "No, exit" first and pre-selected, so the keys are `down enter`, never Enter.
export function answerTrustDialog(callDir) {
  const f = callDir && join(callDir, 'herdr_agent.txt');
  if (!f || !existsSync(f)) return false;
  const agent = readFileSync(f, 'utf8').trim();
  if (!TRUST_PATTERNS.test(herdr(['agent', 'read', agent, '--source', 'visible']).stdout ?? '')) return false;
  const keys = (process.env.GAUNTLET_TRUST_KEYS || 'down enter').split(/\s+/);
  if (herdr(['agent', 'send-keys', agent, ...keys]).status !== 0) return false;
  herdr(['agent', 'wait', agent, '--until', 'idle', '--timeout', process.env.GAUNTLET_TRUST_WAIT_MS || '30000']);
  return !TRUST_PATTERNS.test(herdr(['agent', 'read', agent, '--source', 'visible']).stdout ?? '');
}

// The herdr agent and pane a call dir names, for a human to attach to or close.
export function calleeHandle(callDir) {
  const read = (f) => { try { return readFileSync(join(callDir, f), 'utf8').trim() || null; } catch { return null; } };
  return { agent: callDir ? read('herdr_agent.txt') : null, pane: callDir ? read('herdr_pane.txt') : null };
}

// Returns { ok, json, error }. On a trust-dialog failure: answer it, then re-dial once.
// The re-dial starts a NEW callee even without --fresh: dial.sh forgets the cache
// entry when a first contact fails at deliver. The answered agent never got the
// order, so it sits idle in its pane; nothing runs twice.
export function dial(opts) {
  let r = dialOnce(opts);
  // Never after `sent: true`: that callee may hold the order, and a re-dial runs it twice.
  if (r.rc !== 0 && r.json?.sent !== true && ['deliver', 'boot', 'fire'].includes(r.json?.stage) && answerTrustDialog(r.json?.call_dir)) {
    r = dialOnce({ ...opts, fresh: false });
  }
  if (r.rc !== 0 || r.json?.status !== 'connected' || !r.json?.call_dir) {
    let error = r.json ? `${r.json.stage ?? r.json.status}: ${r.json.detail ?? ''}`.trim() : (r.stderr || `dial.sh exited ${r.rc}`).trim();
    if (/blocked during startup/.test(error)) error += ' (a repo Claude Code has never trusted parks on its startup trust dialog: run `claude` once in the workspace and trust it, then --resume)';
    return { ok: false, json: r.json, error };
  }
  return { ok: true, json: r.json };
}

// Resolves { rc, response } once wait-for-response.sh exits.
// 0 done · 4 awaiting review · 3 preempted · 5 blocked · 1 failed
export function wait(root, callDir, timeoutS) {
  return new Promise((resolve) => {
    const p = spawn('bash', [join(root, WAIT), callDir, '--timeout', String(timeoutS)], { stdio: 'ignore' });
    p.on('close', (code) => {
      let response = null;
      try { response = JSON.parse(readFileSync(join(callDir, 'response.json'), 'utf8')).response ?? null; } catch { /* none */ }
      resolve({ rc: code ?? 1, response });
    });
  });
}

// A critic gets its role and nothing else: the run and piece would point it at the
// ledger, which says which side is ours.
export function hotlineEnv({ role, runId, piece, model }) {
  const env = {
    HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS: '1',
    HOTLINE_CALLEE_ENV: role === 'critic' ? 'GAUNTLET_ROLE=critic' : `GAUNTLET_ROLE=${role} GAUNTLET_RUN=${runId} GAUNTLET_PIECE=${piece}`,
    HOTLINE_HERDR_PLACEMENT: 'workspace',
    HOTLINE_HERDR_WORKSPACE: `gauntlet-${runId}`,
  };
  if (model) env.HOTLINE_CLAUDE_MODEL = model;
  return env;
}
