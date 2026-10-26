// The ledger fold and the stop rules. Pure: no fs, no git, no clock of its own, so
// every rule is testable from a fixture ledger.

const CALL_TERMINAL = new Set(['built', 'build_error', 'verdict', 'verdict_malformed', 'judge_error', 'smoothed', 'smooth_error', 'nudged']);
// A builder pause for a callee that may still be live after a failure. --resume
// re-waits it once; a second failure is recorded as one, the human having been told
// to close its pane.
const FAIL_PAUSES = new Set(['wait_failed', 'preempted', 'delivery_unconfirmed']);
// That second failure ends the call but not the callee: it may still be working in the
// worktree, so the run stays paused until --resume finds its herdr agent gone.
export const STRANDED = 'repeated_wait_failure';
// Failed rechecks (capture or critic error) a closed piece survives before it plateaus.
export const RECHECK_ATTEMPTS = 2;

export const passesFor = (spec) => (spec.judge.mode === 'blind-pairwise' && spec.judge.double ? 2 : 1);

function newWave(e) {
  return { n: e.wave, builds: e.builds, rechecks: e.rechecks, attempted: new Set(), built: new Map(), changed: 0, judge: new Map(), smoothed: false };
}

function judgeSlot(w, piece, round, recheck) {
  if (!w.judge.has(piece)) w.judge.set(piece, { round, recheck: !!recheck, file: null, resolved: false, passes: new Map() });
  return w.judge.get(piece);
}

export function fold(events, spec) {
  const st = {
    init: null, stopped: null, split: false, pieces: new Map(), order: [],
    wave: 0, waves: new Map(), calls: new Map(), stranded: new Map(),
    totalRounds: 0, lastCommit: null, buildsSinceSmooth: 0, events: events.length,
  };
  const piece = (id) => st.pieces.get(id);
  for (const e of events) {
    const w = e.wave !== undefined ? st.waves.get(e.wave) : undefined;
    const call = e.call_dir ? st.calls.get(e.call_dir) : undefined;
    if (call && CALL_TERMINAL.has(e.event)) call.done = true;
    if (e.reason === STRANDED && call) st.stranded.set(e.call_dir, { ...call, close: e.close ?? call.close ?? null });
    switch (e.event) {
      case 'init': st.init = e; break;
      case 'split':
        st.split = true;
        for (const p of e.pieces) {
          st.pieces.set(p.id, { id: p.id, def: p, status: 'open', reason: null, rounds: 0, wins: 0, losses: 0, recheckFails: 0, lastGap: null, lastResult: null, lastCapture: null, pending: false });
          st.order.push(p.id);
        }
        break;
      case 'wave': st.wave = e.wave; st.waves.set(e.wave, newWave(e)); break;
      case 'dispatched': st.calls.set(e.call_dir, { ...e, done: false, paused: false }); break;
      case 'paused':
        if (call) {
          Object.assign(call, { paused: true, close: e.close ?? null, failPaused: call.failPaused || FAIL_PAUSES.has(e.reason) });
          if (e.reason === 'awaiting_review') call.reviewPaused = true;
        }
        break;
      case 'resumed':
        for (const c of st.calls.values()) c.paused = false;
        st.stopped = null;
        break;
      case 'built': {
        const p = piece(e.piece);
        p.rounds++; p.pending = true; st.totalRounds++; st.buildsSinceSmooth++;
        if (e.commit) st.lastCommit = e.commit;
        w?.attempted.add(e.piece);
        w?.built.set(e.piece, e.round);
        if (w) w.changed++;
        break;
      }
      case 'build_error': {
        const p = piece(e.piece);
        p.rounds++; st.totalRounds++;
        w?.attempted.add(e.piece);
        break;
      }
      case 'captured': {
        const p = piece(e.piece);
        p.lastCapture = e.file;
        if (w) judgeSlot(w, e.piece, e.round, e.recheck).file = e.file;
        break;
      }
      case 'capture_error': {
        const p = piece(e.piece);
        if (e.recheck) recheckFailed(st, p);
        else p.pending = false;
        if (w) judgeSlot(w, e.piece, e.round, e.recheck).resolved = true;
        break;
      }
      case 'verdict':
      case 'judge_error':
        if (w) judgeSlot(w, e.piece, e.round, e.recheck).passes.set(e.pass, e);
        break;
      case 'judged': {
        const p = piece(e.piece);
        if (w) judgeSlot(w, e.piece, e.round, e.recheck).resolved = true;
        if (e.recheck && e.result === 'error') recheckFailed(st, p);
        else applyResult(p, e, spec);
        break;
      }
      case 'smoothed':
        if (w) w.smoothed = true;
        st.buildsSinceSmooth = 0;
        if (e.commit) {
          st.lastCommit = e.commit;
          for (const p of st.pieces.values()) if (p.status === 'closed') p.status = 'recheck';
        }
        break;
      case 'smooth_error': if (w) w.smoothed = true; break;
      case 'released': st.stranded.delete(e.call_dir); break;
      case 'stopped': st.stopped = e; break;
    }
    capCheck(st, spec);
  }
  return st;
}

