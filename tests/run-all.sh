#!/usr/bin/env bash
# =============================================================================
# Run every test suite in this repo.
#
# Usage: bash tests/run-all.sh
# Exit 0 only when every suite that could run passed.
#
# The suites are scattered by plugin and written in three languages (node --test,
# bash, pytest), which is why nothing was running them together. A suite whose
# runtime is absent is SKIPPED and reported as such — never silently passed.
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
		FAIL=$((FAIL + 1)); FAILED+=("$label"); printf '\033[31m✗ %s\033[0m\n' "$label"
	fi
}

skip() {
	SKIP=$((SKIP + 1)); printf '\n\033[33m− SKIP %s (%s)\033[0m\n' "$1" "$2"
}

# ---- node suites ------------------------------------------------------------

if have node; then
	run "parser drift (transcript.mjs ↔ switchboard)" node --test tests/parser-drift.test.mjs
	run "session-tools: transcript/digest" \
		node --test plugins/session-tools/skills/sessions-catch-up/tests/transcript.test.mjs
else
	skip "node suites" "node not installed"
fi

# ---- hotline bash suites ----------------------------------------------------
# Five of these drive cmux and cannot pass without it (they self-skip, but the
# skip is worth naming here rather than reading as a pass).

if have bash; then
	CMUX_OK=0; have cmux && CMUX_OK=1
	for t in plugins/hotline/tests/*_test.sh; do
		name="hotline: $(basename "$t" _test.sh)"
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

# stdlib unittest — no third-party deps, so this always runs.
if [[ -n "$PY" ]]; then
	run "session-tools: weekly-recap extractor" \
		"$PY" -m unittest discover -s plugins/session-tools/skills/sessions-weekly-recap/tests
else
	skip "weekly-recap extractor" "python3 not installed"
fi

if [[ -n "$PY" ]] && "$PY" -c 'import pytest' >/dev/null 2>&1; then
	for d in plugins/gws/skills/*/tests; do
		[[ -d "$d" ]] || continue
		run "gws: $(basename "$(dirname "$d")")" "$PY" -m pytest -q "$d"
	done
else
	skip "gws python suites" "pytest not available"
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
