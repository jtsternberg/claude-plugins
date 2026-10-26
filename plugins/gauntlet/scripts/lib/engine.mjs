import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { blind, discard, unblind } from './blind.mjs';
import { beadClose, commitRunDir, commitWithTrailer, isAncestor } from './git.mjs';
import { dial, hotlineEnv, locateHotline, wait } from './hotline.mjs';
import { append, readLedger } from './ledger.mjs';
import { renderProgress } from './progress.mjs';
import { decide, fold, passesFor } from './rules.mjs';
import { loadSpec } from './spec.mjs';
import { parseVerdict, tally } from './verdict.mjs';

export const REFS = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'references');
const ref = (name) => readFileSync(join(REFS, name), 'utf8');
const fill = (tpl, vars) => tpl.replace(/\{\{([A-Z_]+)\}\}/g, (m, k) => (k in vars ? String(vars[k]) : m));
const shq = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;
const criteriaList = (spec) => spec.criteria.map((c) => `- **${c.id}**: ${c.ask}`).join('\n');

export class Run {
  constructor(runDir) {
    this.runDir = runDir;
    const { spec, errors } = loadSpec(join(runDir, 'gauntlet.json'));
    if (errors.length) throw new Error(`gauntlet.json is invalid:\n  ${errors.join('\n  ')}`);
    this.spec = spec;
    this.refresh();
    this.worktree = this.st.init?.worktree;
  }

  refresh() { this.st = fold(readLedger(this.runDir), this.spec); return this.st; }

  record(event) {
    const e = append(this.runDir, event);
    this.refresh();
    renderProgress(this.runDir, this.spec, this.st);
    return e;
  }

  next() {
    return decide(this.st, this.spec, {
      now: Date.now(),
      stopFile: existsSync(join(this.runDir, 'STOP')),
      isAncestor: (sha) => isAncestor(this.worktree, sha),
    });
  }

  hotline() {
    this.root ??= locateHotline();
    if (!this.root) throw new Error('no herdr-capable hotline plugin found; install hotline or set GAUNTLET_HOTLINE_ROOT');
    return this.root;
  }

  // Runs actions until one needs the lead (split, paused, stop, error). --once stops
  // after the first action either way.
  async loop({ once = false } = {}) {
    for (;;) {
      const a = this.next();
      if (['split', 'paused', 'error'].includes(a.action)) return a;
      if (a.action === 'stop') { this.finalize(a); return a; }
      await this.execute(a);
      if (once) return a;
    }
  }

  async execute(a) {
    switch (a.action) {
      case 'wave': this.record({ event: 'wave', wave: a.wave, builds: a.builds, rechecks: a.rechecks }); break;
      case 'build': await this.build(a); break;
      case 'judge': await this.judge(a); break;
      case 'smooth': await this.smooth(a); break;
      case 'await': await this.settle(a.calls.map((c) => this.st.calls.get(c.call_dir))); break;
      default: throw new Error(`unknown action ${a.action}`);
    }
  }

  finalize(a) {
    if (a.reason === 'human' || a.recorded) return;
    this.record({ event: 'stopped', reason: a.reason });
    commitRunDir(this.worktree, this.runDir, `gauntlet: stop ${this.spec.run_id} (${a.reason})`, `Gauntlet: stop run=${this.spec.run_id} reason=${a.reason}`);
    beadClose(this.st.init.workspace, this.st.init.bead, `gauntlet stopped: ${a.reason}`);
  }

  piece(id) { return this.st.pieces.get(id); }
  refFile(id) { const r = this.piece(id).def.ref; return join(this.runDir, (this.spec.bar.find((b) => b.id === r) ?? this.spec.bar[0]).file); }

  writeOrder(name, text) {
    const dir = join(this.runDir, 'orders');
    mkdirSync(dir, { recursive: true });
    const p = join(dir, name);
    writeFileSync(p, text);
    return p;
  }

  dispatch({ role, piece, label, target, promptFile, fresh = true, model }) {
    return dial({
      root: this.hotline(), target, cwd: target, label, promptFile, fresh,
      env: hotlineEnv({ role, runId: this.spec.run_id, piece, model }),
    });
  }