// A failed recheck spends round budget, so max_rounds_total still bounds a smoother
// that breaks the capture; after RECHECK_ATTEMPTS the piece stops being rechecked.
// p.rounds is left alone: it numbers builds, and the recheck re-judges the last one.
function recheckFailed(st, p) {
  st.totalRounds++;
  if (++p.recheckFails >= RECHECK_ATTEMPTS) Object.assign(p, { status: 'plateaued', reason: 'recheck_failed' });
}

function applyResult(p, e, spec) {
  if (e.result === 'error') { p.pending = false; return; }
  // The gap names what the loser must change: only after a loss is that our piece.
  p.lastGap = e.result === 'lost' ? e.biggest_gap ?? null : null;
  p.lastResult = e.result;
  if (e.recheck) {
    p.recheckFails = 0;
    // A loss after smoothing reopens the piece; a win or a tie keeps it closed.
    if (e.result === 'lost') Object.assign(p, { status: 'open', reason: 'reopened', wins: 0, losses: 1 });
    else p.status = 'closed';
    return;
  }
  p.pending = false;
  if (e.result === 'won') { p.wins++; p.losses = 0; }
  else if (e.result === 'lost') { p.losses++; p.wins = 0; }
  else { p.wins = 0; p.losses = 0; }
  if (p.wins >= spec.stop.wins_to_close) Object.assign(p, { status: 'closed', reason: 'wins_to_close' });
  else if (p.losses >= spec.stop.plateau_rounds) Object.assign(p, { status: 'plateaued', reason: 'plateau' });
}

function capCheck(st, spec) {
  for (const p of st.pieces.values()) {
    if (p.status === 'open' && !p.pending && p.rounds >= spec.budget.max_rounds_per_piece) {
      Object.assign(p, { status: 'plateaued', reason: 'cap' });
    }
  }
}

export function budgetReason(st, spec, now) {
  if (st.totalRounds >= spec.budget.max_rounds_total) return 'budget:max_rounds_total';
  if (st.init && (now - Date.parse(st.init.ts)) / 60000 >= spec.budget.max_minutes) return 'budget:max_minutes';
  return null;
}

// ctx: { now: ms, stopFile: bool, isAncestor: (sha) => bool }
export function decide(st, spec, ctx) {
  if (ctx.stopFile) return { action: 'stop', reason: 'human' };
  if (st.stopped) return { action: 'stop', reason: st.stopped.reason, recorded: true };
  if (!st.init) return { action: 'error', reason: 'ledger has no init event; run `gauntlet.mjs init` first' };

  const open = [...st.calls.values()].filter((c) => !c.done);
  const paused = open.filter((c) => c.paused);
  if (paused.length) return { action: 'paused', calls: paused.map(callSummary) };
  if (st.stranded.size) return { action: 'paused', reason: STRANDED, calls: [...st.stranded.values()].map(callSummary) };
  if (open.length) return { action: 'await', calls: open.map(callSummary) };

  if (!st.split) return { action: 'split' };

  const budget = budgetReason(st, spec, ctx.now);
  const w = st.waves.get(st.wave);
  if (w) {
    if (!budget) {
      for (const id of w.builds) {
        const p = st.pieces.get(id);
        if (p.status !== 'open' || w.attempted.has(id)) continue;
        if (st.lastCommit && !ctx.isAncestor(st.lastCommit)) return { action: 'stop', reason: 'history_rewritten' };
        return { action: 'build', wave: w.n, piece: id, round: p.rounds + 1, gap: p.lastGap, last: p.lastResult };
      }
    }
    const pending = [];
    // A build whose capture never landed (a crash between the two) is captured here.
    for (const [id, r] of w.built) if (!w.judge.has(id)) pending.push({ id, round: r, recheck: false });
    for (const id of w.rechecks) if (!w.judge.has(id)) pending.push({ id, round: st.pieces.get(id).rounds, recheck: true });
    for (const [id, slot] of w.judge) if (!slot.resolved) pending.push({ id, round: slot.round, recheck: slot.recheck });
    if (pending.length) return { action: 'judge', wave: w.n, pieces: pending, passes: passesFor(spec) };
    if (budget) return { action: 'stop', reason: budget };
    const allDone = [...st.pieces.values()].every((p) => p.status === 'closed' || p.status === 'plateaued');
    if (!w.smoothed && (allDone ? st.buildsSinceSmooth > 0 : w.changed >= spec.stop.smoothing_after_wave_changes)) {
      return { action: 'smooth', wave: w.n, final: allDone };
    }
  }
  const pieces = [...st.pieces.values()];
  const builds = pieces.filter((p) => p.status === 'open').map((p) => p.id);
  const rechecks = pieces.filter((p) => p.status === 'recheck').map((p) => p.id);
  if (builds.length === 0 && rechecks.length === 0) {
    return { action: 'stop', reason: pieces.some((p) => p.status === 'closed') ? 'all_closed' : 'plateau_all' };
  }
  if (budget) return { action: 'stop', reason: budget };
  return { action: 'wave', wave: st.wave + 1, builds, rechecks };
}

function callSummary(c) {
  return { role: c.role, piece: c.piece, round: c.round, pass: c.pass, call_dir: c.call_dir, agent_name: c.agent_name, ...(c.close ? { close: c.close } : {}) };
}
