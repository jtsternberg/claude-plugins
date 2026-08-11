#!/usr/bin/env bash
# =============================================================================
# Regression tests for session-init.sh — caller-identity resolution.
#
# The script answers from four rungs, in this order, and each rung must win over
# every rung below it:
#
#   1. $HOTLINE_CALLER_SESSION_ID  → cached / override
#   2. $CLAUDE_CODE_SESSION_ID     → cached / native   (validated as a UUID)
#   3. $CODEX_THREAD_ID            → cached / codex
#   4. fingerprint plant + discover → planted / discovered / error  (legacy)
#
# EVERY invocation here goes through si(), which strips all four identity
# variables before setting only the ones the case is about. That is not
# defensive tidiness: this suite normally runs inside a Claude Code session,
# which exports $CLAUDE_CODE_SESSION_ID into every subprocess, so an unsanitized
# run would answer the legacy and codex cases from the harness's own identity
# and pass for the wrong reason.
#
# The one thing no env var can redirect is /tmp/claude-session-<pid>
# (session-fingerprint.sh hardcodes it), so the fake ancestry uses a pid above
# the OS maximum and the file is cleaned up on exit.
# =============================================================================
set -u

PASS=0
FAIL=0
FAILED_CASES=()

HOTLINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SESSION_INIT="$HOTLINE_DIR/scripts/session-init.sh"

FAKE_CLAUDE_PID=990101          # above any real pid, so it can never collide
STRAY_SESSION_CACHE="/tmp/claude-session-${FAKE_CLAUDE_PID}"

SCRATCH=()
trap 'rm -rf "$STRAY_SESSION_CACHE" ${SCRATCH[@]+"${SCRATCH[@]}"}' EXIT

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() {
  FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"
  [[ -n "${2:-}" ]] && echo "    $2"
  return 0
}

check() {  # check <label> <condition-result-rc> <diagnostic>
  if [[ "$2" -eq 0 ]]; then pass "$1"; else fail "$1" "${3:-}"; fi
}

# --- invocation --------------------------------------------------------------

# All four identity variables the script (or the harness around it) can supply.
# Stripped up front so a case only ever sees what it sets itself.
SANITIZE=(env -u HOTLINE_CALLER_SESSION_ID -u CLAUDE_CODE_SESSION_ID
          -u CODEX_THREAD_ID -u SESSION_ID)

si() {  # si <VAR=VALUE>... -- <session-init.sh args>...
  local assigns=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do assigns+=("$1"); shift; done
  [[ $# -gt 0 ]] && shift
  "${SANITIZE[@]}" ${assigns[@]+"${assigns[@]}"} bash "$SESSION_INIT" "$@"
}

# --- stub factories ----------------------------------------------------------

# Fake process ancestry whose claude process is $FAKE_CLAUDE_PID, so the
# fingerprint cache key is stable and lives at a path no real process owns.
# Copied in shape from dial_wrapper_test.sh's make_ps.
make_ps() {
  mkdir -p "$1"
  cat > "$1/ps" <<'EOF'
#!/usr/bin/env bash
FAKE="${FAKE_CLAUDE_PID:?}"
mode=""; pid=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) mode="$2"; shift 2 ;;
    -p) pid="$2"; shift 2 ;;
    *)  shift ;;
  esac
done
case "$mode" in
  comm=) [[ "$pid" == "$FAKE" ]] && echo "claude" || echo "bash" ;;
  ppid=) [[ "$pid" == "$FAKE" ]] && echo "1" || echo "$FAKE" ;;
esac
EOF
  chmod +x "$1/ps"
}

# Ancestry with NO claude in it: every walk terminates at pid 1.
make_orphan_ps() {
  mkdir -p "$1"
  cat > "$1/ps" <<'EOF'
#!/usr/bin/env bash
mode=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) mode="$2"; shift 2 ;;
    *)  shift ;;
  esac
done
case "$mode" in
  comm=) echo "bash" ;;
  ppid=) echo "1" ;;
esac
EOF
  chmod +x "$1/ps"
}

new_env() {   # echoes a fresh scratch root with bin/, home/, work/
  local t
  t=$(mktemp -d /tmp/hotline-session-init-test-XXXXXX)
  mkdir -p "$t/bin" "$t/home" "$t/work"
  echo "$t"
}

UUID_LC="9e1c7a3b-2d4f-4a6b-8c1d-0f2e3a4b5c6d"
UUID_UC="9E1C7A3B-2D4F-4A6B-8C1D-0F2E3A4B5C6D"

echo "session-init.sh identity resolution:"

# ===========================================================================
# 1. Override outranks every other rung.
# ===========================================================================
out=$(si "HOTLINE_CALLER_SESSION_ID=override-1234" \
         "CLAUDE_CODE_SESSION_ID=$UUID_LC" \
         "CODEX_THREAD_ID=codex-thread-9" -- 2>/dev/null)