  dispatched(r, fields) {
    return this.record({
      event: 'dispatched', ...fields, call_dir: r.json.call_dir,
      agent_name: r.json.surface_ref ?? null, callee_session_id: r.json.remote_session_id ?? null,
    });
  }

  // ---- build -------------------------------------------------------------
  async build(a) {
    const { piece, round, wave } = a;
    const p = this.piece(piece);
    const trailer = `Gauntlet: ${piece} r${round} run=${this.spec.run_id}`;
    const order = fill(ref('builder-order.md'), {
      STANCE: ref('stance-builder.md').trim(), RUN_ID: this.spec.run_id, GOAL: this.spec.goal, PIECE: piece,
      PIECE_NOTE: p.def.note || '(no note; the piece id says what it is)', ROUND: round,
      CAPTURE_COMMAND: this.spec.capture.command, CAPTURE_ARGS: JSON.stringify(p.def.capture ?? {}),
      CRITERIA: criteriaList(this.spec), REF_FILE: this.refFile(piece),
      LAST_CAPTURE: p.lastCapture ? `\`${join(this.runDir, p.lastCapture)}\`` : 'none yet (first round)',
      GAP: a.gap || 'First round: no verdict yet. Build the strongest version of this piece you can.',
      TRAILER: trailer,
    });
    const promptFile = this.writeOrder(`build-${piece}-r${round}.md`, order);
    const label = `build ${piece} r${round}`;
    const r = this.dispatch({ role: 'builder', piece, label, target: this.worktree, promptFile, model: this.spec.builder.model });
    if (!r.ok) { this.record({ event: 'build_error', piece, round, wave, reason: `dial failed: ${r.error}` }); return; }
    const call = this.dispatched(r, { role: 'builder', piece, round, wave, label, trailer });
    await this.settle([call]);
  }

  completeBuilder(call, { rc }) {
    const { piece, round, wave, call_dir } = call;
    if (rc === 4 || rc === 5) return this.pause(call, rc);
    if (rc !== 0) return this.record({ event: 'build_error', piece, round, wave, call_dir, wait_rc: rc, reason: rc === 3 ? 'preempted' : 'wait failed' });
    const commit = commitWithTrailer(this.worktree, call.trailer);
    if (!commit) return this.record({ event: 'build_error', piece, round, wave, call_dir, wait_rc: rc, reason: `no commit carries "${call.trailer}"` });
    this.record({ event: 'built', piece, round, wave, call_dir, wait_rc: rc, commit });
    // Captured before the next builder starts, so the capture is this build alone.
    this.capture(piece, round, wave, false);
  }

  pause(call, rc) {
    return this.record({ event: 'paused', call_dir: call.call_dir, role: call.role, piece: call.piece, wait_rc: rc, agent_name: call.agent_name, reason: rc === 4 ? 'awaiting_review' : 'blocked' });
  }

  // ---- capture -----------------------------------------------------------
  capture(piece, round, wave, recheck) {
    const { capture, run_id } = this.spec;
    const rel = `captures/${piece}/r${round}${recheck ? `-s${wave}` : ''}.${capture.ext}`;
    const out = join(this.runDir, rel);
    mkdirSync(dirname(out), { recursive: true });
    const tokens = { ...(this.piece(piece).def.capture ?? {}), piece, round, out, run_dir: this.runDir, run_id };
    const cmd = capture.command.replace(/\{([a-z_][a-z0-9_]*)\}/gi, (m, k) => (k in tokens ? shq(tokens[k]) : m));
    const r = spawnSync('sh', ['-c', cmd], { cwd: this.worktree, encoding: 'utf8', timeout: capture.timeout_s * 1000 });
    const base = { piece, round, wave, ...(recheck ? { recheck: true } : {}) };
    if (r.status !== 0 || !existsSync(out) || statSync(out).size === 0) {
      const why = r.error?.code === 'ETIMEDOUT' ? `timed out after ${capture.timeout_s}s` : r.status !== 0 ? `exit ${r.status}: ${(r.stderr || '').trim().slice(-300)}` : `nothing written to ${rel}`;
      return this.record({ event: 'capture_error', ...base, reason: why });
    }
    const sha256 = createHash('sha256').update(readFileSync(out)).digest('hex');
    return this.record({ event: 'captured', ...base, file: rel, sha256 });
  }

