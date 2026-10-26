// Fake hotline dial.sh / wait-for-response.sh for the gauntlet suites. Behavior is
// set per test through env:
//   FAKE_CRITIC    ours | ref | tie | malformed | malformed-once | rubric-high | rubric-low
//   FAKE_BUILDER   commit (default) | nocommit
//   FAKE_SMOOTHER  nocommit (default) | commit
//   FAKE_WAIT_RC_BUILDER / FAKE_WAIT_RC_CRITIC   the waiter's exit code (default 0)
//   FAKE_TRUST=1   the first dial fails at deliver with a trust dialog on screen
//   FAKE_DIAL_FAIL=builder|critic   that role's dial errors outright
import { spawnSync } from 'node:child_process';
import { appendFileSync, existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const [mode, ...argv] = process.argv.slice(2);
const env = process.env;
const log = (o) => appendFileSync(env.FAKE_LOG, JSON.stringify(o) + '\n');
const flag = (name) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : undefined; };
const calleeEnv = Object.fromEntries((env.HOTLINE_CALLEE_ENV ?? '').split(' ').filter(Boolean).map((kv) => kv.split('=')));
const role = calleeEnv.GAUNTLET_ROLE;

if (mode === 'dial') {
  mkdirSync(env.FAKE_CALLS, { recursive: true });
  const n = readdirSync(env.FAKE_CALLS).length + 1;
  const cd = join(env.FAKE_CALLS, `call-${n}`);
  mkdirSync(cd);
  const target = flag('--target');
  const promptFile = flag('--prompt-file');
  const prompt = readFileSync(promptFile, 'utf8');
  const fresh = argv.includes('--fresh');
  const pick = (k) => env[k];
  log({ kind: 'dial', n, argv, cwd: process.cwd(), role, piece: calleeEnv.GAUNTLET_PIECE, prompt,
    env: Object.fromEntries(['HOTLINE_CALLEE_ENV', 'HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS', 'HOTLINE_CLAUDE_MODEL', 'HOTLINE_HERDR_PLACEMENT', 'HOTLINE_HERDR_WORKSPACE'].map((k) => [k, pick(k) ?? null])) });
  writeFileSync(join(cd, 'meta.json'), JSON.stringify({ role, target, fresh, prompt }));
  writeFileSync(join(cd, 'herdr_agent.txt'), `agent-${n}\n`);
  // Pretty-printed, as the real dial.sh prints it (captured live from hotline 0.39.1).
  const out = (o, rc) => { process.stdout.write(JSON.stringify(o, null, 2) + '\n'); process.exit(rc); };
  if (env.FAKE_TRUST && !existsSync(`${env.FAKE_STATE}-trusted`)) {
    writeFileSync(`${env.FAKE_STATE}-trusted`, '');
    out({ status: 'error', stage: 'deliver', detail: "Claude Code's startup TRUST DIALOG is on screen", call_dir: cd }, 1);
  }
  if (env.FAKE_DIAL_FAIL === role) out({ status: 'error', stage: 'boot', detail: '{\n  "error": "agent_not_ready: agent x is blocked during startup and is not ready for prompts"\n}', call_dir: cd }, 1);
  const trailer = prompt.match(/^ {4}(Gauntlet: .+)$/m)?.[1];
  const commits = role === 'builder' && (calleeEnv.GAUNTLET_PIECE.startsWith('smooth-') ? env.FAKE_SMOOTHER === 'commit' : env.FAKE_BUILDER !== 'nocommit');
  if (commits && trailer) {
    const piece = calleeEnv.GAUNTLET_PIECE;
    writeFileSync(join(target, `piece-${piece}.txt`), `OURS ${trailer}\n`);
    spawnSync('git', ['add', '-A', '--', `piece-${piece}.txt`], { cwd: target });
    spawnSync('git', ['commit', '-q', '-m', `build ${piece}`, '--trailer', trailer], { cwd: target });
  }
  out({ status: 'connected', transport: 'herdr', call_dir: cd, surface_ref: `agent-${n}`, remote_session_id: `sess-${n}`, call_id: `nonce-${n}` }, 0);
}

if (mode === 'wait') {
  const cd = argv[0];
  const meta = JSON.parse(readFileSync(join(cd, 'meta.json'), 'utf8'));
  log({ kind: 'wait', call_dir: cd, argv, role: meta.role });
  let response = 'done\nSTATUS: WORK_COMPLETE call_id=x';
  if (meta.role === 'critic') response = critic(meta);
  writeFileSync(join(cd, 'response.json'), JSON.stringify({ session_id: 's', response }));
  process.exit(Number(meta.role === 'critic' ? env.FAKE_WAIT_RC_CRITIC ?? 0 : env.FAKE_WAIT_RC_BUILDER ?? 0));
}

function critic(meta) {
  const files = readdirSync(meta.target);
  // A follow-up carries only the retry ask; the first prompt sits beside the blind dir.
  const ids = [...readFileSync(join(meta.target, '..', 'prompt.md'), 'utf8').matchAll(/^- \*\*([a-z0-9_-]+)\*\*/gm)].map((m) => m[1]);
  const kind = env.FAKE_CRITIC ?? 'ours';
  const schemaEcho = '```json\n{"winner":"A|B|tie"}\n```\n';
  if (kind === 'malformed' || (kind === 'malformed-once' && meta.fresh)) return 'I think A is better.\nSTATUS: WORK_COMPLETE call_id=x';
  if (kind.startsWith('rubric')) {
    const n = kind === 'rubric-high' ? 8 : 5;
    return `${schemaEcho}\`\`\`json\n${JSON.stringify({ scores: Object.fromEntries(ids.map((i) => [i, n])), biggest_gap: 'rubric gap', confidence: 3 })}\n\`\`\`\nSTATUS: WORK_COMPLETE call_id=x`;
  }
  const oursFile = files.find((f) => readFileSync(join(meta.target, f), 'utf8').startsWith('OURS'));
  const ours = oursFile?.[0];
  const theirs = ours === 'A' ? 'B' : 'A';
  const winner = kind === 'ours' || kind === 'malformed-once' ? ours : kind === 'ref' ? theirs : 'tie';
  const v = { winner, criteria: Object.fromEntries(ids.map((i) => [i, winner])), biggest_gap: `gap seen by critic ${kind}`, confidence: 4 };
  return `Reasoning.\n${schemaEcho}\`\`\`json\n${JSON.stringify(v)}\n\`\`\`\nSTATUS: WORK_COMPLETE call_id=x`;
}