rc=$?

[[ "$rc" -eq 0 && "$(jq -r .status <<<"$out")" == "cached" \
   && "$(jq -r .caller_kind <<<"$out")" == "override" \
   && "$(jq -r .session_id <<<"$out")" == "override-1234" ]]
check "the explicit override beats a valid native id and a codex thread" $? \
  "rc=$rc out=$out"

# ===========================================================================
# 2. Native: a valid UUID in $CLAUDE_CODE_SESSION_ID resolves in one call.
# ===========================================================================
out=$(si "CLAUDE_CODE_SESSION_ID=$UUID_LC" -- 2>/dev/null)
rc=$?

[[ "$rc" -eq 0 && "$(jq -r .status <<<"$out")" == "cached" \
   && "$(jq -r .caller_kind <<<"$out")" == "native" \
   && "$(jq -r .session_id <<<"$out")" == "$UUID_LC" ]]
check "a lowercase native UUID resolves to cached/native in one call" $? \
  "rc=$rc out=$out"

# Claude Code writes transcripts under the id EXACTLY as given, so the value
# must come back verbatim rather than case-normalized.
out=$(si "CLAUDE_CODE_SESSION_ID=$UUID_UC" -- 2>/dev/null)
[[ "$(jq -r .caller_kind <<<"$out")" == "native" \
   && "$(jq -r .session_id <<<"$out")" == "$UUID_UC" ]]
check "uppercase hex is accepted and returned verbatim" $? "out=$out"

# ===========================================================================
# 3. Native --expanded reconstructs the transcript path from cwd + $HOME.
# ===========================================================================
t=$(new_env); SCRATCH+=("$t")
# Mirror the script's own munge instead of hardcoding it, but compute it from a
# scratch cwd so the result is deterministic wherever the suite runs from.
PROJ=$( cd "$t/work" && pwd | sed 's|[^a-zA-Z0-9-]|-|g' )
EXPECT_PATH="$t/home/.claude/projects/${PROJ}/${UUID_LC}.jsonl"
out=$( cd "$t/work" && si "HOME=$t/home" "CLAUDE_CODE_SESSION_ID=$UUID_LC" \
         -- --expanded 2>/dev/null )
rc=$?

[[ "$rc" -eq 0 && "$(jq -r .transcript_path <<<"$out")" == "$EXPECT_PATH" ]]
check "--expanded builds transcript_path from \$HOME + the munged cwd" $? \
  "rc=$rc expected=$EXPECT_PATH out=$out"

[[ "$(jq -r .project_dir <<<"$out")" == "$(dirname "$EXPECT_PATH")" ]]
check "project_dir is the transcript's directory" $? "out=$out"

# claude_pid is best-effort on this rung (native identity never needed the
# process walk), so the KEY must exist even when the value is empty.
[[ "$(jq -r 'has("claude_pid")' <<<"$out")" == "true" ]]
check "--expanded always carries a claude_pid key, empty or not" $? "out=$out"

[[ "$(jq -r .caller_kind <<<"$out")" == "native" ]]
check "--expanded keeps caller_kind=native" $? "out=$out"

# ===========================================================================
# 4. Codex: $CODEX_THREAD_ID is both the signal and the id.
# ===========================================================================
out=$(si "CODEX_THREAD_ID=0199f0c4-3a11-7c2e-8b55-6d4e9f0a1b2c" -- 2>/dev/null)
rc=$?

[[ "$rc" -eq 0 && "$(jq -r .status <<<"$out")" == "cached" \
   && "$(jq -r .caller_kind <<<"$out")" == "codex" \
   && "$(jq -r .session_id <<<"$out")" == "0199f0c4-3a11-7c2e-8b55-6d4e9f0a1b2c" ]]
check "a codex thread id resolves to cached/codex" $? "rc=$rc out=$out"

# Codex thread ids are not required to be UUIDs, so no validation may be
# applied to them the way it is to the native id.
out=$(si "CODEX_THREAD_ID=thread_abc123" -- 2>/dev/null)
[[ "$(jq -r .session_id <<<"$out")" == "thread_abc123" ]]
check "a non-UUID codex thread id is passed through unvalidated" $? "out=$out"

# ===========================================================================
# 5. A malformed native id falls THROUGH, it does not propagate or error.
# ===========================================================================
# Half-set environments are the real failure mode here: a truncated or empty
# $CLAUDE_CODE_SESSION_ID must never become the caller's identity, and must not
# stop a lower rung from answering.
for bad in "not-a-uuid" "" "${UUID_LC}-extra" "9e1c7a3b-2d4f-4a6b-8c1d-0f2e3a4b5c6"; do
  out=$(si "CLAUDE_CODE_SESSION_ID=$bad" "CODEX_THREAD_ID=codex-fallthrough" \
           -- 2>/dev/null)
  [[ "$(jq -r .caller_kind <<<"$out")" == "codex" \
     && "$(jq -r .session_id <<<"$out")" == "codex-fallthrough" ]]
  check "a malformed native id ('$bad') falls through to codex" $? "out=$out"
