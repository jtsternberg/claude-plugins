#!/usr/bin/env node
// gauntlet.mjs — the Gauntlet Loop engine. The lead session calls it; it never
// decides "done" by itself, the ledger fold does.
//
//   validate <spec.json>                       check a spec, print errors + notes
//   try-capture <spec.json> --piece <id> [--args <json>] [--out <file>]
//                                              run capture.command once in the workspace
//   init <spec.json>                           worktree + branch, copy the run dir, bead, first commit
//   split --run <dir> --pieces <json>          record the lead's split (round 0)
//   next --run <dir>                           print the next action, change nothing
//   loop --run <dir> [--once]                  run actions until the lead is needed
//   status --run <dir> [--json]                per-piece standing
//   stop --run <dir> | resume --run <dir>      write / clear the STOP file
//   progress --run <dir>                       re-render progress.html
//
// --run takes the run dir (<worktree>/.gauntlet/<run-id>), its gauntlet.json, or the
// setup copy at <workspace>/.gauntlet/<run-id>/ (exit 3 if that run is not initialized).
import { spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { Run } from './lib/engine.mjs';
import { beadCreate, commitRunDir, createWorktree, head } from './lib/git.mjs';
import { append } from './lib/ledger.mjs';
import { renderProgress } from './lib/progress.mjs';
import { budgetReason } from './lib/rules.mjs';
import { ID_RE, loadSpec } from './lib/spec.mjs';

const out = (v) => process.stdout.write((typeof v === 'string' ? v : JSON.stringify(v, null, 2)) + '\n');
const die = (msg, code = 1) => { process.stderr.write(`gauntlet: ${msg}\n`); process.exit(code); };

function parse(argv) {
  const pos = []; const flags = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) { pos.push(a); continue; }
    const k = a.slice(2);
    if (['once', 'json'].includes(k)) flags[k] = true;
    else { if (argv[i + 1] === undefined) die(`--${k} needs a value`, 2); flags[k] = argv[++i]; }
  }
  return { pos, flags };
}

function runDirOf(flags) {
  if (!flags.run) die('--run <run-dir> is required', 2);
  const p = resolve(flags.run);
  const dir = existsSync(p) && statSync(p).isFile() ? dirname(p) : p;
  if (!existsSync(join(dir, 'gauntlet.json'))) die(`${dir} has no gauntlet.json`, 2);
  if (existsSync(join(dir, 'ledger.jsonl'))) return dir;
  // The setup copy in the workspace stands for the run dir in the run's worktree.
  const { spec, errors } = loadSpec(join(dir, 'gauntlet.json'));
  if (errors.length) die(`${dir}/gauntlet.json is invalid: ${errors.join('; ')}`, 2);
  const runDir = join(spec.git.worktree, '.gauntlet', spec.run_id);
  if (!existsSync(join(runDir, 'ledger.jsonl'))) die(`run ${spec.run_id} is not initialized; run: gauntlet.mjs init ${join(dir, 'gauntlet.json')}`, 3);
  return runDir;
}

function specOrDie(path) {
  if (!path) die('a spec path is required', 2);
  const r = loadSpec(resolve(path));
  if (r.errors.length) { out({ ok: false, errors: r.errors, notes: r.notes }); process.exit(1); }
  return r;
}

const shq = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;

