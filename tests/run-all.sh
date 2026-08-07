#!/usr/bin/env bash
# =============================================================================
# Run every test suite in this repo.
#
# Usage: bash tests/run-all.sh
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

PASS=0; FAIL=0; SKIP=0
FAILED=()

have() { command -v "$1" >/dev/null 2>&1; }

run() {          # run <label> <command...>
	local label="$1"; shift
	printf '\n\033[1m=== %s ===\033[0m\n' "$label"
	if "$@"; then
		PASS=$((PASS + 1)); printf '\033[32m✓ %s\033[0m\n' "$label"
	else
		local status=$?
		if [[ $status -eq 77 ]]; then
			SKIP=$((SKIP + 1)); printf '\033[33m− SKIP %s (suite opted out)\033[0m\n' "$label"
		else
			FAIL=$((FAIL + 1)); FAILED+=("$label"); printf '\033[31m✗ %s\033[0m\n' "$label"
		fi
	fi
}

skip() {
	SKIP=$((SKIP + 1)); printf '\n\033[33m− SKIP %s (%s)\033[0m\n' "$1" "$2"
}

# ---- node suites ------------------------------------------------------------

if have node; then
	run "parser drift (transcript.mjs ↔ switchboard)" node --test tests/parser-drift.test.mjs
	# Discovered, not listed: a hardcoded list silently omits new suites. The handoff
	# bash suite shipped with 14 passing tests that CI never ran, because the globs
	# below used to name one plugin each.
	for t in plugins/*/skills/*/tests/*.test.mjs plugins/*/tests/*.test.mjs; do
		[[ -f "$t" ]] || continue
		run "node: ${t#plugins/}" node --test "$t"
	done
else
	skip "node suites" "node not installed"
fi

# ---- bash suites (any plugin) -----------------------------------------------
# Some hotline suites drive cmux and cannot pass without it (they self-skip, but the
# skip is worth naming here rather than reading as a pass).

if have bash; then
	CMUX_OK=0; have cmux && CMUX_OK=1
	for t in plugins/*/tests/*_test.sh; do
		[[ -f "$t" ]] || continue
		plugin="${t#plugins/}"; plugin="${plugin%%/*}"
		name="$plugin: $(basename "$t" _test.sh)"
		if [[ $CMUX_OK -eq 0 ]] && grep -q "command -v cmux" "$t" 2>/dev/null; then
			skip "$name" "needs cmux"
			continue
		fi
		run "$name" bash "$t"
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
	for d in plugins/*/skills/*/tests plugins/*/tests; do
		[[ -d "$d" ]] || continue
		compgen -G "$d/test_*.py" >/dev/null || continue

		plugin="${d#plugins/}"; plugin="${plugin%%/*}"
		sub="$(basename "$(dirname "$d")")"
		label="python: $plugin"
		[[ "$sub" != "$plugin" ]] && label="python: $plugin/$sub"

		# `unittest discover` collects only unittest.TestCase subclasses. A
		# pytest-style module of bare `def test_x()` functions would be silently
		# ignored — the exact silent-omission this file exists to prevent — so
		# fail loudly rather than reporting a green run over uncollected tests.
		for f in "$d"/test_*.py; do
			grep -q 'import unittest' "$f" && continue
			printf '\n\033[31m✗ %s has no `import unittest` — discover will not collect it\033[0m\n' "$f"
			FAIL=$((FAIL + 1)); FAILED+=("$label ($(basename "$f") not unittest-based)")
		done

		run "$label" "$PY" -m unittest discover -s "$d"
	done
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