done

# ===========================================================================
# 6. The env rungs short-circuit the `discover` subcommand too.
# ===========================================================================
# dial.sh re-runs `session-init.sh discover <fp>` from persisted pending state.
# If a native/codex/override id is available by then, that answer wins — the
# stale fingerprint must not be looked up (or errored on) at all.
out=$(si "CLAUDE_CODE_SESSION_ID=$UUID_LC" -- discover garbage 2>/dev/null)
rc=$?
[[ "$rc" -eq 0 && "$(jq -r .status <<<"$out")" == "cached" \
   && "$(jq -r .caller_kind <<<"$out")" == "native" ]]
check "native identity short-circuits 'discover <garbage>'" $? "rc=$rc out=$out"

out=$(si "CODEX_THREAD_ID=codex-thread-9" -- discover garbage 2>/dev/null)
rc=$?
[[ "$rc" -eq 0 && "$(jq -r .caller_kind <<<"$out")" == "codex" ]]
check "a codex thread id short-circuits 'discover <garbage>'" $? "rc=$rc out=$out"

out=$(si "HOTLINE_CALLER_SESSION_ID=override-1234" -- discover garbage 2>/dev/null)
rc=$?
[[ "$rc" -eq 0 && "$(jq -r .caller_kind <<<"$out")" == "override" ]]
check "the override short-circuits 'discover <garbage>'" $? "rc=$rc out=$out"

# ===========================================================================
# 7. Legacy rung: no identity in the environment → plant a fingerprint.
# ===========================================================================
t=$(new_env); SCRATCH+=("$t")
make_ps "$t/bin"
rm -f "$STRAY_SESSION_CACHE"

out=$( cd "$t/work" && si "PATH=$t/bin:$PATH" "HOME=$t/home" \
         "FAKE_CLAUDE_PID=$FAKE_CLAUDE_PID" -- 2>/dev/null )
rc=$?
fp=$(jq -r '.fingerprint // empty' <<<"$out" 2>/dev/null)

[[ "$rc" -eq 0 && "$(jq -r .status <<<"$out")" == "planted" \
   && "$fp" == SESSION_FINGERPRINT_* ]]
check "a stripped environment with a claude ancestor plants a fingerprint" $? \
  "rc=$rc out=$out"

[[ -n "$(jq -r '.next // empty' <<<"$out")" ]]
check "the planted payload says the discover step is a SEPARATE tool call" $? \
  "out=$out"

# A populated fingerprint cache is the legacy cache HIT — "cached", but with no
# caller_kind, which is what distinguishes it from the native rung above.
echo "abcdef01-2345-4678-8abc-def012345678" > "$STRAY_SESSION_CACHE"
out=$( cd "$t/work" && si "PATH=$t/bin:$PATH" "HOME=$t/home" \
         "FAKE_CLAUDE_PID=$FAKE_CLAUDE_PID" -- 2>/dev/null )
[[ "$(jq -r .status <<<"$out")" == "cached" \
   && "$(jq -r .session_id <<<"$out")" == "abcdef01-2345-4678-8abc-def012345678" \
   && "$(jq -r 'has("caller_kind")' <<<"$out")" == "false" ]]
check "a legacy cache hit is cached WITHOUT a caller_kind" $? "out=$out"
rm -f "$STRAY_SESSION_CACHE"

# ===========================================================================
# 8. No identity anywhere → a hard error, not a silent empty session id.
# ===========================================================================
t=$(new_env); SCRATCH+=("$t")
make_orphan_ps "$t/bin"

out=$( cd "$t/work" && si "PATH=$t/bin:$PATH" "HOME=$t/home" -- 2>/dev/null )
rc=$?

[[ "$rc" -ne 0 && "$(jq -r .status <<<"$out")" == "error" ]]
check "no env identity and no claude ancestor is status=error, nonzero exit" $? \
  "rc=$rc out=$out"

[[ -n "$(jq -r '.message // empty' <<<"$out")" ]]
check "the identity error carries a message" $? "out=$out"

# `discover` with nothing to discover from is an error, not a hang or an empty id.
out=$( cd "$t/work" && si "PATH=$t/bin:$PATH" "HOME=$t/home" -- discover 2>/dev/null )
rc=$?
[[ "$rc" -ne 0 && "$(jq -r .status <<<"$out")" == "error" ]]
check "'discover' with no fingerprint errors instead of guessing" $? \
  "rc=$rc out=$out"

# ===========================================================================
echo ""
echo "Result: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "Failed cases:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
