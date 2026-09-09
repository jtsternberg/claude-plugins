#!/usr/bin/env bash
# =============================================================================
# Run every test suite in this repo.
#
# Usage: bash tests/run-all.sh
#        RUN_ALL_JOBS=1 bash tests/run-all.sh  # serial execution
# Suites run four at a time by default. Their isolated output is replayed in
# discovery order after each batch, so failures remain readable and repeatable.
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

# Hotline's call scripts create scratch dirs under ${HOTLINE_CALL_HOME:-/tmp}.
# Point them at a run-scoped dir we own and wipe on exit, so a full suite run
# stops leaving hundreds of /tmp/hotline-call-* dirs behind (claude-plugins-cjgn).
# Only hotline scripts read this var, so it is inert for every other suite.
RUN_TMP_HOME="$(mktemp -d /tmp/run-all-XXXXXX)" || exit 1
RUN_OUTPUT_HOME="$RUN_TMP_HOME/output"
mkdir -p "$RUN_OUTPUT_HOME"
ACTIVE_PIDS=()
cleanup() {
	local pid attempt any_live
	for pid in ${ACTIVE_PIDS[@]+"${ACTIVE_PIDS[@]}"}; do kill -TERM -- "-$pid" 2>/dev/null || true; done
	for attempt in 1 2 3 4 5 6 7 8 9 10; do
		any_live=0
		for pid in ${ACTIVE_PIDS[@]+"${ACTIVE_PIDS[@]}"}; do
			kill -0 "$pid" 2>/dev/null && any_live=1
		done
		[[ $any_live -eq 0 ]] && break
		sleep 0.1
	done
	for pid in ${ACTIVE_PIDS[@]+"${ACTIVE_PIDS[@]}"}; do kill -KILL -- "-$pid" 2>/dev/null || true; done
	for pid in ${ACTIVE_PIDS[@]+"${ACTIVE_PIDS[@]}"}; do wait "$pid" 2>/dev/null || true; done
	rm -rf "$RUN_TMP_HOME"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

RUN_ALL_JOBS="${RUN_ALL_JOBS:-4}"
case "$RUN_ALL_JOBS" in
	''|*[!0-9]*|0|0[0-9]*)
		printf 'RUN_ALL_JOBS must be a positive whole number, got %s\n' "$RUN_ALL_JOBS" >&2
		exit 2
		;;
esac

PASS=0; FAIL=0; SKIP=0
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

# Run one batch concurrently, then replay its output in argument order. Batches
# avoid Bash 4-only job-control helpers (`wait -n`, associative arrays), so the
# same runner works under macOS's Bash 3 and Linux. Each suite gets a private log;
# a noisy failure can never interleave with another suite's diagnostics.
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

run_batch() {    # run_batch <label> <kind> <path> [triples...]
	local labels=() logs=() ends=() pids=() statuses=() starts=()
	local label kind path log end_file job_tmp pid status i ended
	# Monitor mode gives every async suite its own process group, including the
	# servers it starts. The signal cleanup above can therefore stop the whole
	# suite tree without `setsid`, which macOS does not provide by default.
	set -m
	while [[ $# -gt 0 ]]; do
		label="$1"; kind="$2"; path="$3"; shift 3
		TASK_SERIAL=$((TASK_SERIAL + 1))
		log="$RUN_OUTPUT_HOME/$TASK_SERIAL.log"
		end_file="$RUN_OUTPUT_HOME/$TASK_SERIAL.end"
		job_tmp="$RUN_TMP_HOME/t$TASK_SERIAL"
		mkdir -p "$job_tmp/calls"
		labels+=("$label"); logs+=("$log"); ends+=("$end_file")
		starts+=("$(date +%s)")
		( run_task "$kind" "$path" "$log" "$end_file" "$job_tmp" ) &
		pids+=("$!")
		ACTIVE_PIDS+=("$!")
	done
	printf '\nRunning %d suite(s) with up to %d jobs...\n' "${#labels[@]}" "$RUN_ALL_JOBS"

	for pid in "${pids[@]}"; do
		wait "$pid"; statuses+=("$?")
	done
	set +m
	for ((i = 0; i < ${#labels[@]}; i++)); do
		printf '\n\033[1m=== %s ===\033[0m\n' "${labels[$i]}"
		cat "${logs[$i]}"
		# report prints a heading itself; update the counters inline after the
		# already-rendered suite heading so each label appears only once.
		status="${statuses[$i]}"
		ended=$(cat "${ends[$i]}")
		if [[ $status -eq 0 ]]; then
			PASS=$((PASS + 1)); printf '\033[32m✓ %s\033[0m\n' "${labels[$i]}"
		elif [[ $status -eq 77 ]]; then
			SKIP=$((SKIP + 1)); printf '\033[33m− SKIP %s (suite opted out)\033[0m\n' "${labels[$i]}"
		else
			FAIL=$((FAIL + 1)); FAILED+=("${labels[$i]}"); printf '\033[31m✗ %s\033[0m\n' "${labels[$i]}"
		fi
		printf '  completed in %ss\n' "$((ended - starts[$i]))"
	done
	ACTIVE_PIDS=()
}

enqueue() {      # enqueue <label> <command> <path>
	BATCH+=("$1" "$2" "$3")
	BATCH_COUNT=$((BATCH_COUNT + 1))
	if [[ $BATCH_COUNT -ge $RUN_ALL_JOBS ]]; then
		run_batch "${BATCH[@]}"
		BATCH=(); BATCH_COUNT=0
	fi
}

flush() {
	[[ $BATCH_COUNT -eq 0 ]] || run_batch "${BATCH[@]}"
	BATCH=(); BATCH_COUNT=0
}

BATCH=(); BATCH_COUNT=0; TASK_SERIAL=0

# ---- node suites ------------------------------------------------------------

if have node; then
	enqueue "parser drift (transcript.mjs ↔ switchboard)" node tests/parser-drift.test.mjs
	enqueue "codex catalog drift (native ↔ legacy + policy)" node tests/codex-catalog-drift.test.mjs
	[[ ! -f tests/run-all-runner.test.mjs ]] || enqueue "run-all runner behavior" node tests/run-all-runner.test.mjs
	# Discovered, not listed: a hardcoded list silently omits new suites. The handoff
	# bash suite shipped with 14 passing tests that CI never ran, because the globs
	# below used to name one plugin each.
	for t in plugins/*/skills/*/tests/*.test.mjs plugins/*/tests/*.test.mjs \
	         plugins/*/*/skills/*/tests/*.test.mjs plugins/*/*/tests/*.test.mjs; do
		[[ -f "$t" ]] || continue
		enqueue "node: ${t#plugins/}" node "$t"
	done
	flush
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
	flush
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
	flush
else
	skip "python suites" "python3 not installed"
fi

# ---- summary ----------------------------------------------------------------

printf '\n\033[1m──────── summary ────────\033[0m\n'
printf 'passed  %d\nfailed  %d\nskipped %d\n' "$PASS" "$FAIL" "$SKIP"
if [[ $FAIL -gt 0 ]]; then
	printf '\n\033[31mFailed suites:\033[0m\n'
	printf '  %s\n' "${FAILED[@]}"
	exit 1
fi
exit 0
