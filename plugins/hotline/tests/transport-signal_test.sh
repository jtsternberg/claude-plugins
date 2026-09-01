#!/usr/bin/env bash
# =============================================================================
# Regression tests for the transport.txt backend signal in the call-dir seam.
#
# The call dir has always been the backend-agnostic contract between hotline's
# launchers and its wait scripts, but the backend itself was only ever INFERRED:
# a surface_ref.txt or workspace_ref.txt meant cmux, and the absence of both meant
# headless. transport.txt states it instead, and these tests pin the three facts
# that make it safe to build on:
#
#   1. Every launcher names its backend. cmux-call-async.sh and
#      cmux-reuse-surface.sh write 'cmux'; headless-call-async.sh writes
#      'headless'. It is written with the call dir, not with the host handle, so
#      it is there for every reader even when the launcher dies before placing a
#      host.
#   2. The wait scripts read it FIRST, and it is COARSE. It picks cmux vs
#      headless; the cmux sub-mode (poll a SURFACE vs poll a WORKSPACE) is still
#      surface_ref.txt vs workspace_ref.txt, exactly as before.
#   3. An ABSENT transport.txt behaves exactly as it did before the signal
#      existed. Legacy call dirs — and hand-staged ones, of which this repo's own
#      suites have many — must dispatch on file presence, unchanged.
#   4. A value OUTSIDE the contract's set ('cmux' | 'herdr' | 'headless') is
#      refused by both waiters, not inferred. Guessing turns a call dir written by
#      a hotline that knows a fourth backend into a poll of the wrong kind of host,
#      or a file-watch for a `done` nobody will write — a --timeout of silence
#      instead of an error. An EMPTY file names nothing and keeps the inference:
#      that is the launcher-died-mid-write case, whose own error.txt is the better
#      diagnosis.
#
# Plus the inertness guard that pays for constraint 2 being coarse: a cmux call
# dir with NO host handle (a launcher that failed placement, which writes
# done+error.txt and hands that dir straight to the waiter) must still report the
# launcher's error.txt, not a `cat` failure from reading a ref that isn't there.
#
# Nothing here touches a real cmux, a real claude, a real control socket, or any
# beads DB: `cmux` and `claude` are PATH stubs, HOME is a sandbox, the socket is
# tests/lib/socket-stub.py, and HOTLINE_CALL_HOME points every call dir at a
# directory this suite owns and wipes.
# =============================================================================
set -u

PASS=0
FAIL=0
SKIP=0
FAILED_CASES=()
SKIPPED_CASES=()

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOTLINE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPTS="$HOTLINE_DIR/skills/dial/scripts"
CMUX_ASYNC="$SCRIPTS/cmux-call-async.sh"
HEADLESS_ASYNC="$SCRIPTS/headless-call-async.sh"
REUSE_SURFACE="$SCRIPTS/cmux-reuse-surface.sh"
WAIT_SESSION="$SCRIPTS/wait-for-session.sh"
WAIT_RESPONSE="$SCRIPTS/wait-for-response.sh"

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() {
  FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"
  [[ -n "${2:-}" ]] && echo "    $2"
}
# A case this environment cannot run. Counted and named in the summary: an
# unrecorded soft-skip makes the pass count environment-dependent, so a machine
# missing a dependency reads as a smaller green run instead of an incomplete one.
skipped() {  # skipped <case> <reason>
  SKIP=$((SKIP + 1)); SKIPPED_CASES+=("$1 — $2"); echo "  – $1 (SKIPPED: $2)"
}

# The real interpreter, captured before anything shims PATH.
REAL_PYTHON3="$(command -v python3)"

# ---------------------------------------------------------------------------
# Poison stubs, in FRONT of PATH for the whole file. Every case installs its own
# `cmux`/`claude`; a case that forgets fails loudly here instead of reaching the
# user's real cmux and opening a live pane. (cmux-call-async_test.sh carries the
# same guard because a missing stub really did launch a `claude --resume` pane on
# every run of that suite.)
# ---------------------------------------------------------------------------
ROOT="$(mktemp -d /tmp/hotline-transport-test-XXXXXX)"
POISON_BIN="$ROOT/poison-bin"
POISON_LOG="$ROOT/violations"
mkdir -p "$POISON_BIN"
for _poison in cmux claude; do
  cat > "$POISON_BIN/$_poison" <<POISON
#!/usr/bin/env bash
echo "$_poison \$*" >> "$POISON_LOG"
echo "TEST BUG: reached the real $_poison — this invocation is missing its PATH stub" >&2
exit 127
POISON
  chmod +x "$POISON_BIN/$_poison"
done
PATH="$POISON_BIN:$PATH"

# Every call dir this suite creates lands here, so none of it is left in /tmp.
export HOTLINE_CALL_HOME="$ROOT/calls"
mkdir -p "$HOTLINE_CALL_HOME"
# A sandbox HOME: transcript-path derivation and any cache write must not touch
# the user's ~/.claude or ~/.hotline.
SANDBOX_HOME="$ROOT/home"
mkdir -p "$SANDBOX_HOME"

# Sourced here, not at its point of use: the harness's contract is that
# socket_stub_cleanup runs from the sourcing suite's EXIT trap, and the trap is
# installed below. Sourcing only defines functions, so a machine with no python3
# reaches this line safely and the stub simply never starts.
# shellcheck source=lib/socket-stub-harness.sh
source "$TESTS_DIR/lib/socket-stub-harness.sh"

