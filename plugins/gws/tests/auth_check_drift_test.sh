#!/usr/bin/env bash
# Guards the gws plugin against re-growing hand-rolled auth checks.
#
# The bug this exists to prevent shipped in six SKILL.md preflights at once:
#
#   gws auth status 2>&1 | python3 -c '...json.load(sys.stdin)...'
#
# `gws` writes "Using keyring backend: keyring" to stderr on EVERY invocation.
# `2>&1` merged it into the parser's stdin, so the parse failed every time and
# the `|| echo "NOT AUTHENTICATED"` fallback fired for fully authenticated
# accounts. Ten scripts separately hardcoded "Run: gws auth login" as the fix for
# every failure, which is wrong advice when the real problem is that no account
# is selected.
#
# scripts/auth-preflight.sh is now the single source of truth. This suite fails
# if a new caller reintroduces either mistake, in the same spirit as
# tests/parser-drift.test.mjs at the repo root.
#
# Deliberately NOT flagged:
#   - account-*.sh, which legitimately query per-account status while iterating
#     or logging in, and correctly use 2>/dev/null
#   - diagnose-access.sh, whose whole job is reporting raw auth state
#   - auth-preflight.sh itself
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PLUGIN_ROOT"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "      $2"; }

# Files allowed to talk to `gws auth status` directly.
is_exempt() {
  case "${1#./}" in
    scripts/auth-preflight.sh|scripts/account-*.sh|scripts/diagnose-access.sh) return 0 ;;
    */tests/*|tests/*) return 0 ;;
    *) return 1 ;;
  esac
}

# --- 1. nobody merges gws stderr into a parser --------------------------------
# Shell/python only. Markdown is covered by check 2 — prose in README.md and
# SKILL.md legitimately quotes the broken form to explain why it was wrong, and
# an early version of this suite flagged exactly that documentation.
hits=""
while IFS= read -r line; do
  f="${line%%:*}"
  is_exempt "$f" && continue
  # Skip comments — auth-preflight.sh's own header quotes the broken form.
  body="${line#*:*:}"
  [[ "$(printf '%s' "$body" | sed -e 's/^[[:space:]]*//' | cut -c1)" == "#" ]] && continue
  hits="$hits$line"$'\n'
done < <(grep -rn 'gws auth status 2>&1' --include='*.sh' --include='*.py' . 2>/dev/null || true)

if [[ -z "$hits" ]]; then
  ok "no executable line merges 'gws auth status' stderr into stdout"
else
  bad "a caller merges 'gws auth status' stderr into stdout (guaranteed false negative)" \
    "$(printf '%s' "$hits" | tr '\n' ' ')"
fi

# --- 2. no hand-rolled preflight in any SKILL.md ------------------------------
skill_hits=""
for f in skills/*/SKILL.md; do
  # A bare `gws auth status` in a runnable ``` ! block is the preflight slot.
  if grep -qE '^gws auth status' "$f"; then
    skill_hits="$skill_hits $f"
  fi
done
if [[ -z "$skill_hits" ]]; then
  ok "no SKILL.md runs a bare 'gws auth status' as its preflight"
else
  bad "SKILL.md preflight bypasses auth-preflight.sh:" "$skill_hits"
fi

# --- 3. every skill that needs auth actually runs the preflight ---------------
missing=""
for f in skills/*/SKILL.md; do
  skill="$(basename "$(dirname "$f")")"
  # youtube has its own PKCE token flow, not gws auth.
  [[ "$skill" == "youtube" ]] && continue
  grep -q 'auth-preflight.sh' "$f" || missing="$missing $skill"
done
if [[ -z "$missing" ]]; then
  ok "every gws-auth skill invokes auth-preflight.sh"
else
  bad "skill(s) with no auth preflight:" "$missing"
fi

# --- 4. no script hardcodes 'run gws auth login' as the universal fix ---------
# Permitted only as the fallback inside the auth-preflight.sh invocation guard
# in skill-local scripts (they may run from a standalone copy of the skill).
bare=""
while IFS= read -r line; do
  f="${line%%:*}"
  is_exempt "$f" && continue
  # Allowed when the same file defers to auth-preflight.sh first.
  grep -q 'auth-preflight.sh' "$f" && continue
  bare="$bare$line"$'\n'
done < <(grep -rn 'ERROR: gws not authenticated' --include='*.sh' . 2>/dev/null || true)

if [[ -z "$bare" ]]; then
  ok "no script hardcodes 'gws auth login' as the fix for every auth failure"
else
  bad "script(s) give one-size-fits-all auth advice:" \
    "$(printf '%s' "$bare" | tr '\n' ' ')"
fi

# --- 5. the resolver does not delete the user's account selection -------------
# Comments stripped first: account-common.sh documents the removed `rm -f` so the
# reason it went away survives, and an early version of this check flagged that
# explanation as the bug it warns about.
if grep -vE '^[[:space:]]*#' scripts/account-common.sh \
   | grep -qE 'rm -f +"?\$ACTIVE_FILE'; then
  bad "resolve_active_config deletes .active" \
    "destructive on a read path: erases the account selection and the evidence"
else
  ok "account-common.sh never deletes .active"
fi

# account-switch.sh legitimately removes it when switching to 'default'.
if grep -qE 'rm -f +"?\$ACTIVE_FILE' scripts/account-switch.sh; then
  ok "account-switch.sh still clears .active for the 'default' switch"
else
  bad "account-switch.sh no longer clears .active" \
    "switching to 'default' must remove the selection"
fi

echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
