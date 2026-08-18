#!/usr/bin/env bash
# =============================================================================
# Doc canary: the preempt-grace default has ONE source — the
# `HOTLINE_PREEMPT_GRACE:-<n>` fallback in wait-for-response.sh — and every
# prose statement of it must agree with that source.
#
# Why a string-match test and not a behavior test: the behavior (grace window
# opens on a preempting prompt, closes on our-nonce STATUS, exits 3 at the
# boundary) is pinned by wait-for-response_test.sh. What this guards is the
# NUMBER drifting between the code and the two places that state it — the
# script's own header and dial/SKILL.md's exit-3 entry — the exact two-source
# failure docs/compounding.md § "Each constant has one source" exists for.
# (claude-plugins-mrpi)
# =============================================================================
set -u

PASS=0
FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/plugins/hotline/skills/dial/scripts/wait-for-response.sh"
SKILL="$ROOT/plugins/hotline/skills/dial/SKILL.md"

pass() { PASS=$((PASS + 1)); echo "ok - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "not ok - $1"; }

# The one source of truth.
DEFAULT=$(grep -oE 'HOTLINE_PREEMPT_GRACE:-[0-9]+' "$SCRIPT" | head -1 | grep -oE '[0-9]+$')
if [[ -n "$DEFAULT" ]]; then
  pass "wait-for-response.sh declares a numeric HOTLINE_PREEMPT_GRACE default ($DEFAULT)"
else
  fail "wait-for-response.sh declares a numeric HOTLINE_PREEMPT_GRACE default"
fi

# The script header restates it — must agree.
if grep -qE "HOTLINE_PREEMPT_GRACE — how long \(default ${DEFAULT:-MISSING}," "$SCRIPT"; then
  pass "script header states the same default (${DEFAULT}s)"
else
  fail "script header states the same default (${DEFAULT}s)"
fi

# dial/SKILL.md's exit-3 entry restates it — must agree.
if grep -qE "\(${DEFAULT:-MISSING}s, .HOTLINE_PREEMPT_GRACE.\)" "$SKILL"; then
  pass "dial/SKILL.md exit-3 entry states the same default (${DEFAULT}s)"
else
  fail "dial/SKILL.md exit-3 entry states the same default (${DEFAULT}s)"
fi

echo "${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