# The launchers write their launch script to /tmp/hotline-launch-*, outside the
# call dir. Collect the ones this suite causes and remove them with everything else.
LAUNCH_SCRIPTS=()
reap_launch_script() {  # <call-dir>
  [[ -s "${1:-}/launch_script.txt" ]] && LAUNCH_SCRIPTS+=("$(cat "$1/launch_script.txt")")
  return 0
}
cleanup() {
  local s
  socket_stub_cleanup
  for s in ${LAUNCH_SCRIPTS[@]+"${LAUNCH_SCRIPTS[@]}"}; do rm -f "$s"; done
  rm -rf "$ROOT"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Shared stub builders
# ---------------------------------------------------------------------------

# A cmux that logs every call, serves a fixture screen for read-screen, and
# answers `tree` with one window holding the surface/workspace under test.
make_cmux_stub() {  # <bin-dir>
  mkdir -p "$1"
  cat > "$1/cmux" <<'STUB'
#!/usr/bin/env bash
printf '%q ' "$@" >> "${CMUX_LOG:?CMUX_LOG not set}"; printf '\n' >> "${CMUX_LOG}"
case "$1" in
  new-workspace)
    # The launcher greps `workspace:<n>` out of this, so it has to be here or the
    # detached path fails placement and never writes workspace_ref.txt.
    echo "OK ${CMUX_NEW_WS_REF:-workspace:321}"
    exit 0 ;;
  read-screen)
    if [[ -n "${CMUX_SCREEN:-}" && -f "$CMUX_SCREEN" ]]; then
      cat "$CMUX_SCREEN"
    else
      # A non-empty screen: the detached launcher polls for one before it sends.
      printf '$ \n'
    fi
    exit 0 ;;
  tree)
    jq -nc --arg s "${CMUX_SURF_ID:-SURF}" --arg w "${CMUX_WS_ID:-WS}" \
      '{windows:[{workspaces:[{id:$w,ref:"workspace:1",
        panes:[{surfaces:[{id:$s,ref:"surface:1"}]}]}]}]}'
    exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$1/cmux"
}

# A claude that behaves like `claude -p --output-format stream-json`: one result
# line on stdout, then exits. Enough for headless-call-async.sh's worker to write
# session_id.txt, response.json and done.
make_claude_stub() {  # <bin-dir> <session-id> <response>
  mkdir -p "$1"
  cat > "$1/claude" <<STUB
#!/usr/bin/env bash
cat > /dev/null            # consume the prompt on stdin
jq -nc --arg sid '$2' --arg r '$3' \
  '{type:"result", subtype:"success", session_id:\$sid, result:\$r, num_turns:1}'
STUB
  chmod +x "$1/claude"
}

# The Claude Code REPL banner — signal A for wait-for-session.sh.
banner_screen() {
  printf ' ▐▛███▜▌   Claude Code v2.1.141\n▝▜█████▛▘  Opus 4.7\n'
}

# A screen carrying a terminal STATUS for a given nonce — what wait-for-response.sh
# scrapes in cmux mode when no transcript is derivable.
status_screen() {  # <call-id> <body>
  printf 'bash /tmp/hotline-launch-FAKE\nSTATUS: WORK_IN_PROGRESS call_id=%s\n%s\nSTATUS: WORK_COMPLETE call_id=%s\n' \
    "$1" "$2" "$1"
}

# An idle claude REPL with an empty input box. The live box pads its ❯ with a
# NO-BREAK SPACE; a transcript echo of a prior user turn uses a plain space. Both
# shapes are here so the "which ❯ is the live box" logic is really exercised.
GLYPH=$'\xe2\x9d\xaf'
NBSP=$'\xc2\xa0'
RULE="$(printf '─%.0s' {1..40})"
idle_empty_screen() {
  printf '%s%s Run the earlier thing\n\n%s Baked for 12s\n\n%s\n%s%s\n%s\n' \
    "$GLYPH" " " "✻" "$RULE" "$GLYPH" "$NBSP" "$RULE"
}

# Stage a call dir by hand. transport= '' means "write no transport.txt at all",
# which is the legacy shape every pre-existing suite in this repo stages.
stage_call_dir() {  # <dir> <transport|''> <handle-kind: surface|workspace|none> <ref> [preset]
  local dir="$1" transport="$2" kind="$3" ref="$4" preset="${5:-}"
  mkdir -p "$dir"
  [[ -n "$transport" ]] && echo "$transport" > "$dir/transport.txt"
  case "$kind" in
    surface)   echo "$ref" > "$dir/surface_ref.txt" ;;
    workspace) echo "$ref" > "$dir/workspace_ref.txt" ;;
  esac
  [[ -n "$preset" ]] && echo "$preset" > "$dir/session_id_preset.txt"
  echo false > "$dir/keep_workspace.txt"
  echo "/tmp/hotline-launch-FAKE-$$" > "$dir/launch_script.txt"
  return 0
}

read_transport() { cat "$1/transport.txt" 2>/dev/null || true; }

# ===========================================================================
echo "1. Launchers name their backend in transport.txt:"
# ===========================================================================

# --- cmux-call-async.sh, detached placement (writes workspace_ref.txt) -------
case_dir="$ROOT/launch-cmux-detached"
mkdir -p "$case_dir/bin" "$case_dir/cwd"
make_cmux_stub "$case_dir/bin"
out=$(CMUX_LOG="$case_dir/cmux.log" \
  HOME="$SANDBOX_HOME" PATH="$case_dir/bin:$PATH" \
  bash "$CMUX_ASYNC" --detached --cwd "$case_dir/cwd" --prompt "hello detached" \
  2>"$case_dir/err.txt")