  // ---- judge -------------------------------------------------------------
  async judge(a) {
    const w = this.st.waves.get(a.wave);
    const launched = [];
    for (const { id, round, recheck } of a.pieces) {
      if (!w.judge.get(id)?.file) {
        this.capture(id, round, a.wave, recheck);
        if (!this.st.waves.get(a.wave).judge.get(id)?.file) continue;
      }
      const slot = this.st.waves.get(a.wave).judge.get(id);
      for (let pass = 1; pass <= a.passes; pass++) {
        if (slot.passes.has(pass)) continue;
        const call = this.launchCritic({ piece: id, round, wave: a.wave, pass, recheck, file: slot.file });
        if (call) launched.push(call);
      }
    }
    await this.settle(launched);
    for (const { id, round, recheck } of a.pieces) this.tallyPiece(a.wave, id, round, recheck, a.passes);
  }

  launchCritic({ piece, round, wave, pass, recheck, file }) {
    const { spec } = this;
    const mode = spec.judge.mode;
    const b = blind({
      ours: join(this.runDir, file), ref: this.refFile(piece), ext: spec.capture.ext, medium: spec.medium,
      mode, seed: `${spec.run_id}:${piece}:${round}:${wave}`, pass,
    });
    const schema = mode === 'rubric'
      ? { scores: Object.fromEntries(spec.criteria.map((c) => [c.id, '1-10'])), biggest_gap: 'one sentence', confidence: '1-5' }
      : { winner: 'A|B|tie', criteria: Object.fromEntries(spec.criteria.map((c) => [c.id, 'A|B|tie'])), biggest_gap: 'one sentence', confidence: '1-5' };
    const tpl = spec.judge.prompt
      ? readFileSync(isAbsolute(spec.judge.prompt) ? spec.judge.prompt : join(this.runDir, spec.judge.prompt), 'utf8')
      : ref(mode === 'rubric' ? 'judge-rubric.md' : 'judge-pairwise.md');
    const prompt = fill(tpl, {
      STANCE: ref('stance-critic.md').trim(), GOAL: spec.goal, CRITERIA: criteriaList(spec),
      FILE_A: b.files.A, FILE_B: b.files.B, REFERENCE: b.files.reference, CANDIDATE: b.files.candidate,
      SCHEMA: JSON.stringify(schema, null, 2),
    });
    const promptFile = join(b.base, 'prompt.md');
    writeFileSync(promptFile, prompt);
    const label = `judge ${piece} r${round}${recheck ? ` s${wave}` : ''}${pass > 1 ? ` p${pass}` : ''}`;
    const r = this.dispatch({ role: 'critic', piece, label, target: b.dir, promptFile, model: spec.judge.model });
    const fields = { piece, round, wave, pass, ...(recheck ? { recheck: true } : {}) };
    if (!r.ok) { discard(b.base); this.record({ event: 'judge_error', ...fields, reason: `dial failed: ${r.error}` }); return null; }
    return this.dispatched(r, { role: 'critic', ...fields, label, blind_base: b.base, blind_dir: b.dir, mode });
  }

  completeCritic(call, { rc, response }) {
    const fields = { piece: call.piece, round: call.round, wave: call.wave, pass: call.pass, call_dir: call.call_dir, ...(call.recheck ? { recheck: true } : {}) };
    if (rc === 4 || rc === 5) { this.pause(call, rc); return null; }
    if (rc !== 0) { discard(call.blind_base); this.record({ event: 'judge_error', ...fields, wait_rc: rc, reason: rc === 3 ? 'preempted' : 'wait failed' }); return null; }
    const parsed = parseVerdict(response, this.spec);
    if (parsed.ok) {
      const v = unblind(call.blind_base, parsed.verdict);
      discard(call.blind_base);
      this.record({ event: 'verdict', ...fields, mode: call.mode, ...v });
      return null;
    }
    if (call.retry || !existsSync(call.blind_base)) {
      discard(call.blind_base);
      this.record({ event: 'judge_error', ...fields, reason: `malformed verdict after retry: ${parsed.reason}` });
      return null;
    }
    this.record({ event: 'verdict_malformed', ...fields, reason: parsed.reason });
    // A follow-up to the SAME critic (no --fresh): it already read the files.
    const promptFile = join(call.blind_base, 'retry.md');
    writeFileSync(promptFile, `Your reply had no usable verdict (${parsed.reason}). Reply with the \`\`\`json verdict block alone, in the shape the first message gave, then your STATUS line.\n`);
    const label = `${call.label} retry`;
    const r = this.dispatch({ role: 'critic', piece: call.piece, label, target: call.blind_dir, promptFile, fresh: false, model: this.spec.judge.model });
    if (!r.ok) { discard(call.blind_base); this.record({ event: 'judge_error', ...fields, reason: `retry dial failed: ${r.error}` }); return null; }
    const { piece, round, wave, pass, recheck, blind_base, blind_dir, mode } = call;
    return this.dispatched(r, { role: 'critic', piece, round, wave, pass, ...(recheck ? { recheck: true } : {}), label, blind_base, blind_dir, mode, retry: true });
  }

