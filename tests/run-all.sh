#!/usr/bin/env bash
# =============================================================================
# Run every test suite in this repo.
#
# Usage: bash tests/run-all.sh
#        RUN_ALL_JOBS=1 bash tests/run-all.sh  # serial execution
# Every suite goes into one global work queue that keeps up to RUN_ALL_JOBS
# slots busy: the moment a slot frees, the next suite starts. Output is
# buffered per suite and replayed in discovery order, so failures remain
# readable and repeatable no matter what order the suites finished in.
# Exit 0 only when every suite that could run passed.
#
# The suites are scattered by plugin and written in three languages (node --test,
# bash, python unittest), which is why nothing was running them together. A suite
# whose runtime is absent is SKIPPED and reported as such — never silently passed.
#
# Corollary learned the hard way: a skip is only honest if it can actually be
# satisfied. Gating a suite on a runtime that CI never installs is a permanent
# skip wearing a temporary skip's clothing — see the python section.
# =============================================================================
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1

RUN_STARTED=$(date +%s)

# Hotline's call scripts create scratch dirs under ${HOTLINE_CALL_HOME:-/tmp}.
# Point them at a run-scoped dir we own and wipe on exit, so a full suite run
# stops leaving hundreds of /tmp/hotline-call-* dirs behind (claude-plugins-cjgn).
# Only hotline scripts read this var, so it is inert for every other suite.
RUN_TMP_HOME="$(mktemp -d /tmp/run-all-XXXXXX)" || exit 1
RUN_OUTPUT_HOME="$RUN_TMP_HOME/output"
mkdir -p "$RUN_OUTPUT_HOME"
# Slot-indexed and holding *only* pids still in flight — a freed slot is emptied
# the moment its suite is reaped. cleanup below signals process *groups* by
# number, and a reaped pid's number is free for the kernel to reissue: this box
# churns ~500 pids/s against a 99,999 ceiling, so an every-pid-ever list would,
# on a Ctrl-C two minutes into a run, aim SIGKILL at ~50 numbers that now belong
# to somebody else's shell, editor, or agent session — and take their whole group
# with them. Every suite gets a group whose pgid equals its own pid (`set -m`
# below), so live pids are all the bookkeeping this needs.
ACTIVE_PIDS=()
cleanup() {
	local pid attempt any_live live=()
	for pid in ${ACTIVE_PIDS[@]+"${ACTIVE_PIDS[@]}"}; do
		[[ -z "$pid" ]] || live+=("$pid")
	done
	for pid in ${live[@]+"${live[@]}"}; do kill -TERM -- "-$pid" 2>/dev/null || true; done
	for attempt in 1 2 3 4 5 6 7 8 9 10; do
		any_live=0
		for pid in ${live[@]+"${live[@]}"}; do
			kill -0 "$pid" 2>/dev/null && any_live=1
		done
		[[ $any_live -eq 0 ]] && break
		sleep 0.1
	done
	for pid in ${live[@]+"${live[@]}"}; do kill -KILL -- "-$pid" 2>/dev/null || true; done
	for pid in ${live[@]+"${live[@]}"}; do wait "$pid" 2>/dev/null || true; done
	rm -rf "$RUN_TMP_HOME"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# One job per core, because a hardcoded number is wrong on some box: too wide
# oversubscribes a small runner or container, and the suites that assert on
# short wall-clock timeouts are the first to notice; too narrow leaves a
# 12-core laptop idle. ubuntu-latest reports 4 cores for a public repo, so CI
# and a laptop both land on the 4 ceiling; the 2 floor is for anything smaller.
default_jobs() {
	local n=""
	case "$(uname -s 2>/dev/null || true)" in
		Darwin) n="$(sysctl -n hw.ncpu 2>/dev/null || true)" ;;
		*)      n="$(nproc 2>/dev/null || true)" ;;
	esac
	case "$n" in ''|*[!0-9]*|0) n=4 ;; esac
	# Clamped to 2..4, measured rather than guessed. Below 2 a single-core box
	# would serialize an 8-minute run. The 4 ceiling is not a property of the
	# suites: an 8-job run on a 12-core laptop came out slower overall and
	# failed surface-placement, whose assertion has a fixed wall-clock budget
	# that expires once the box is loaded enough — tracked as
	# claude-plugins-fjuh. Fix that test and this ceiling may well lift.
	[[ $n -lt 2 ]] && n=2
	[[ $n -gt 4 ]] && n=4
	printf '%s\n' "$n"
}

RUN_ALL_JOBS="${RUN_ALL_JOBS:-$(default_jobs)}"
case "$RUN_ALL_JOBS" in
	''|*[!0-9]*|0|0[0-9]*)
		printf 'RUN_ALL_JOBS must be a positive whole number, got %s\n' "$RUN_ALL_JOBS" >&2
		exit 2
		;;