cd_path=$(printf '%s' "$out" | jq -r '.call_dir // empty' 2>/dev/null || true)
reap_launch_script "$cd_path"
if [[ "$(read_transport "$cd_path")" == "cmux" ]]; then
  pass "cmux-call-async.sh (detached) writes transport.txt=cmux"
else
  fail "cmux-call-async.sh (detached) writes transport.txt=cmux" \
       "got: '$(read_transport "$cd_path")' out=$out stderr=$(cat "$case_dir/err.txt")"
fi
# The signal must be in place BEFORE the host handle, so a launcher that dies
# mid-placement still leaves a dir that names its backend.
if [[ -f "$cd_path/transport.txt" && -f "$cd_path/workspace_ref.txt" ]]; then
  pass "…alongside the workspace handle, not instead of it (sub-mode is unchanged)"
else
  fail "…alongside the workspace handle, not instead of it (sub-mode is unchanged)" \
       "call_dir contents: $(ls "$cd_path" 2>/dev/null | tr '\n' ' ')"
fi

# --- cmux-call-async.sh, default side-by-side placement (surface_ref.txt) ----
case_dir="$ROOT/launch-cmux-surface"
mkdir -p "$case_dir/bin" "$case_dir/cwd"
make_cmux_stub "$case_dir/bin"
: > "$case_dir/screen.txt"
cat > "$case_dir/open-side.sh" <<'SIDE'
#!/usr/bin/env bash
printf '%s\n' '{"surface_ref":"surface:777","surface_id":"SURFACE-UUID-777","pane_ref":"pane:55","pane_id":"PANE-UUID-55","workspace_ref":"workspace:5","mode":"new-surface","ready":"ready"}'
SIDE
chmod +x "$case_dir/open-side.sh"
out=$(CMUX_LOG="$case_dir/cmux.log" CMUX_SCREEN="$case_dir/screen.txt" \
  HOME="$SANDBOX_HOME" PATH="$case_dir/bin:$PATH" \
  HOTLINE_OPEN_SIDE_SURFACE="$case_dir/open-side.sh" \
  bash "$CMUX_ASYNC" --cwd "$case_dir/cwd" --prompt "hello surface" \
  2>"$case_dir/err.txt")
cd_path=$(printf '%s' "$out" | jq -r '.call_dir // empty' 2>/dev/null || true)
reap_launch_script "$cd_path"
if [[ "$(read_transport "$cd_path")" == "cmux" ]]; then
  pass "cmux-call-async.sh (side-by-side surface) writes transport.txt=cmux"
else
  fail "cmux-call-async.sh (side-by-side surface) writes transport.txt=cmux" \
       "got: '$(read_transport "$cd_path")' out=$out stderr=$(cat "$case_dir/err.txt")"
fi
if [[ -f "$cd_path/surface_ref.txt" && ! -f "$cd_path/workspace_ref.txt" ]]; then
  pass "…and the surface-vs-workspace sub-mode signal is untouched by it"
else
  fail "…and the surface-vs-workspace sub-mode signal is untouched by it" \
       "call_dir contents: $(ls "$cd_path" 2>/dev/null | tr '\n' ' ')"
fi

# --- cmux-call-async.sh with a placement that FAILS -------------------------
# The launcher returns a call dir carrying done+error.txt and NO host handle.
# transport.txt has to be there anyway — it is written with the dir.
case_dir="$ROOT/launch-cmux-nohost"
mkdir -p "$case_dir/bin" "$case_dir/cwd"
cat > "$case_dir/bin/cmux" <<'STUB'
#!/usr/bin/env bash
printf '%q ' "$@" >> "${CMUX_LOG:?}"; printf '\n' >> "${CMUX_LOG}"
case "$1" in
  new-workspace) echo "cmux: cannot open a workspace here" >&2; exit 1 ;;
  read-screen)   exit 0 ;;
  *)             exit 0 ;;
esac
STUB
chmod +x "$case_dir/bin/cmux"
out=$(CMUX_LOG="$case_dir/cmux.log" HOME="$SANDBOX_HOME" PATH="$case_dir/bin:$PATH" \
  bash "$CMUX_ASYNC" --detached --cwd "$case_dir/cwd" --prompt "doomed" \
  2>"$case_dir/err.txt")
cd_path=$(printf '%s' "$out" | jq -r '.call_dir // empty' 2>/dev/null || true)
if [[ "$(read_transport "$cd_path")" == "cmux" && ! -f "$cd_path/workspace_ref.txt" ]]; then
  pass "a launcher that fails BEFORE placing a host still names its backend"
else
  fail "a launcher that fails BEFORE placing a host still names its backend" \
       "transport='$(read_transport "$cd_path")' contents: $(ls "$cd_path" 2>/dev/null | tr '\n' ' ')"
fi
NOHOST_CALL_DIR="$cd_path"   # reused by the inertness guard in section 4

# --- headless-call-async.sh -------------------------------------------------
case_dir="$ROOT/launch-headless"
mkdir -p "$case_dir/bin" "$case_dir/cwd"
make_claude_stub "$case_dir/bin" "headless-session-1" "headless body"
out=$(HOME="$SANDBOX_HOME" PATH="$case_dir/bin:$PATH" \
  bash "$HEADLESS_ASYNC" --cwd "$case_dir/cwd" --prompt "hello headless" \
  2>"$case_dir/err.txt")