  tallyPiece(wave, piece, round, recheck, passes) {
    const slot = this.st.waves.get(wave).judge.get(piece);
    if (!slot || slot.resolved || slot.passes.size < passes) return;
    const t = tally([...slot.passes.keys()].sort().map((k) => slot.passes.get(k)), this.spec);
    this.record({ event: 'judged', piece, round, wave, mode: this.spec.judge.mode, ...(recheck ? { recheck: true } : {}), ...t });
    const what = `${piece} r${round}${recheck ? ` recheck w${wave}` : ''}`;
    commitRunDir(this.worktree, this.runDir, `gauntlet: ${what} ${t.result}`, `Gauntlet: ${what} verdict=${t.result} run=${this.spec.run_id}`);
  }

  // ---- smooth ------------------------------------------------------------
  async smooth(a) {
    const trailer = `Gauntlet: smooth w${a.wave} run=${this.spec.run_id}`;
    const pieces = this.st.order.map((id) => {
      const p = this.piece(id);
      return `- **${id}** (${p.status}${p.lastCapture ? `, last capture \`${join(this.runDir, p.lastCapture)}\`` : ''})`;
    }).join('\n');
    const order = fill(ref('smooth-order.md'), {
      STANCE: ref('stance-builder.md').trim(), RUN_ID: this.spec.run_id, WAVE: a.wave, GOAL: this.spec.goal,
      PIECES: pieces, CRITERIA: criteriaList(this.spec), TRAILER: trailer,
    });
    const promptFile = this.writeOrder(`smooth-w${a.wave}.md`, order);
    const label = `smooth w${a.wave}`;
    const r = this.dispatch({ role: 'builder', piece: `smooth-w${a.wave}`, label, target: this.worktree, promptFile, model: this.spec.builder.model });
    if (!r.ok) { this.record({ event: 'smooth_error', wave: a.wave, reason: `dial failed: ${r.error}` }); return; }
    const call = this.dispatched(r, { role: 'smoother', piece: '*', round: a.wave, wave: a.wave, label, trailer, final: a.final });
    await this.settle([call]);
  }

  completeSmoother(call, { rc }) {
    if (rc === 4 || rc === 5) return this.pause(call, rc);
    if (rc !== 0) return this.record({ event: 'smooth_error', wave: call.wave, call_dir: call.call_dir, wait_rc: rc, reason: rc === 3 ? 'preempted' : 'wait failed' });
    // No commit is a legitimate answer: nothing needed smoothing, so nothing is re-judged.
    return this.record({ event: 'smoothed', wave: call.wave, call_dir: call.call_dir, wait_rc: rc, final: !!call.final, commit: commitWithTrailer(this.worktree, call.trailer) });
  }

  // ---- waiting -----------------------------------------------------------
  // Waits on every call in parallel and records each outcome; a critic retry
  // returns a new call, which is waited on in turn.
  async settle(calls) {
    let pending = calls.filter(Boolean);
    while (pending.length) {
      const results = await Promise.all(pending.map((c) => wait(this.hotline(), c.call_dir, this.spec.budget.call_timeout_s)));
      const more = [];
      pending.forEach((c, i) => {
        if (c.role === 'builder') this.completeBuilder(c, results[i]);
        else if (c.role === 'smoother') this.completeSmoother(c, results[i]);
        else { const n = this.completeCritic(c, results[i]); if (n) more.push(n); }
      });
      pending = more;
    }
  }
}