esac

PASS=0; FAIL=0; SKIP=0
SUITE_SECONDS=0
FAILED=()

have() { command -v "$1" >/dev/null 2>&1; }

report() {       # report <label> <status> [reason]
	local label="$1"; shift
	printf '\n\033[1m=== %s ===\033[0m\n' "$label"
	local status="$1"; shift
	if [[ $status -eq 0 ]]; then
		PASS=$((PASS + 1)); printf '\033[32m✓ %s\033[0m\n' "$label"
	elif [[ $status -eq 77 ]]; then
		SKIP=$((SKIP + 1)); printf '\033[33m− SKIP %s (%s)\033[0m\n' "$label" "${1:-suite opted out}"
	else
		FAIL=$((FAIL + 1)); FAILED+=("$label"); printf '\033[31m✗ %s\033[0m\n' "$label"
	fi
}

skip() {
	report "$1" 77 "$2"
}

# ---- the work queue ---------------------------------------------------------
# Suites are collected first and run last, from a single queue that spans all
# three languages: the 2s worth of node suites have to be free to fill the gaps
# left by the multi-minute bash ones. Each suite gets a private log, so a noisy
# failure can never interleave with another suite's diagnostics, and the logs
# are replayed in discovery order rather than completion order.

TASK_LABEL=(); TASK_KIND=(); TASK_PATH=()
TASK_STATUS=(); TASK_START=(); TASK_LOG=(); TASK_END=()
TASK_COUNT=0; TASK_SERIAL=0

enqueue() {      # enqueue <label> <kind> <path>
	TASK_LABEL+=("$1"); TASK_KIND+=("$2"); TASK_PATH+=("$3")
	TASK_STATUS+=(""); TASK_START+=(""); TASK_LOG+=(""); TASK_END+=("")
	TASK_COUNT=$((TASK_COUNT + 1))
}

# Longest-first is a packing optimization *only* — the queue is correct in any
# order. Starting the handful of suites that dominate the run first keeps the
# tail from being one multi-minute suite finishing alone while every slot sits
# idle. Refresh this list from the `completed in Ns` lines the runner already
# prints; it is deliberately not a persisted timing cache.
SLOW_FIRST="herdr-transport dial_wrapper cmux-reuse-surface wait-for-cmux"

already_queued() {  # already_queued <task-index>
	local candidate="$1" queued
	for queued in ${RUN_ORDER[@]+"${RUN_ORDER[@]}"}; do
		[[ $queued -eq $candidate ]] && return 0
	done
	return 1
}

build_run_order() {
	local i slow
	RUN_ORDER=()
	# With one slot the packing hint is all cost and no benefit: the run takes the
	# same total either way, but discovery order lets each suite's output land as
	# it finishes instead of holding five minutes of it behind the slow four.
	if [[ $RUN_ALL_JOBS -le 1 ]]; then
		for ((i = 0; i < TASK_COUNT; i++)); do RUN_ORDER+=("$i"); done
		return 0
	fi
	for slow in $SLOW_FIRST; do
		for ((i = 0; i < TASK_COUNT; i++)); do
			case "${TASK_LABEL[$i]}" in
				*": $slow") already_queued "$i" || RUN_ORDER+=("$i") ;;
			esac
		done
	done
	for ((i = 0; i < TASK_COUNT; i++)); do
		already_queued "$i" || RUN_ORDER+=("$i")
	done
	# RUN_ORDER is the launch loop's only source of task indices and that loop
	# stops at TASK_COUNT, so an order longer than the queue silently drops its
	# tail: the dropped task never launches, its status stays empty, and the
	# replay loop then waits on it forever with nothing in flight and nothing
	# printed. Naming one suite twice in SLOW_FIRST was enough to do it, and
	# the comment above that list invites hand-editing. Fail here instead: in
	# CI the alternative is a job that burns its whole timeout in silence.
	if [[ ${#RUN_ORDER[@]} -ne $TASK_COUNT ]]; then
		printf 'run order holds %d entries for %d suite(s) — check SLOW_FIRST for duplicates\n' \
			"${#RUN_ORDER[@]}" "$TASK_COUNT" >&2
		exit 2
	fi
}

run_task() {     # run_task <kind> <path> <log> <end-file> <tmp-dir>
	local kind="$1" path="$2" log="$3" end_file="$4" job_tmp="$5" status
	export TMPDIR="$job_tmp" HOTLINE_CALL_HOME="$job_tmp/calls"
	case "$kind" in
		node)   node --test "$path" >"$log" 2>&1 ;;
		bash)   bash "$path" >"$log" 2>&1 ;;
		python) "$PY" -m unittest discover -s "$path" >"$log" 2>&1 ;;
	esac
	status=$?
	date +%s > "$end_file"
	return "$status"
}