cd_path=$(printf '%s' "$out" | jq -r '.call_dir // empty' 2>/dev/null || true)
if [[ "$(read_transport "$cd_path")" == "headless" ]]; then
  pass "headless-call-async.sh writes transport.txt=headless"
else
  fail "headless-call-async.sh writes transport.txt=headless" \
       "got: '$(read_transport "$cd_path")' out=$out stderr=$(cat "$case_dir/err.txt")"
fi
# Headless places no host, so transport.txt is its only positive backend evidence:
# the inference below it has nothing but an absence to read.
if [[ ! -f "$cd_path/surface_ref.txt" && ! -f "$cd_path/workspace_ref.txt" ]]; then
  pass "…and writes no host handle, so transport.txt is its only positive evidence"
else
  fail "…and writes no host handle, so transport.txt is its only positive evidence" \
       "call_dir contents: $(ls "$cd_path" 2>/dev/null | tr '\n' ' ')"
fi

# --- cmux-reuse-surface.sh (follow-up into a live surface) ------------------
# Driven to the "socket accepted the paste, landing unprovable" outcome, which is
# the one path that KEEPS its call dir (the payload is the only copy left, so
# re-delivering it would run the work order twice). That is what lets us read
# transport.txt back out of it.
if [[ -z "$REAL_PYTHON3" ]]; then
  skipped "cmux-reuse-surface.sh writes transport.txt=cmux" \
          "python3 absent; the control-socket helper needs it"
  skipped "…alongside surface_ref.txt, so the follow-up still dispatches as surface mode" \
          "python3 absent; the control-socket helper needs it"
else
  case_dir="$ROOT/launch-reuse"
  mkdir -p "$case_dir/bin" "$case_dir/home"
  socket_stub_write_responses "$case_dir/responses"
  sock="$(socket_stub_start "$case_dir/socket" "$case_dir/responses/ok.json")"
  make_cmux_stub "$case_dir/bin"
  idle_empty_screen > "$case_dir/screen.txt"
  SURF_UUID="aaaa0000-1111-4111-8111-111111111111"
  out=$(CMUX_LOG="$case_dir/cmux.log" CMUX_SCREEN="$case_dir/screen.txt" \
    CMUX_SURF_ID="$SURF_UUID" CMUX_WS_ID="bbbb0000-2222-4222-8222-222222222222" \
    CMUX_SOCKET_PATH="$sock" HOME="$case_dir/home" \
    HOTLINE_PASTE_CONFIRM_TRIES=2 HOTLINE_PASTE_CONFIRM_SLEEP=0.05 \
    PATH="$case_dir/bin:$PATH" \
    bash "$REUSE_SURFACE" --surface "$SURF_UUID" --cwd "$case_dir/callee-cwd" \
      --session "cccc0000-3333-4333-8333-333333333333" \
      --prompt "a follow-up nobody can confirm" 2>&1)
  cd_path=$(printf '%s' "$out" | jq -r '.call_dir // empty' 2>/dev/null || true)
  if [[ "$(read_transport "$cd_path")" == "cmux" ]]; then
    pass "cmux-reuse-surface.sh writes transport.txt=cmux"
  else
    fail "cmux-reuse-surface.sh writes transport.txt=cmux" \
         "got: '$(read_transport "$cd_path")' out=$out"
  fi
  if [[ -f "$cd_path/surface_ref.txt" ]]; then
    pass "…alongside surface_ref.txt, so the follow-up still dispatches as surface mode"
  else
    fail "…alongside surface_ref.txt, so the follow-up still dispatches as surface mode" \
         "call_dir contents: $(ls "$cd_path" 2>/dev/null | tr '\n' ' ')"
  fi
fi

# ===========================================================================
echo ""
echo "2. The wait scripts read transport.txt first:"
# ===========================================================================

# --- transport.txt=cmux + workspace handle → poll the cmux WORKSPACE ---------
case_dir="$ROOT/wait-cmux-workspace"
mkdir -p "$case_dir/bin"
make_cmux_stub "$case_dir/bin"
banner_screen > "$case_dir/screen.txt"
cd_path="$case_dir/call"
stage_call_dir "$cd_path" cmux workspace "workspace:99" "cmux-preset-1"
out=$(CMUX_LOG="$case_dir/cmux.log" CMUX_SCREEN="$case_dir/screen.txt" \
  HOME="$SANDBOX_HOME" PATH="$case_dir/bin:$PATH" \
  bash "$WAIT_SESSION" "$cd_path" --timeout 5 2>"$case_dir/err.txt")
rc=$?
if [[ $rc -eq 0 && "$out" == "cmux-preset-1" ]]; then
  pass "transport.txt=cmux + workspace handle: boot-waits on cmux and promotes the preset"
else
  fail "transport.txt=cmux + workspace handle: boot-waits on cmux and promotes the preset" \
       "rc=$rc stdout=$out stderr=$(cat "$case_dir/err.txt")"
fi
if grep -q -- '--workspace workspace:99' "$case_dir/cmux.log" 2>/dev/null; then
  pass "…and reads the WORKSPACE (transport.txt did not flatten the cmux sub-mode)"
else
  fail "…and reads the WORKSPACE (transport.txt did not flatten the cmux sub-mode)" \
       "cmux calls: $(cat "$case_dir/cmux.log" 2>/dev/null || echo NONE)"
fi

