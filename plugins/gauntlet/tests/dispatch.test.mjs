import assert from 'node:assert/strict';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { cli, events, fakeLog, initAndSplit, makeFixture } from './helpers.mjs';

const dials = (fx, role) => fakeLog(fx).filter((l) => l.kind === 'dial' && (!role || l.role === role));
const argOf = (argv, f) => argv[argv.indexOf(f) + 1];

test('builder and critic dials: herdr, detached, fresh, work_order, labelled, skip-permissions on both', () => {
  const fx = makeFixture({ spec: { judge: { model: 'claude-opus-5-5' }, builder: { model: 'claude-sonnet-5-5' } } });
  initAndSplit(fx);
  const r = cli(fx, ['loop', '--run', fx.runDir]);
  assert.equal(r.rc, 0, r.stderr);
  const [b] = dials(fx, 'builder');
  const [c] = dials(fx, 'critic');
  for (const d of [b, c]) {
    for (const f of ['--transport', '--detached', '--fresh', '--mode']) assert.ok(d.argv.includes(f), `${d.role} missing ${f}`);
    assert.equal(argOf(d.argv, '--transport'), 'herdr');
    assert.equal(argOf(d.argv, '--mode'), 'work_order');
    assert.equal(d.env.HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS, '1');
    assert.equal(d.env.HOTLINE_HERDR_PLACEMENT, 'workspace');
    assert.equal(d.env.HOTLINE_HERDR_WORKSPACE, 'gauntlet-demo');
  }
  assert.equal(argOf(b.argv, '--label'), 'build hero r1');
  assert.equal(argOf(b.argv, '--target'), fx.worktree);
  assert.equal(b.env.HOTLINE_CALLEE_ENV, 'GAUNTLET_ROLE=builder GAUNTLET_RUN=demo GAUNTLET_PIECE=hero');
  assert.equal(b.env.HOTLINE_CLAUDE_MODEL, 'claude-sonnet-5-5');
  assert.equal(argOf(c.argv, '--label'), 'judge hero r1');
  assert.equal(c.env.HOTLINE_CALLEE_ENV, 'GAUNTLET_ROLE=critic', 'no run or piece in the critic env');
  assert.equal(c.env.HOTLINE_CLAUDE_MODEL, 'claude-opus-5-5');
});

test('the critic is dialed from its blind dir and its prompt carries no project, ledger or gap text', () => {
  const fx = makeFixture({ env: { FAKE_CRITIC: 'ref' }, spec: { stop: { plateau_rounds: 2 } } });
  initAndSplit(fx);
  cli(fx, ['loop', '--run', fx.runDir]);
  const critics = dials(fx, 'critic');
  assert.ok(critics.length >= 2, 'two rounds were judged');
  for (const c of critics) {
    assert.equal(c.cwd, argOf(c.argv, '--target'), 'cwd = target = the blind dir');
    assert.ok(!c.cwd.startsWith(fx.ws) && !c.cwd.startsWith(fx.worktree));
    assert.deepEqual(c.beside, ['blind', 'prompt.md'], 'no key beside the blind dir');
    assert.ok(!c.prompt.includes(fx.ws), 'no project path');
    assert.ok(!c.prompt.includes('gap seen by critic'), 'no gap history');
    assert.ok(!c.prompt.includes('"event"'), 'no ledger text');
    assert.match(c.prompt, /A\.txt/);
    assert.match(c.prompt, /A page that explains the service/);
    assert.match(c.prompt, /\*\*clarity\*\*/);
  }
  // The builder of round 2 is handed round 1's lost gap, with the A/B key.
  assert.match(dials(fx, 'builder')[1].prompt, /\[A = (ours|reference), B = (reference|ours)\] gap seen by critic ref/);
  assert.equal(events(fx, 'judged').at(-1).result, 'lost');
  assert.ok(!existsSync(critics[0].cwd), 'the blind dir is discarded after the verdict');
});

test('after a win the next builder is told there is no gap, not handed the reference\'s flaw', () => {
  const fx = makeFixture({ spec: { budget: { max_rounds_total: 2 } } });
  initAndSplit(fx);
  cli(fx, ['loop', '--run', fx.runDir]);
  const b = dials(fx, 'builder').filter((d) => d.piece === 'hero');
  assert.equal(b.length, 2);
  assert.ok(!b[1].prompt.includes('gap seen by critic'));
  assert.match(b[1].prompt, /your piece won, so there is no gap to close/);
});