launch_task() {  # launch_task <task-index>; sets LAUNCHED_PID
	local i="$1" job_tmp
	TASK_SERIAL=$((TASK_SERIAL + 1))
	TASK_LOG[$i]="$RUN_OUTPUT_HOME/$TASK_SERIAL.log"
	TASK_END[$i]="$RUN_OUTPUT_HOME/$TASK_SERIAL.end"
	job_tmp="$RUN_TMP_HOME/t$TASK_SERIAL"
	mkdir -p "$job_tmp/calls"
	TASK_START[$i]="$(date +%s)"
	( run_task "${TASK_KIND[$i]}" "${TASK_PATH[$i]}" "${TASK_LOG[$i]}" "${TASK_END[$i]}" "$job_tmp" ) &
	LAUNCHED_PID=$!
}

replay_task() {  # replay_task <task-index>
	local i="$1" status ended
	printf '\n\033[1m=== %s ===\033[0m\n' "${TASK_LABEL[$i]}"
	cat "${TASK_LOG[$i]}"
	# report prints a heading itself; update the counters inline after the
	# already-rendered suite heading so each label appears only once.
	status="${TASK_STATUS[$i]}"
	if [[ $status -eq 0 ]]; then
		PASS=$((PASS + 1)); printf '\033[32m✓ %s\033[0m\n' "${TASK_LABEL[$i]}"
	elif [[ $status -eq 77 ]]; then
		SKIP=$((SKIP + 1)); printf '\033[33m− SKIP %s (suite opted out)\033[0m\n' "${TASK_LABEL[$i]}"
	else
		FAIL=$((FAIL + 1)); FAILED+=("${TASK_LABEL[$i]}"); printf '\033[31m✗ %s\033[0m\n' "${TASK_LABEL[$i]}"
	fi
	# A suite whose whole process group is killed never writes its .end stamp,
	# and the subtraction below then printed a nonsense negative elapsed time.
	ended=""
	[[ ! -f "${TASK_END[$i]}" ]] || ended="$(cat "${TASK_END[$i]}")"
	case "$ended" in
		''|*[!0-9]*)
			printf '  did not finish (no completion time recorded)\n'
			;;
		*)
			printf '  completed in %ss\n' "$((ended - ${TASK_START[$i]}))"
			SUITE_SECONDS=$((SUITE_SECONDS + ended - ${TASK_START[$i]}))
			;;
	esac
}

run_queue() {
	local slot_task=() j i pid next replay busy reaped finished
	[[ $TASK_COUNT -gt 0 ]] || return 0
	build_run_order
	printf '\nRunning %d suite(s) with up to %d jobs...\n' "$TASK_COUNT" "$RUN_ALL_JOBS"
	for ((j = 0; j < RUN_ALL_JOBS; j++)); do ACTIVE_PIDS[$j]=""; slot_task[$j]=-1; done
	# Monitor mode gives every async suite its own process group, including the
	# servers it starts. The signal cleanup above can therefore stop the whole
	# suite tree without `setsid`, which macOS does not provide by default.
	set -m
	next=0; replay=0; finished=0
	while [[ $replay -lt $TASK_COUNT ]]; do
		busy=0
		for ((j = 0; j < RUN_ALL_JOBS; j++)); do
			if [[ -z "${ACTIVE_PIDS[$j]}" ]] && [[ $next -lt $TASK_COUNT ]]; then
				i="${RUN_ORDER[$next]}"; next=$((next + 1))
				launch_task "$i"
				ACTIVE_PIDS[$j]="$LAUNCHED_PID"; slot_task[$j]="$i"
			fi
			[[ -z "${ACTIVE_PIDS[$j]}" ]] || busy=$((busy + 1))
		done
		# Bash 3 has no `wait -n`, so ask the live slots whether they are still
		# there with `kill -0` on a 0.1s tick — under 1% overhead across a run
		# this long. When only one suite is left in flight there is nothing to
		# poll *for*, so block on it instead; that also makes RUN_ALL_JOBS=1 a
		# plain serial `wait` with no ticking at all.
		reaped=0
		for ((j = 0; j < RUN_ALL_JOBS; j++)); do
			pid="${ACTIVE_PIDS[$j]}"
			[[ -n "$pid" ]] || continue
			if [[ $busy -gt 1 ]]; then
				kill -0 "$pid" 2>/dev/null && continue
			fi
			wait "$pid"; TASK_STATUS[${slot_task[$j]}]=$?
			finished=$((finished + 1))
			# Replay is strictly discovery-ordered, so nothing at all prints until
			# the suite at position 0 finishes — 54s of a 145s run, and a run whose
			# position-0 suite hangs prints nothing for its entire lifetime. This
			# line is the only evidence a CI log gets that the other 57 suites ran.
			printf '  ⋯ launched %d/%d · finished %d — %s\n' \
				"$next" "$TASK_COUNT" "$finished" "${TASK_LABEL[${slot_task[$j]}]}"
			ACTIVE_PIDS[$j]=""; slot_task[$j]=-1; reaped=1
		done
		[[ $reaped -eq 1 ]] || sleep 0.1
		while [[ $replay -lt $TASK_COUNT ]] && [[ -n "${TASK_STATUS[$replay]}" ]]; do
			replay_task "$replay"; replay=$((replay + 1))
		done
	done
	set +m
	ACTIVE_PIDS=()
}

