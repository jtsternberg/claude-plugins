import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { chmodSync, cpSync, existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { availableParallelism, cpus, tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

const sourceRunner = process.env.RUN_ALL_RUNNER_SOURCE ?? new URL('./run-all.sh', import.meta.url);

function writeExecutable(path, contents) {
	writeFileSync(path, contents);
	chmodSync(path, 0o755);
}

function createFixture() {
	const root = mkdtempSync(join(tmpdir(), 'run-all-runner-test-'));
	mkdirSync(join(root, 'tests'), { recursive: true });
	mkdirSync(join(root, 'plugins', 'fixture', 'tests'), { recursive: true });
	cpSync(sourceRunner, join(root, 'tests', 'run-all.sh'));
	writeFileSync(join(root, 'tests', 'parser-drift.test.mjs'), "// fixture\n");
	writeFileSync(join(root, 'tests', 'codex-catalog-drift.test.mjs'), "// fixture\n");
	return root;
}

function addTrackedSuite(root, name, delay, exitCode = 0) {
	const suite = join(root, 'plugins', 'fixture', 'tests', `${name}_test.sh`);
	writeExecutable(suite, `#!/usr/bin/env bash
set -u
while ! mkdir "$RUNNER_TEST_STATE/lock" 2>/dev/null; do sleep 0.01; done
active=0
[[ ! -f "$RUNNER_TEST_STATE/active" ]] || active=$(<"$RUNNER_TEST_STATE/active")
active=$((active + 1))
printf '%s\n' "$active" > "$RUNNER_TEST_STATE/active"
maximum=0
[[ ! -f "$RUNNER_TEST_STATE/maximum" ]] || maximum=$(<"$RUNNER_TEST_STATE/maximum")
((active <= maximum)) || printf '%s\n' "$active" > "$RUNNER_TEST_STATE/maximum"
rmdir "$RUNNER_TEST_STATE/lock"
sleep ${delay}
printf 'output-${name}\n'
while ! mkdir "$RUNNER_TEST_STATE/lock" 2>/dev/null; do sleep 0.01; done
active=$(<"$RUNNER_TEST_STATE/active")
printf '%s\n' "$((active - 1))" > "$RUNNER_TEST_STATE/active"
rmdir "$RUNNER_TEST_STATE/lock"
exit ${exitCode}
`);
}

// A suite that cannot finish until some *later* suite in the queue has started.
// It passes under a work queue and deadlocks under a batch barrier.
function addGatedSuite(root, name, sentinel, ticks = 400) {
	writeExecutable(join(root, 'plugins', 'fixture', 'tests', `${name}_test.sh`), `#!/usr/bin/env bash
set -u
for ((i = 0; i < ${ticks}; i++)); do
	[[ ! -f "$RUNNER_TEST_STATE/${sentinel}" ]] || { printf 'output-${name}\\n'; exit 0; }
	sleep 0.05
done
printf 'gate never opened\\n'
exit 1
`);
}

function addSentinelSuite(root, name, sentinel) {
	writeExecutable(join(root, 'plugins', 'fixture', 'tests', `${name}_test.sh`), `#!/usr/bin/env bash
set -u
: > "$RUNNER_TEST_STATE/${sentinel}"
printf 'output-${name}\\n'
`);
}

function runFixture(root, jobs) {
	const state = join(root, 'state');
	mkdirSync(state, { recursive: true });
	// Strip an inherited RUN_ALL_JOBS when the fixture wants the default: these
	// suites run *under* the very runner they test, so `RUN_ALL_JOBS=1 bash
	// tests/run-all.sh` used to leak its 1 into the fixture and fail the
	// default-job-count assertion.
	const env = { ...process.env, RUNNER_TEST_STATE: state };
	if (jobs === undefined) delete env.RUN_ALL_JOBS;
	else env.RUN_ALL_JOBS = String(jobs);
	return spawnSync('bash', ['tests/run-all.sh'], { cwd: root, env, encoding: 'utf8' });
}

test('limits concurrent suites and replays their output in discovery order', (t) => {
	const root = createFixture();
	t.after(() => rmSync(root, { recursive: true, force: true }));
	addTrackedSuite(root, 'a_slow', 0.3);
	addTrackedSuite(root, 'b_fast', 0.05);
	addTrackedSuite(root, 'c_fast', 0.05);

	const result = runFixture(root, 2);

	assert.equal(result.status, 0, result.stderr || result.stdout);
	assert.equal(readFileSync(join(root, 'state', 'maximum'), 'utf8').trim(), '2');
	assert.ok(result.stdout.indexOf('output-a_slow') < result.stdout.indexOf('output-b_fast'));
	assert.ok(result.stdout.indexOf('output-b_fast') < result.stdout.indexOf('output-c_fast'));
});

test('counts suite failures and exit-77 skips separately', (t) => {
	const root = createFixture();
	t.after(() => rmSync(root, { recursive: true, force: true }));
	addTrackedSuite(root, 'a_pass', 0.01);
	addTrackedSuite(root, 'b_fail', 0.01, 1);
	addTrackedSuite(root, 'c_skip', 0.01, 77);

	const result = runFixture(root, 3);

	assert.equal(result.status, 1);
	assert.match(result.stdout, /passed\s+3\nfailed\s+1\nskipped\s+1/);
	assert.match(result.stdout, /Failed suites:[\s\S]*fixture: b_fail/);
});

test('RUN_ALL_JOBS=1 forces serial execution', (t) => {
	const root = createFixture();
	t.after(() => rmSync(root, { recursive: true, force: true }));
	addTrackedSuite(root, 'a', 0.05);
	addTrackedSuite(root, 'b', 0.05);

	const result = runFixture(root, 1);

	assert.equal(result.status, 0, result.stderr || result.stdout);
	assert.equal(readFileSync(join(root, 'state', 'maximum'), 'utf8').trim(), '1');
});

test('defaults to one job per core and gives every suite a fresh temp namespace', (t) => {
	const root = createFixture();
	t.after(() => rmSync(root, { recursive: true, force: true }));
	for (const name of ['a', 'b', 'c', 'd', 'e']) {
		addTrackedSuite(root, name, 0.02);
		const suite = join(root, 'plugins', 'fixture', 'tests', `${name}_test.sh`);
		writeFileSync(suite, readFileSync(suite, 'utf8').replace(
			`exit ${0}`,
			`printf '%s\\n' "$TMPDIR" >> "$RUNNER_TEST_STATE/namespaces"\nexit 0`,
		));
	}

	const result = runFixture(root);
	const namespaces = readFileSync(join(root, 'state', 'namespaces'), 'utf8').trim().split('\n');
	// Mirrors the runner's own clamp: one job per core, never below 2, never
	// above 4. A hardcoded default oversubscribed CI's 2-core runners 2x.
	const expected = Math.min(4, Math.max(2, availableParallelism?.() ?? cpus().length));
	assert.equal(result.status, 0, result.stderr || result.stdout);
	assert.match(result.stdout, new RegExp(`with up to ${expected} jobs`));
	assert.equal(new Set(namespaces).size, 5);
});

test('termination kills suite descendants and removes the run temp root', async (t) => {
	const root = createFixture();
	t.after(() => rmSync(root, { recursive: true, force: true }));
	writeExecutable(join(root, 'plugins', 'fixture', 'tests', 'hang_test.sh'), `#!/usr/bin/env bash
printf '%s\n' "$TMPDIR" > "$RUNNER_TEST_STATE/tmpdir"
sleep 30 &
printf '%s\n' "$!" > "$RUNNER_TEST_STATE/child"
wait
`);
	const state = join(root, 'state');
	mkdirSync(state, { recursive: true });
	const proc = spawn('/bin/bash', ['tests/run-all.sh'], {
		cwd: root,
		env: { ...process.env, RUN_ALL_JOBS: '1', RUNNER_TEST_STATE: state },
		stdio: 'ignore',
	});
	for (let i = 0; i < 100 && !existsSync(join(state, 'child')); i++) {
		await new Promise(resolve => setTimeout(resolve, 20));
	}
	assert.ok(existsSync(join(state, 'child')), 'fixture child did not start');
	const child = Number(readFileSync(join(state, 'child'), 'utf8').trim());
	const suiteTmp = readFileSync(join(state, 'tmpdir'), 'utf8').trim();
	proc.kill('SIGTERM');
	await new Promise(resolve => proc.once('close', resolve));
	assert.throws(() => process.kill(child, 0));
	assert.equal(existsSync(suiteTmp), false);
});

test('rejects invalid RUN_ALL_JOBS values before running suites', (t) => {
	const root = createFixture();
	t.after(() => rmSync(root, { recursive: true, force: true }));

	for (const value of ['0', '00', '08', 'two']) {
		const result = runFixture(root, value);
		assert.equal(result.status, 2, `RUN_ALL_JOBS=${JSON.stringify(value)}`);
		assert.match(result.stderr, /RUN_ALL_JOBS must be a positive whole number/);
	}
});

test('starts the next suite the moment a slot frees instead of waiting for a batch', (t) => {
	const root = createFixture();
	t.after(() => rmSync(root, { recursive: true, force: true }));
	// a_gate finishes only once e_last — the last suite in the queue — has run.
	// With two slots, a batch barrier holds e_last behind a_gate's own batch, so
	// the gate never opens and the suite fails.
	addGatedSuite(root, 'a_gate', 'gate-open');
	addTrackedSuite(root, 'b', 0.02);
	addTrackedSuite(root, 'c', 0.02);
	addTrackedSuite(root, 'd', 0.02);
	addSentinelSuite(root, 'e_last', 'gate-open');

	const result = runFixture(root, 2);

	assert.equal(result.status, 0, result.stdout);
	assert.doesNotMatch(result.stdout, /gate never opened/);
	assert.ok(result.stdout.indexOf('output-a_gate') < result.stdout.indexOf('output-e_last'));
});

test('a suite killed with its process group reports no completion time', (t) => {
	const root = createFixture();
	t.after(() => rmSync(root, { recursive: true, force: true }));
	const safePgid = spawnSync('ps', ['-o', 'pgid=', '-p', String(process.pid)], { encoding: 'utf8' }).stdout.trim();
	// The suite kills its whole process group, which is how a suite can exit
	// without ever writing its .end stamp. It refuses to fire unless monitor
	// mode really did give it a group of its own — otherwise it would take this
	// test process with it.
	writeExecutable(join(root, 'plugins', 'fixture', 'tests', 'suicide_test.sh'), `#!/usr/bin/env bash
set -u
pgid=$(ps -o pgid= -p $$ | tr -d ' ')
if [[ "$pgid" == "$RUNNER_TEST_SAFE_PGID" ]]; then
	printf 'refusing to kill the shared process group\\n'
	exit 1
fi
kill -KILL -- "-$pgid"
sleep 5
`);
	const state = join(root, 'state');
	mkdirSync(state, { recursive: true });

	const result = spawnSync('bash', ['tests/run-all.sh'], {
		cwd: root,
		env: { ...process.env, RUN_ALL_JOBS: '1', RUNNER_TEST_STATE: state, RUNNER_TEST_SAFE_PGID: safePgid },
		encoding: 'utf8',
	});

	assert.equal(result.status, 1, result.stdout);
	assert.doesNotMatch(result.stdout, /refusing to kill the shared process group/);
	assert.match(result.stdout, /did not finish \(no completion time recorded\)/);
	assert.doesNotMatch(result.stdout, /completed in -/);
});