for (const [rc, reason] of [[4, 'awaiting_review'], [5, 'blocked'], [3, 'preempted'], [1, 'wait_failed']]) {
  test(`builder wait exit ${rc} → paused (${reason})`, () => {
    const fx = makeFixture({ env: { FAKE_WAIT_RC_BUILDER: String(rc) } });
    initAndSplit(fx);
    const r = cli(fx, ['loop', '--run', fx.runDir, '--once']);
    assert.equal(r.rc, 0, r.stderr);
    cli(fx, ['loop', '--run', fx.runDir, '--once']);
    const [p] = events(fx, 'paused');
    assert.equal(p?.wait_rc, rc, r.stdout);
    assert.equal(p.reason, reason);
    assert.equal(p.agent_name, 'agent-1');
    assert.equal(p.close, 'herdr pane close w1:p1');
    assert.equal(cli(fx, ['next', '--run', fx.runDir]).json.action, 'paused');
    assert.match(cli(fx, ['status', '--run', fx.runDir]).stdout, /to clear it: herdr pane close w1:p1/);
  });
}

for (const rc of [1, 3]) {
  test(`a builder that failed (wait exit ${rc}) blocks the next build until a resume re-waits it once`, () => {
    const fx = makeFixture({ env: { FAKE_WAIT_RC_BUILDER: String(rc) }, spec: { budget: { max_rounds_total: 1 } } });
    initAndSplit(fx);
    cli(fx, ['loop', '--run', fx.runDir]);
    assert.equal(cli(fx, ['loop', '--run', fx.runDir]).json.last.action, 'paused', 'no second builder while the first may be live');
    assert.equal(dials(fx, 'builder').length, 1);
    cli(fx, ['resume', '--run', fx.runDir]);
    cli(fx, ['loop', '--run', fx.runDir]);
    assert.equal(events(fx, 'build_error')[0].wait_rc, rc, 'the second failure is recorded as one');
    assert.equal(dials(fx, 'builder').length, 1);
  });
}

test('a builder dial whose deliver failed with sent:true is recorded live and paused, never re-dialed', () => {
  const fx = makeFixture({ env: { FAKE_DIAL_SENT: 'builder' }, spec: { budget: { max_rounds_total: 1 } } });
  initAndSplit(fx);
  const r = cli(fx, ['loop', '--run', fx.runDir]);
  assert.equal(r.json.last.action, 'paused');
  const [d] = events(fx, 'dispatched');
  assert.equal(d.delivery_unconfirmed, true);
  assert.equal(d.agent_name, 'agent-1');
  assert.ok(d.call_dir);
  assert.equal(events(fx, 'paused')[0].reason, 'delivery_unconfirmed');
  assert.equal(events(fx, 'build_error').length, 0);
  // Resume re-waits that call dir; the order did land, so the build counts.
  cli(fx, ['resume', '--run', fx.runDir]);
  cli(fx, ['loop', '--run', fx.runDir], { FAKE_DIAL_SENT: '' });
  assert.equal(dials(fx, 'builder').length, 1);
  assert.equal(events(fx, 'built').length + events(fx, 'build_error').length, 1);
});

test('critic wait exit 5 (blocked) pauses the run instead of reading as done', () => {
  const fx = makeFixture({ env: { FAKE_WAIT_RC_CRITIC: '5' } });
  initAndSplit(fx);
  const r = cli(fx, ['loop', '--run', fx.runDir]);
  assert.equal(r.json.last.action, 'paused');
  assert.equal(events(fx, 'verdict').length, 0);
  assert.equal(events(fx, 'paused')[0].role, 'critic');
  // Resume re-waits on the same call dir; once the critic answers, the round is judged.
  cli(fx, ['resume', '--run', fx.runDir]);
  const r2 = cli(fx, ['loop', '--run', fx.runDir, '--once'], { FAKE_WAIT_RC_CRITIC: '0' });
  assert.equal(r2.json.last.action, 'await');
  assert.equal(events(fx, 'verdict').length, 1);
});

test('a malformed verdict gets one non-fresh follow-up, then judge_error', () => {
  const fx = makeFixture({ env: { FAKE_CRITIC: 'malformed' }, spec: { budget: { max_rounds_total: 1 } } });
  initAndSplit(fx);
  cli(fx, ['loop', '--run', fx.runDir]);
  const critics = dials(fx, 'critic');
  assert.equal(critics.length, 2);
  assert.ok(!critics[1].argv.includes('--fresh'), 'the follow-up reuses the critic session');
  assert.equal(argOf(critics[1].argv, '--target'), argOf(critics[0].argv, '--target'));
  assert.equal(events(fx, 'verdict_malformed').length, 1);
  assert.match(events(fx, 'judge_error')[0].reason, /after retry/);
  assert.equal(events(fx, 'judged')[0].result, 'error');
});

test('a malformed verdict fixed by the follow-up counts', () => {
  const fx = makeFixture({ env: { FAKE_CRITIC: 'malformed-once' }, spec: { budget: { max_rounds_total: 1 } } });
  initAndSplit(fx);
  cli(fx, ['loop', '--run', fx.runDir]);
  assert.equal(events(fx, 'judged')[0].result, 'won');
});

