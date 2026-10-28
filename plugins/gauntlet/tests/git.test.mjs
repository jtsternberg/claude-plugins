import assert from 'node:assert/strict';
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { cli, events, initAndSplit, makeFixture, sh } from './helpers.mjs';

test('init cuts the run branch in its own worktree and leaves the default branch alone', () => {
  const fx = makeFixture();
  const before = sh(fx.ws, 'git rev-parse main', fx.env);
  const r = cli(fx, ['init', fx.specPath]);
  assert.equal(r.rc, 0, r.stderr);
  assert.equal(r.json.branch, 'gauntlet/demo');
  assert.equal(r.json.base, 'main');
  assert.equal(sh(fx.worktree, 'git branch --show-current', fx.env), 'gauntlet/demo');
  assert.equal(sh(fx.ws, 'git rev-parse main', fx.env), before);
  assert.ok(existsSync(join(fx.runDir, 'refs/ref-a.txt')));
  assert.match(sh(fx.worktree, 'git log -1 --no-color --format=%B', fx.env), /Gauntlet: init run=demo/);
  assert.equal(cli(fx, ['init', fx.specPath]).rc, 1, 'a second init refuses');
});

test('init refuses a spec outside <workspace>/.gauntlet/<run-id>/', () => {
  const fx = makeFixture();
  mkdirSync(join(fx.ws, 'elsewhere'));
  renameSync(fx.specPath, join(fx.ws, 'elsewhere', 'gauntlet.json'));
  const r = cli(fx, ['init', join(fx.ws, 'elsewhere', 'gauntlet.json')]);
  assert.equal(r.rc, 2);
  assert.match(r.stderr, /must live at/);
});

test('builders commit with the round trailer; the script commits each verdict', () => {
  const fx = makeFixture({ spec: { budget: { max_rounds_total: 1 } } });
  initAndSplit(fx);
  cli(fx, ['loop', '--run', fx.runDir]);
  const log = sh(fx.worktree, 'git log --no-color --format=%B', fx.env);
  assert.match(log, /Gauntlet: hero r1 run=demo/);
  assert.match(log, /Gauntlet: hero r1 verdict=won run=demo/);
  assert.equal(events(fx, 'built')[0].commit, sh(fx.worktree, 'git log -1 --no-color --format=%H --grep="Gauntlet: hero r1 run=demo"', fx.env));
  assert.ok(sh(fx.worktree, 'git ls-files .gauntlet/demo', fx.env).includes('captures/hero/r1.txt'));
  assert.equal(sh(fx.worktree, 'git status --porcelain', fx.env), '', 'the run dir is fully committed');
});

test('commit_captures:false keeps captures and refs out of git', () => {
  const fx = makeFixture({ spec: { git: { commit_captures: false }, budget: { max_rounds_total: 1 } } });
  initAndSplit(fx);
  cli(fx, ['loop', '--run', fx.runDir]);
  const files = sh(fx.worktree, 'git ls-files .gauntlet/demo', fx.env);
  assert.ok(files.includes('ledger.jsonl'));
  assert.ok(!files.includes('captures/'));
  assert.ok(!files.includes('refs/'));
  assert.ok(existsSync(join(fx.runDir, 'captures/hero/r1.txt')), 'captures still exist on disk');
});

test('a reset past the last build commit stops the run', () => {
  const fx = makeFixture({ env: { FAKE_CRITIC: 'ref' } });
  initAndSplit(fx);
  while (events(fx, 'judged').length === 0) cli(fx, ['loop', '--run', fx.runDir, '--once']);
  // Rewind the branch to before round 1's build, keeping the ledger as it was.
  const saved = readFileSync(join(fx.runDir, 'ledger.jsonl'));
  sh(fx.worktree, `git reset -q --hard ${events(fx, 'built')[0].commit}~1`, fx.env);
  writeFileSync(join(fx.runDir, 'ledger.jsonl'), saved);
  const r = cli(fx, ['loop', '--run', fx.runDir]);
  assert.deepEqual(r.json.last, { action: 'stop', reason: 'history_rewritten' });
});

test('one bd task per run in the target project, closed on stop; no .beads → no bd', () => {
  const fx = makeFixture({ beads: true, spec: { budget: { max_rounds_total: 1 } } });
  initAndSplit(fx);
  assert.equal(events(fx, 'init')[0].bead, 'site-g1');
  cli(fx, ['loop', '--run', fx.runDir]);
  const bd = readFileSync(join(fx.T, 'bd.log'), 'utf8').trim().split('\n');
  assert.equal(bd.length, 2);
  assert.ok(bd[0].startsWith(`${fx.ws} create Gauntlet run demo`));
  assert.match(bd[1], /close site-g1 --reason gauntlet stopped: budget:max_rounds_total/);

  const bare = makeFixture({ spec: { budget: { max_rounds_total: 1 } } });
  initAndSplit(bare);
  cli(bare, ['loop', '--run', bare.runDir]);
  assert.ok(!existsSync(join(bare.T, 'bd.log')));
  assert.equal(events(bare, 'init')[0].bead, null);
});

test('--run accepts the setup copy in the workspace and maps it to the worktree run dir', () => {
  const fx = makeFixture();
  const before = cli(fx, ['status', '--run', fx.specPath]);
  assert.equal(before.rc, 3);
  assert.match(before.stderr, /not initialized/);
  initAndSplit(fx);
  const r = cli(fx, ['next', '--run', fx.specPath]);
  assert.equal(r.rc, 0, r.stderr);
  assert.equal(r.json.action, 'wave');
});