# --- transport.txt=cmux + surface handle → poll the cmux SURFACE -------------
case_dir="$ROOT/wait-cmux-surface"
mkdir -p "$case_dir/bin"
make_cmux_stub "$case_dir/bin"
banner_screen > "$case_dir/screen.txt"
cd_path="$case_dir/call"
stage_call_dir "$cd_path" cmux surface "surface:777" "cmux-preset-2"
out=$(CMUX_LOG="$case_dir/cmux.log" CMUX_SCREEN="$case_dir/screen.txt" \
  HOME="$SANDBOX_HOME" PATH="$case_dir/bin:$PATH" \
  bash "$WAIT_SESSION" "$cd_path" --timeout 5 2>"$case_dir/err.txt")
rc=$?
if [[ $rc -eq 0 && "$out" == "cmux-preset-2" ]] \
   && grep -q -- '--surface surface:777' "$case_dir/cmux.log" 2>/dev/null; then
  pass "transport.txt=cmux + surface handle: still reads the SURFACE, not a workspace"
else
  fail "transport.txt=cmux + surface handle: still reads the SURFACE, not a workspace" \
       "rc=$rc stdout=$out cmux calls: $(cat "$case_dir/cmux.log" 2>/dev/null || echo NONE)"
fi

# --- transport.txt=headless → the file-watch path, and cmux is never touched --
case_dir="$ROOT/wait-headless"
mkdir -p "$case_dir/bin"
make_cmux_stub "$case_dir/bin"
cd_path="$case_dir/call"
stage_call_dir "$cd_path" headless none ""
echo "headless-session-2" > "$cd_path/session_id.txt"
out=$(CMUX_LOG="$case_dir/cmux.log" HOME="$SANDBOX_HOME" PATH="$case_dir/bin:$PATH" \
  bash "$WAIT_SESSION" "$cd_path" --timeout 5 2>"$case_dir/err.txt")
rc=$?
if [[ $rc -eq 0 && "$out" == "headless-session-2" ]]; then
  pass "transport.txt=headless: wait-for-session takes the file-watch path"
else
  fail "transport.txt=headless: wait-for-session takes the file-watch path" \
       "rc=$rc stdout=$out stderr=$(cat "$case_dir/err.txt")"
fi
if [[ ! -s "$case_dir/cmux.log" ]]; then
  pass "…without making a single cmux call"
else
  fail "…without making a single cmux call" "cmux calls: $(cat "$case_dir/cmux.log")"
fi

# --- transport.txt=headless BEATS a stray host handle ------------------------
# The branch where the explicit signal actually decides something the inference
# could not: a dir that says headless is headless even if a surface handle is
# lying around, so a future backend cannot be misread as cmux by a leftover file.
case_dir="$ROOT/wait-headless-stray-handle"
mkdir -p "$case_dir/bin"
make_cmux_stub "$case_dir/bin"
banner_screen > "$case_dir/screen.txt"
cd_path="$case_dir/call"
stage_call_dir "$cd_path" headless surface "surface:stray"
echo "headless-session-3" > "$cd_path/session_id.txt"
out=$(CMUX_LOG="$case_dir/cmux.log" CMUX_SCREEN="$case_dir/screen.txt" \
  HOME="$SANDBOX_HOME" PATH="$case_dir/bin:$PATH" \
  bash "$WAIT_SESSION" "$cd_path" --timeout 5 2>"$case_dir/err.txt")
rc=$?
if [[ $rc -eq 0 && "$out" == "headless-session-3" && ! -s "$case_dir/cmux.log" ]]; then
  pass "transport.txt=headless outranks a stray surface_ref.txt (no cmux polling)"
else
  fail "transport.txt=headless outranks a stray surface_ref.txt (no cmux polling)" \
       "rc=$rc stdout=$out cmux calls: $(cat "$case_dir/cmux.log" 2>/dev/null || echo NONE)"
fi

# --- wait-for-response.sh honors it too -------------------------------------
case_dir="$ROOT/resp-cmux-surface"
mkdir -p "$case_dir/bin"
make_cmux_stub "$case_dir/bin"
cd_path="$case_dir/call"
stage_call_dir "$cd_path" cmux surface "surface:777" "resp-preset-1"
echo "resp-preset-1" > "$cd_path/session_id.txt"
echo "nonce00000000aa" > "$cd_path/call_id.txt"
status_screen "nonce00000000aa" "the answer is 42" > "$case_dir/screen.txt"
out=$(CMUX_LOG="$case_dir/cmux.log" CMUX_SCREEN="$case_dir/screen.txt" \
  HOME="$SANDBOX_HOME" PATH="$case_dir/bin:$PATH" HOTLINE_POLL_SLEEP=0 \
  bash "$WAIT_RESPONSE" "$cd_path" --timeout 10 2>"$case_dir/err.txt")
rc=$?
resp=$(printf '%s' "$out" | jq -r '.response' 2>/dev/null || true)
if [[ $rc -eq 0 && "$resp" == *"the answer is 42"* ]] \
   && grep -q -- '--surface surface:777' "$case_dir/cmux.log" 2>/dev/null; then
  pass "transport.txt=cmux: wait-for-response scrapes the surface for STATUS"
else
  fail "transport.txt=cmux: wait-for-response scrapes the surface for STATUS" \
       "rc=$rc resp=$(printf '%q' "$resp") stderr=$(cat "$case_dir/err.txt")"
fi