const cmds = {
  validate({ pos }) {
    const r = loadSpec(resolve(pos[0] ?? die('validate <spec.json>', 2)));
    out({ ok: r.errors.length === 0, errors: r.errors, notes: r.notes });
    process.exit(r.errors.length ? 1 : 0);
  },

  'try-capture'({ pos, flags }) {
    const { spec } = specOrDie(pos[0]);
    const piece = flags.piece ?? die('--piece <id> is required', 2);
    const file = flags.out ? resolve(flags.out) : join(mkdtempSync(join(tmpdir(), 'gauntlet-try-')), `capture.${spec.capture.ext}`);
    const tokens = { ...(flags.args ? JSON.parse(flags.args) : {}), piece, round: 0, out: file, run_dir: dirname(resolve(pos[0])), run_id: spec.run_id };
    const cmd = spec.capture.command.replace(/\{([a-z_][a-z0-9_]*)\}/gi, (m, k) => (k in tokens ? shq(tokens[k]) : m));
    const r = spawnSync('sh', ['-c', cmd], { cwd: spec.artifact.workspace, encoding: 'utf8', timeout: spec.capture.timeout_s * 1000 });
    const ok = r.status === 0 && existsSync(file) && statSync(file).size > 0;
    out({ ok, out: file, exit: r.status, bytes: ok ? statSync(file).size : 0, stderr: (r.stderr || '').trim().slice(-500) });
    process.exit(ok ? 0 : 1);
  },

  init({ pos }) {
    const specPath = resolve(pos[0] ?? die('init <spec.json>', 2));
    const { spec, notes } = specOrDie(specPath);
    const specDir = dirname(specPath);
    if (basename(specDir) !== spec.run_id || basename(dirname(specDir)) !== '.gauntlet') {
      die(`the spec must live at <workspace>/.gauntlet/${spec.run_id}/gauntlet.json (got ${specPath})`, 2);
    }
    const { workspace } = spec.artifact;
    const { worktree, branch } = spec.git;
    let base;
    try { base = createWorktree({ workspace, worktree, branch, base: spec.git.base }); } catch (e) { die(e.message); }
    const runDir = join(worktree, '.gauntlet', spec.run_id);
    const skip = new Set(['ledger.jsonl', 'STOP', 'captures', 'orders', 'progress.html']);
    cpSync(specDir, runDir, { recursive: true, filter: (src) => !skip.has(basename(src)) || src === specDir });
    if (!spec.git.commit_captures) writeFileSync(join(runDir, '.gitignore'), 'captures/\nrefs/\n');
    const missing = spec.bar.filter((b) => !existsSync(join(runDir, b.file))).map((b) => b.file);
    if (missing.length) die(`reference files missing from ${specDir}: ${missing.join(', ')}`);
    const bead = beadCreate(workspace, `Gauntlet run ${spec.run_id}`,
      `Gauntlet Loop run. Branch ${branch}, worktree ${worktree}, run dir ${runDir}. Round state lives in ledger.jsonl there; this task closes when the run stops.`);
    const e = append(runDir, { event: 'init', run_id: spec.run_id, workspace, worktree, branch, base, run_dir: runDir, bead });
    const run = new Run(runDir);
    renderProgress(runDir, run.spec, run.st);
    commitRunDir(worktree, runDir, `gauntlet: init ${spec.run_id}`, `Gauntlet: init run=${spec.run_id}`);
    out({ ok: true, run_dir: runDir, worktree, branch, base, bead, notes, ts: e.ts });
  },

  split({ flags }) {
    const run = new Run(runDirOf(flags));
    if (run.st.split) die('this run is already split; pieces are fixed for the run');
    let pieces;
    try { pieces = JSON.parse(flags.pieces ?? die('--pieces <json array> is required', 2)); } catch (e) { die(`--pieces: ${e.message}`, 2); }
    if (!Array.isArray(pieces) || pieces.length === 0) die('--pieces: a non-empty array of {id, note?, ref?, capture?}', 2);
    const bars = new Set(run.spec.bar.map((b) => b.id));
    const seen = new Set();
    for (const [i, p] of pieces.entries()) {
      if (!p || typeof p.id !== 'string' || !ID_RE.test(p.id)) die(`pieces[${i}].id: required, lowercase letters, digits, "_" or "-"`, 2);
      if (seen.has(p.id)) die(`pieces[${i}].id: duplicate "${p.id}"`, 2);
      seen.add(p.id);
      if (p.ref !== undefined && !bars.has(p.ref)) die(`pieces[${i}].ref: "${p.ref}" is not a bar id (${[...bars].join(', ')})`, 2);
      if (p.capture !== undefined && (typeof p.capture !== 'object' || Array.isArray(p.capture))) die(`pieces[${i}].capture: an object of capture tokens`, 2);
    }
    run.record({ event: 'split', pieces: pieces.map((p) => ({ id: p.id, note: p.note ?? null, ref: p.ref ?? run.spec.bar[0].id, capture: p.capture ?? {} })) });
    out({ ok: true, pieces: pieces.map((p) => p.id), next: run.next() });
  },

  next({ flags }) { out(new Run(runDirOf(flags)).next()); },

  async loop({ flags }) {
    const run = new Run(runDirOf(flags));
    let a;
    try { a = await run.loop({ once: !!flags.once }); } catch (e) { die(e.message); }
    // Status for the reader, then one JSON line last for whoever parses it.
    out(statusText(run));
    out(JSON.stringify({ last: a, next: run.next() }));
  },

  status({ flags }) {
    const run = new Run(runDirOf(flags));
    if (flags.json) {
      out({ next: run.next(), wave: run.st.wave, rounds: run.st.totalRounds, stopped: run.st.stopped, pieces: run.st.order.map((id) => { const { def, ...p } = run.st.pieces.get(id); return p; }) });
    } else out(statusText(run));
  },

  stop({ flags }) {
    const dir = runDirOf(flags);
    writeFileSync(join(dir, 'STOP'), `${new Date().toISOString()}\n`);
    out({ ok: true, stop_file: join(dir, 'STOP'), note: 'callees already in flight keep running; --resume re-waits on them' });
  },

  resume({ flags }) {
    const dir = runDirOf(flags);
    rmSync(join(dir, 'STOP'), { force: true });
    const run = new Run(dir);
    run.record({ event: 'resumed' });
    out({ ok: true, next: run.next() });
  },

  progress({ flags }) {
    const run = new Run(runDirOf(flags));
    renderProgress(run.runDir, run.spec, run.st, { next: run.next().action });
    out({ ok: true, progress: join(run.runDir, 'progress.html') });
  },
};