test('a build with no trailer commit is a build_error', () => {
  const fx = makeFixture({ env: { FAKE_BUILDER: 'nocommit' }, spec: { budget: { max_rounds_total: 1 } } });
  initAndSplit(fx);
  cli(fx, ['loop', '--run', fx.runDir]);
  assert.match(events(fx, 'build_error')[0].reason, /no commit carries "Gauntlet: hero r1 run=demo"/);
  assert.equal(dials(fx, 'critic').length, 0);
});

test('one wave never has two builders in flight', () => {
  const fx = makeFixture({ spec: { budget: { max_rounds_total: 3 } } });
  initAndSplit(fx, [{ id: 'hero' }, { id: 'cta' }, { id: 'proof' }]);
  cli(fx, ['loop', '--run', fx.runDir]);
  let inflight = 0;
  for (const e of fx && JSON.parse('[' + readFileSync(join(fx.runDir, 'ledger.jsonl'), 'utf8').trim().split('\n').join(',') + ']')) {
    if (e.event === 'dispatched' && e.role === 'builder') { inflight++; assert.equal(inflight, 1); }
    if (['built', 'build_error'].includes(e.event)) inflight--;
  }
});

test('double judging dials twice with the assignment swapped', () => {
  const fx = makeFixture({ spec: { judge: { double: true }, budget: { max_rounds_total: 1 } } });
  initAndSplit(fx);
  cli(fx, ['loop', '--run', fx.runDir]);
  const v = events(fx, 'verdict');
  assert.equal(v.length, 2);
  assert.notEqual(v[0].ours, v[1].ours);
  assert.deepEqual(dials(fx, 'critic').map((d) => argOf(d.argv, '--label')), ['judge hero r1', 'judge hero r1 p2']);
  assert.equal(events(fx, 'judged')[0].swap_agreed, true);
});

test('rubric mode shows a labeled pair and wins at 7+', () => {
  const fx = makeFixture({ env: { FAKE_CRITIC: 'rubric-high' }, spec: { judge: { mode: 'rubric' }, budget: { max_rounds_total: 1 } } });
  initAndSplit(fx);
  cli(fx, ['loop', '--run', fx.runDir]);
  assert.match(dials(fx, 'critic')[0].prompt, /reference\.txt/);
  assert.equal(events(fx, 'judged')[0].result, 'won');
  assert.equal(events(fx, 'judged')[0].mode, 'rubric');
});

test('the trust dialog is answered with down enter and the target re-dialed without --fresh', () => {
  const fx = makeFixture({ env: { FAKE_TRUST: '1' }, spec: { budget: { max_rounds_total: 1 } } });
  initAndSplit(fx);
  cli(fx, ['loop', '--run', fx.runDir]);
  const herdr = readFileSync(join(fx.T, 'herdr.log'), 'utf8');
  assert.match(herdr, /agent send-keys agent-1 down enter/);
  const b = dials(fx, 'builder');
  assert.equal(b.length, 2);
  assert.ok(b[0].argv.includes('--fresh') && !b[1].argv.includes('--fresh'));
  assert.equal(events(fx, 'built').length, 1);
});

test('a failed dial is recorded, not thrown', () => {
  const fx = makeFixture({ env: { FAKE_DIAL_FAIL: 'builder' }, spec: { budget: { max_rounds_total: 1 } } });
  initAndSplit(fx);
  cli(fx, ['loop', '--run', fx.runDir]);
  assert.match(events(fx, 'build_error')[0].reason, /dial failed: boot: .*blocked during startup.*run `claude` once in the workspace/s);
});

test('no herdr-capable hotline → a one-line refusal', () => {
  const fx = makeFixture();
  writeFileSync(join(fx.env.GAUNTLET_HOTLINE_ROOT, 'skills/dial/scripts/dial.sh'), '#!/usr/bin/env bash\necho old\n');
  initAndSplit(fx);
  const r = cli(fx, ['loop', '--run', fx.runDir]);
  assert.equal(r.rc, 1);
  assert.match(r.stderr, /no herdr-capable hotline/);
});

test('--stop halts at the next step without finalizing; --resume continues', () => {
  const fx = makeFixture({ spec: { budget: { max_rounds_total: 1 } } });
  initAndSplit(fx);
  cli(fx, ['stop', '--run', fx.runDir]);
  const r = cli(fx, ['loop', '--run', fx.runDir]);
  assert.deepEqual(r.json.last, { action: 'stop', reason: 'human' });
  assert.equal(events(fx, 'stopped').length, 0);
  cli(fx, ['resume', '--run', fx.runDir]);
  const r2 = cli(fx, ['loop', '--run', fx.runDir]);
  assert.equal(r2.json.last.reason, 'budget:max_rounds_total');
  assert.equal(events(fx, 'judged').length, 1);
});
