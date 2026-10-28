#!/usr/bin/env bash
# =============================================================================
# Doc canary: the herdr stall defaults have ONE source each — the
# `HOTLINE_STALL_SECONDS:-<n>` and `HOTLINE_HERDR_STALL_SETTLE:-<n>` fallbacks
# in wait-for-response.sh — and every prose statement of them must agree.
#
# The exit-6 behavior is pinned by herdr-transport-delivery_test.sh. What this
# guards is the NUMBER drifting between the code and the five places that state
# it: the script header, dial/SKILL.md (exit-6 entry + knob list), the README's
# herdr paragraph, and error-recovery.md — the failure docs/compounding.md
# § "Each constant has one source" exists for. (claude-plugins-vw0f)
# =============================================================================
set -u

PASS=0
FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/plugins/hotline/skills/dial/scripts/wait-for-response.sh"
SKILL="$ROOT/plugins/hotline/skills/dial/SKILL.md"
README="$ROOT/plugins/hotline/README.md"
RECOVERY="$ROOT/plugins/hotline/skills/dial/references/error-recovery.md"

pass() { PASS=$((PASS + 1)); echo "ok - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "not ok - $1"; }
expect() { # <description> <file> <ERE>
  if grep -qE "$3" "$2"; then pass "$1"; else fail "$1"; fi
}

# The two sources of truth.
STALL=$(grep -oE 'HOTLINE_STALL_SECONDS:-[0-9]+' "$SCRIPT" | head -1 | grep -oE '[0-9]+$')
SETTLE=$(grep -oE 'HOTLINE_HERDR_STALL_SETTLE:-[0-9]+' "$SCRIPT" | head -1 | grep -oE '[0-9]+$')
[[ -n "$STALL" ]] && pass "wait-for-response.sh declares a numeric HOTLINE_STALL_SECONDS default ($STALL)" \
  || fail "wait-for-response.sh declares a numeric HOTLINE_STALL_SECONDS default"
[[ -n "$SETTLE" ]] && pass "wait-for-response.sh declares a numeric HOTLINE_HERDR_STALL_SETTLE default ($SETTLE)" \
  || fail "wait-for-response.sh declares a numeric HOTLINE_HERDR_STALL_SETTLE default"
STALL="${STALL:-MISSING}"
SETTLE="${SETTLE:-MISSING}"

expect "script header states the same stall default (${STALL})" "$SCRIPT" \
  "HOTLINE_STALL_SECONDS — .*\(default ${STALL},"
expect "script header states the same settle default (${SETTLE})" "$SCRIPT" \
  "^#     \(default ${SETTLE}\)\. Claude Code sometimes auto-continues"
expect "dial/SKILL.md exit-6 entry states the same stall default (${STALL})" "$SKILL" \
  "\`HOTLINE_STALL_SECONDS\` \(default ${STALL}\)"
expect "dial/SKILL.md knob list states the same stall default (${STALL})" "$SKILL" \
  "\(default ${STALL}; \`0\` turns this window off\)"
expect "dial/SKILL.md knob list states the same settle default (${SETTLE})" "$SKILL" \
  "^  \(default ${SETTLE}\)\. Claude Code can auto-continue"
expect "README states the same stall default (${STALL})" "$README" \
  "\`HOTLINE_STALL_SECONDS\` \(default ${STALL}\)"
expect "error-recovery.md states the same stall default (${STALL})" "$RECOVERY" \
  "\`HOTLINE_STALL_SECONDS\` \(default ${STALL}\)"

echo "${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