# ---- node suites ------------------------------------------------------------

if have node; then
	# Discovered, not listed: a hardcoded list silently omits new suites. The handoff
	# bash suite shipped with 14 passing tests that CI never ran, because the globs
	# below used to name one plugin each. The repo's own tests/ suites are globbed
	# for that same reason: named one by one, a rename there takes the runner's
	# own tests out of the run without a word.
	for t in tests/*.test.mjs \
	         plugins/*/skills/*/tests/*.test.mjs plugins/*/tests/*.test.mjs \
	         plugins/*/*/skills/*/tests/*.test.mjs plugins/*/*/tests/*.test.mjs; do
		[[ -f "$t" ]] || continue
		enqueue "node: ${t#plugins/}" node "$t"
	done
else
	skip "node suites" "node not installed"
fi

# ---- bash suites (any plugin) -----------------------------------------------
# Some hotline suites drive cmux and cannot pass without it (they self-skip, but the
# skip is worth naming here rather than reading as a pass).

if have bash; then
	CMUX_OK=0; have cmux && CMUX_OK=1
	for t in plugins/*/tests/*_test.sh plugins/*/*/tests/*_test.sh; do
		[[ -f "$t" ]] || continue
		plugin="${t#plugins/}"; plugin="${plugin%/tests/*}"
		name="$plugin: $(basename "$t" _test.sh)"
		if [[ $CMUX_OK -eq 0 ]] && grep -q "command -v cmux" "$t" 2>/dev/null; then
			skip "$name" "needs cmux"
			continue
		fi
		enqueue "$name" bash "$t"
	done
fi

# ---- python suites ----------------------------------------------------------

PY="$HOME/.venvs/genai/bin/python3"
[[ -x "$PY" ]] || PY="$(command -v python3 || true)"

# Every python suite here is stdlib unittest, so a bare python3 runs all of them.
# This used to be a hardcoded session-tools case plus a gws loop gated on
# `import pytest` — and since CI installs no python packages, that gate skipped
# all six gws suites (54 tests) on every run while still exiting 0. Same
# hardcoded-list failure the node section warns about, one language over.
# Glob by path, never by plugin name.
if [[ -n "$PY" ]]; then
	for d in plugins/*/skills/*/tests plugins/*/tests \
	         plugins/*/*/skills/*/tests plugins/*/*/tests; do
		[[ -d "$d" ]] || continue
		compgen -G "$d/test_*.py" >/dev/null || continue

		plugin="${d#plugins/}"; plugin="${plugin%%/skills/*}"; plugin="${plugin%/tests}"
		sub="$(basename "$(dirname "$d")")"
		label="python: $plugin"
		[[ "$sub" != "$(basename "$plugin")" ]] && label="python: $plugin/$sub"

		# `unittest discover` collects only unittest.TestCase subclasses. A
		# pytest-style module of bare `def test_x()` functions would be silently
		# ignored — the exact silent-omission this file exists to prevent — so
		# fail loudly rather than reporting a green run over uncollected tests.
		for f in "$d"/test_*.py; do
			grep -q 'import unittest' "$f" && continue
			printf '\n\033[31m✗ %s has no `import unittest` — discover will not collect it\033[0m\n' "$f"
			FAIL=$((FAIL + 1)); FAILED+=("$label ($(basename "$f") not unittest-based)")
		done

		enqueue "$label" python "$d"
	done
else
	skip "python suites" "python3 not installed"
fi

run_queue

# ---- summary ----------------------------------------------------------------

printf '\n\033[1m──────── summary ────────\033[0m\n'
printf 'passed  %d\nfailed  %d\nskipped %d\n' "$PASS" "$FAIL" "$SKIP"
printf 'TOTAL   %ss of suite work in %ss wall clock\n' "$SUITE_SECONDS" "$(($(date +%s) - RUN_STARTED))"
if [[ $FAIL -gt 0 ]]; then
	printf '\n\033[31mFailed suites:\033[0m\n'
	printf '  %s\n' "${FAILED[@]}"
	exit 1
fi
exit 0