case_dir="$ROOT/resp-headless"
mkdir -p "$case_dir/bin"
make_cmux_stub "$case_dir/bin"
cd_path="$case_dir/call"
stage_call_dir "$cd_path" headless none ""
echo "resp-headless-1" > "$cd_path/session_id.txt"
echo '{"session_id":"resp-headless-1","response":"headless body"}' > "$cd_path/response.json"
touch "$cd_path/done"
out=$(CMUX_LOG="$case_dir/cmux.log" HOME="$SANDBOX_HOME" PATH="$case_dir/bin:$PATH" \
  HOTLINE_POLL_SLEEP=0 bash "$WAIT_RESPONSE" "$cd_path" --timeout 5 2>"$case_dir/err.txt")
rc=$?
if [[ $rc -eq 0 && "$(printf '%s' "$out" | jq -r '.response' 2>/dev/null)" == "headless body" ]] \
   && [[ ! -s "$case_dir/cmux.log" ]]; then
  pass "transport.txt=headless: wait-for-response reads response.json, no cmux calls"
else
  fail "transport.txt=headless: wait-for-response reads response.json, no cmux calls" \
       "rc=$rc stdout=$out cmux calls: $(cat "$case_dir/cmux.log" 2>/dev/null || echo NONE)"
fi

# ===========================================================================
echo ""
echo "3. A call dir with NO transport.txt dispatches exactly as it always did:"
# ===========================================================================

# --- legacy workspace handle → cmux workspace mode --------------------------
case_dir="$ROOT/legacy-workspace"
mkdir -p "$case_dir/bin"
make_cmux_stub "$case_dir/bin"
banner_screen > "$case_dir/screen.txt"
cd_path="$case_dir/call"
stage_call_dir "$cd_path" '' workspace "workspace:88" "legacy-preset-1"
if [[ ! -f "$cd_path/transport.txt" ]]; then
  pass "the legacy fixture really has no transport.txt (guard on the guard)"
else
  fail "the legacy fixture really has no transport.txt (guard on the guard)"
fi
out=$(CMUX_LOG="$case_dir/cmux.log" CMUX_SCREEN="$case_dir/screen.txt" \
  HOME="$SANDBOX_HOME" PATH="$case_dir/bin:$PATH" \
  bash "$WAIT_SESSION" "$cd_path" --timeout 5 2>"$case_dir/err.txt")
rc=$?
if [[ $rc -eq 0 && "$out" == "legacy-preset-1" ]] \
   && grep -q -- '--workspace workspace:88' "$case_dir/cmux.log" 2>/dev/null; then
  pass "legacy: workspace_ref.txt alone still means cmux WORKSPACE mode"
else
  fail "legacy: workspace_ref.txt alone still means cmux WORKSPACE mode" \
       "rc=$rc stdout=$out cmux calls: $(cat "$case_dir/cmux.log" 2>/dev/null || echo NONE)"
fi

# --- legacy surface handle → cmux surface mode ------------------------------
case_dir="$ROOT/legacy-surface"
mkdir -p "$case_dir/bin"
make_cmux_stub "$case_dir/bin"
banner_screen > "$case_dir/screen.txt"
cd_path="$case_dir/call"
stage_call_dir "$cd_path" '' surface "surface:888" "legacy-preset-2"
out=$(CMUX_LOG="$case_dir/cmux.log" CMUX_SCREEN="$case_dir/screen.txt" \
  HOME="$SANDBOX_HOME" PATH="$case_dir/bin:$PATH" \
  bash "$WAIT_SESSION" "$cd_path" --timeout 5 2>"$case_dir/err.txt")
rc=$?
if [[ $rc -eq 0 && "$out" == "legacy-preset-2" ]] \
   && grep -q -- '--surface surface:888' "$case_dir/cmux.log" 2>/dev/null; then
  pass "legacy: surface_ref.txt alone still means cmux SURFACE mode"
else
  fail "legacy: surface_ref.txt alone still means cmux SURFACE mode" \
       "rc=$rc stdout=$out cmux calls: $(cat "$case_dir/cmux.log" 2>/dev/null || echo NONE)"
fi

# --- legacy, no handle at all → headless -----------------------------------
case_dir="$ROOT/legacy-headless"
mkdir -p "$case_dir/bin"
make_cmux_stub "$case_dir/bin"
cd_path="$case_dir/call"
stage_call_dir "$cd_path" '' none ""
echo "legacy-session-3" > "$cd_path/session_id.txt"
out=$(CMUX_LOG="$case_dir/cmux.log" HOME="$SANDBOX_HOME" PATH="$case_dir/bin:$PATH" \
  bash "$WAIT_SESSION" "$cd_path" --timeout 5 2>"$case_dir/err.txt")
rc=$?
if [[ $rc -eq 0 && "$out" == "legacy-session-3" && ! -s "$case_dir/cmux.log" ]]; then
  pass "legacy: no handle at all still means headless (file-watch, no cmux)"
else
  fail "legacy: no handle at all still means headless (file-watch, no cmux)" \
       "rc=$rc stdout=$out cmux calls: $(cat "$case_dir/cmux.log" 2>/dev/null || echo NONE)"
fi