function statusText(run) {
  const { st, spec } = run;
  const next = run.next();
  const mins = st.init ? Math.round((Date.now() - Date.parse(st.init.ts)) / 60000) : 0;
  const lines = [
    `run ${spec.run_id} · branch ${st.init?.branch} · head ${st.init ? head(st.init.worktree) : '?'} · worktree ${st.init?.worktree}`,
    `wave ${st.wave} · rounds ${st.totalRounds}/${spec.budget.max_rounds_total} · ${mins}/${spec.budget.max_minutes} min · judge ${spec.judge.mode}${spec.judge.double ? ' (double)' : ''}${budgetReason(st, spec, Date.now()) ? ' · BUDGET SPENT' : ''}`,
    `next: ${next.action}${next.reason ? ` (${next.reason})` : ''}${next.piece ? ` ${next.piece} r${next.round}` : ''}`,
    '',
    'piece            status     rounds  wins  losses  last   gap',
  ];
  for (const id of st.order) {
    const p = st.pieces.get(id);
    lines.push(`${id.padEnd(16)} ${p.status.padEnd(10)} ${String(p.rounds).padEnd(7)} ${String(p.wins).padEnd(5)} ${String(p.losses).padEnd(7)} ${(p.lastResult ?? '-').padEnd(6)} ${(p.lastGap ?? '').slice(0, 80)}`);
  }
  if (next.calls) for (const c of next.calls) lines.push(`  ${next.action}: ${c.role} ${c.piece} r${c.round} agent=${c.agent_name ?? '?'} (herdr agent attach ${c.agent_name ?? '<agent>'}${c.close ? `; to clear it: ${c.close}` : ''})`);
  lines.push(`progress: ${join(run.runDir, 'progress.html')}`);
  return lines.join('\n');
}

const [cmd, ...rest] = process.argv.slice(2);
if (!cmd || !cmds[cmd]) {
  process.stdout.write(readFileSync(new URL(import.meta.url), 'utf8').split('\n').slice(1).filter((l) => l.startsWith('//')).map((l) => l.slice(3)).join('\n') + '\n');
  process.exit(cmd ? 2 : 0);
}
await cmds[cmd](parse(rest));