# --- legacy, wait-for-response, no handle at all → headless ----------------
case_dir="$ROOT/legacy-resp-headless"
mkdir -p "$case_dir/bin"
make_cmux_stub "$case_dir/bin"
cd_path="$case_dir/call"
stage_call_dir "$cd_path" '' none ""
echo "legacy-session-4" > "$cd_path/session_id.txt"
echo '{"session_id":"legacy-session-4","response":"legacy body"}' > "$cd_path/response.json"
touch "$cd_path/done"
out=$(CMUX_LOG="$case_dir/cmux.log" HOME="$SANDBOX_HOME" PATH="$case_dir/bin:$PATH" \
  HOTLINE_POLL_SLEEP=0 bash "$WAIT_RESPONSE" "$cd_path" --timeout 5 2>"$case_dir/err.txt")
rc=$?
if [[ $rc -eq 0 && "$(printf '%s' "$out" | jq -r '.response' 2>/dev/null)" == "legacy body" ]] \
   && [[ ! -s "$case_dir/cmux.log" ]]; then
  pass "legacy: wait-for-response with no handle still reads response.json"
else
  fail "legacy: wait-for-response with no handle still reads response.json" \
       "rc=$rc stdout=$out cmux calls: $(cat "$case_dir/cmux.log" 2>/dev/null || echo NONE)"
fi

# ===========================================================================
echo ""
echo "4. Inertness guard — a cmux call dir with no host handle:"
# ===========================================================================
# transport.txt is written with the call dir, BEFORE a host is placed, so a
# launcher that fails placement hands the waiter a dir that says 'cmux' and has no
# ref file. transport.txt is a coarse selector, not a promise that a host exists:
# such a dir must keep taking the file-watch path, because that is the path whose
# check_early_fail reports the launcher's own error.txt. Reading a ref that isn't
# there would replace a real diagnosis with `cat: no such file`.
case_dir="$ROOT/inert-nohost"
mkdir -p "$case_dir/bin"
make_cmux_stub "$case_dir/bin"
cd_path="$case_dir/call"
stage_call_dir "$cd_path" cmux none ""
echo "cmux: cannot open a workspace here" > "$cd_path/error.txt"
touch "$cd_path/done"
out=$(CMUX_LOG="$case_dir/cmux.log" HOME="$SANDBOX_HOME" PATH="$case_dir/bin:$PATH" \
  bash "$WAIT_SESSION" "$cd_path" --timeout 5 2>"$case_dir/err.txt")
rc=$?
if [[ $rc -ne 0 ]] && grep -q "cannot open a workspace here" "$case_dir/err.txt"; then
  pass "handle-less cmux dir reports the LAUNCHER's error.txt, not a ref-read failure"
else
  fail "handle-less cmux dir reports the LAUNCHER's error.txt, not a ref-read failure" \
       "rc=$rc stderr=$(cat "$case_dir/err.txt")"
fi
# And the real dir the failing launcher produced in section 1 behaves the same —
# a fixture that drifted from what the launcher actually writes would hide this.
if [[ -n "${NOHOST_CALL_DIR:-}" && -f "$NOHOST_CALL_DIR/done" && -f "$NOHOST_CALL_DIR/error.txt" ]]; then
  out=$(CMUX_LOG="$case_dir/cmux2.log" HOME="$SANDBOX_HOME" PATH="$case_dir/bin:$PATH" \
    bash "$WAIT_SESSION" "$NOHOST_CALL_DIR" --timeout 5 2>"$case_dir/err2.txt")
  rc=$?
  if [[ $rc -ne 0 && -s "$case_dir/err2.txt" ]] \
     && ! grep -qi 'no such file' "$case_dir/err2.txt"; then
    pass "…and the same holds for the dir the real launcher left behind"
  else
    fail "…and the same holds for the dir the real launcher left behind" \
         "rc=$rc stderr=$(cat "$case_dir/err2.txt")"
  fi
else
  fail "…and the same holds for the dir the real launcher left behind" \
       "the failing launcher in section 1 left no done+error.txt to re-check"
fi

# ===========================================================================
echo ""
echo "5. A transport.txt value outside the contract's set is refused, not guessed:"
# ===========================================================================
# The failure mode this buys: a call dir written by a hotline that knows a fourth
# backend used to fall through to the host-handle inference, so it was polled as
# whatever kind of host happened to be named in it — or file-watched for a `done`
# nobody would write, which is a 30-minute silence rather than an error. Both
# waiters now refuse the dir and say which value they could not read.
UNKNOWN="quantum-foam"

# --- wait-for-session.sh ----------------------------------------------------
# Staged WITH a workspace handle on purpose: that handle is exactly what the old
# fall-through would have polled, so an empty cmux log is the proof it did not.
case_dir="$ROOT/unknown-session"
mkdir -p "$case_dir/bin"
make_cmux_stub "$case_dir/bin"
banner_screen > "$case_dir/screen.txt"
cd_path="$case_dir/call"
stage_call_dir "$cd_path" "$UNKNOWN" workspace "workspace:66" "unknown-preset-1"
out=$(CMUX_LOG="$case_dir/cmux.log" CMUX_SCREEN="$case_dir/screen.txt" \
  HOME="$SANDBOX_HOME" PATH="$case_dir/bin:$PATH" \
  bash "$WAIT_SESSION" "$cd_path" --timeout 5 2>"$case_dir/err.txt")
rc=$?
if [[ $rc -ne 0 ]]; then
  pass "wait-for-session.sh refuses an unknown transport instead of inferring cmux"
else
  fail "wait-for-session.sh refuses an unknown transport instead of inferring cmux" \
       "rc=$rc stdout=$out cmux calls: $(cat "$case_dir/cmux.log" 2>/dev/null || echo NONE)"
fi
if grep -q "$UNKNOWN" "$case_dir/err.txt" 2>/dev/null \
   && grep -q 'cmux herdr headless' "$case_dir/err.txt" 2>/dev/null; then
  pass "…naming the value it could not read and the set it knows"
else
  fail "…naming the value it could not read and the set it knows" \
       "stderr=$(cat "$case_dir/err.txt" 2>/dev/null || echo EMPTY)"
fi
if [[ ! -s "$case_dir/cmux.log" ]]; then
  pass "…without polling the workspace handle the old fall-through would have used"
else
  fail "…without polling the workspace handle the old fall-through would have used" \
       "cmux calls: $(cat "$case_dir/cmux.log")"
fi

# --- wait-for-response.sh ---------------------------------------------------
# Both waiters read the same file through the same helper, so both must refuse.
case_dir="$ROOT/unknown-response"
mkdir -p "$case_dir/bin"
make_cmux_stub "$case_dir/bin"
cd_path="$case_dir/call"
stage_call_dir "$cd_path" "$UNKNOWN" surface "surface:66" "unknown-preset-2"
echo "unknown-preset-2" > "$cd_path/session_id.txt"
echo "nonce00000000bb" > "$cd_path/call_id.txt"
status_screen "nonce00000000bb" "an answer nobody should read" > "$case_dir/screen.txt"
out=$(CMUX_LOG="$case_dir/cmux.log" CMUX_SCREEN="$case_dir/screen.txt" \
  HOME="$SANDBOX_HOME" PATH="$case_dir/bin:$PATH" HOTLINE_POLL_SLEEP=0 \
  bash "$WAIT_RESPONSE" "$cd_path" --timeout 5 2>"$case_dir/err.txt")
rc=$?
if [[ $rc -ne 0 ]] && grep -q "$UNKNOWN" "$case_dir/err.txt" 2>/dev/null \
   && [[ ! -s "$case_dir/cmux.log" ]]; then
  pass "wait-for-response.sh refuses it too, and scrapes no surface on the way out"
else
  fail "wait-for-response.sh refuses it too, and scrapes no surface on the way out" \
       "rc=$rc stdout=$out stderr=$(cat "$case_dir/err.txt" 2>/dev/null || echo EMPTY)" \
       "cmux calls: $(cat "$case_dir/cmux.log" 2>/dev/null || echo NONE)"
fi

# --- 'herdr' is IN the set, and must stay readable here ---------------------
# The set is the spec's, not this tree's. Phase 1 writes 'herdr'; a Phase 0
# waiter that refused it would turn this guard into the thing that breaks Phase 1.
case_dir="$ROOT/known-herdr"
mkdir -p "$case_dir/bin"
make_cmux_stub "$case_dir/bin"
cd_path="$case_dir/call"
stage_call_dir "$cd_path" herdr none ""
echo "herdr-session-1" > "$cd_path/session_id.txt"
out=$(CMUX_LOG="$case_dir/cmux.log" HOME="$SANDBOX_HOME" PATH="$case_dir/bin:$PATH" \
  bash "$WAIT_SESSION" "$cd_path" --timeout 5 2>"$case_dir/err.txt")
rc=$?
if [[ $rc -eq 0 && "$out" == "herdr-session-1" ]]; then
  pass "transport.txt=herdr is accepted, not refused (Phase 1's value is readable)"
else
  fail "transport.txt=herdr is accepted, not refused (Phase 1's value is readable)" \
       "rc=$rc stdout=$out stderr=$(cat "$case_dir/err.txt")"
fi

# --- an EMPTY transport.txt is 'names nothing', not 'names something wrong' --
# A launcher killed between creating the call dir and writing the value leaves
# exactly this. Refusing it would replace the launcher's own diagnosis with ours,
# so it takes the legacy inference — the same carve-out the handle-less-cmux guard
# in section 4 exists to protect.
case_dir="$ROOT/empty-transport"
mkdir -p "$case_dir/bin"
make_cmux_stub "$case_dir/bin"
banner_screen > "$case_dir/screen.txt"
cd_path="$case_dir/call"
stage_call_dir "$cd_path" '' workspace "workspace:65" "empty-preset-1"
: > "$cd_path/transport.txt"
out=$(CMUX_LOG="$case_dir/cmux.log" CMUX_SCREEN="$case_dir/screen.txt" \
  HOME="$SANDBOX_HOME" PATH="$case_dir/bin:$PATH" \
  bash "$WAIT_SESSION" "$cd_path" --timeout 5 2>"$case_dir/err.txt")
rc=$?
if [[ $rc -eq 0 && "$out" == "empty-preset-1" ]] \
   && grep -q -- '--workspace workspace:65' "$case_dir/cmux.log" 2>/dev/null; then
  pass "an empty transport.txt falls through to the legacy inference, unrefused"
else
  fail "an empty transport.txt falls through to the legacy inference, unrefused" \
       "rc=$rc stdout=$out stderr=$(cat "$case_dir/err.txt") cmux calls: $(cat "$case_dir/cmux.log" 2>/dev/null || echo NONE)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "Result: $PASS passed, $FAIL failed, $SKIP skipped"
if [[ $SKIP -gt 0 ]]; then
  echo ""
  echo "Skipped cases:"
  for c in "${SKIPPED_CASES[@]}"; do echo "  - $c"; done
fi
if [[ -s "$POISON_LOG" ]]; then
  echo ""
  echo "TEST BUG: a case reached a real binary (missing PATH stub):"
  cat "$POISON_LOG"
  exit 1
fi
if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "Failed cases:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
