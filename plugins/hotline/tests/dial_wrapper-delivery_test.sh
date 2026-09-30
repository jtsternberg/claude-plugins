#!/usr/bin/env bash
# =============================================================================
# dial.sh wrapper regression tests — delivery: capability preflight, the deliver
# stage, the prompt file, unconfirmed pastes, the argv audit, and the boot signal
# and budget.
#
# One shard of the dial_wrapper suite. The stubs, sockets and scratch-env
# helpers live in lib/dial-wrapper-harness.sh; the sibling
# dial_wrapper-*_test.sh shards hold the other sections.
# =============================================================================
set -u
FAKE_CLAUDE_PID=990004
# shellcheck source=lib/dial-wrapper-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/dial-wrapper-harness.sh"

echo "dial.sh wrapper regression:"

# ===========================================================================
# Capability preflight: a cmux with no terminal.paste cannot carry a call.
#
# Every cmux delivery is a terminal.paste now, first contact included, so there is
# no paste-free cmux path left to degrade to. The dial says so and goes headless
# rather than resurrecting the argv launch this rework removed — a silent fallback
# tier that reopened the leak would give back exactly what was paid for.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_claude "$t/bin"
FAKE_CLAUDE_SESSION_ID="caaaaaaa-cccc-4ccc-8ccc-cccccccccccc"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  CMUX_SOCKET_PATH="$NO_PASTE_SOCK" \
  HOTLINE_CALLER_SESSION_ID="caller-cap" HOTLINE_PENDING_DIR="$t/pending" \
  FAKE_CLAUDE_SESSION_ID="$FAKE_CLAUDE_SESSION_ID" \
  bash "$DIAL" --target "$t/target" --mode work_order --label "probe label" \
    --prompt "no paste available here" --boot-timeout 5 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"

jq -e '.fallbacks | map(startswith("terminal-paste-unavailable→headless")) | any' <<<"$out" >/dev/null 2>&1
check "a cmux without terminal.paste records the capability miss as a fallback" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

[[ "$(jq -r .status <<<"$out")" == "connected" && "$(jq -r .transport <<<"$out")" == "headless" ]]
check "…and the call still completes, over the headless transport" $? "out=$out"

[[ ! -s "$SOCKROOT/nopaste/requests.log" ]] || \
  ! grep -qF '"terminal.paste"' "$SOCKROOT/nopaste/requests.log"
check "…and no paste is attempted against a cmux that cannot do it" $? \
  "$(cat "$SOCKROOT/nopaste/requests.log" 2>/dev/null)"

# ===========================================================================
# A prompt that never lands is stage `deliver` — an ERROR, not a fallback.
#
# The surface is open and its REPL is live, but it was never told anything.
# Reporting "connected" would leave the caller polling for a response to a message
# that does not exist, which is the failure mode the confirmation exists to catch.
# The recovery line must warn against a blind re-dial: the paste can land just
# after the confirmation window, and re-dialling then double-delivers.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  CMUX_SOCKET_PATH="$NOECHO_SOCK" SOCK_ECHO_FILE="" \
  HOTLINE_CALLER_SESSION_ID="caller-undelivered" HOTLINE_PENDING_DIR="$t/pending" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" \
  bash "$DIAL" --target "$t/target" --mode work_order --label "probe label" \
    --prompt "this one never lands" --boot-timeout 5 2>"$t/err.txt")
rc=$?
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"

[[ "$rc" -eq 1 && "$(jq -r .status <<<"$out")" == "error" \
   && "$(jq -r .stage <<<"$out")" == "deliver" ]]
check "a prompt that cannot be confirmed is an error at stage 'deliver'" $? \
  "rc=$rc out=$out"

grep -qi 'never landed' <<<"$(jq -r '.detail // empty' <<<"$out")"
check "…and the detail says the REPL booted but the prompt never landed" $? "out=$out"

grep -qi 'not silently re-dial' <<<"$(jq -r '.recovery // empty' <<<"$out")"
check "…and the recovery warns against a blind re-dial (double-delivery)" $? "out=$out"

# The prompt stays on disk: it is the only copy, and the caller may want it.
[[ -s "$call_dir/pending_paste.md" ]]
check "…and pending_paste.md is left in place for recovery" $? \
  "call_dir contents: $(ls -A "$call_dir" 2>/dev/null | tr '\n' ' ')"

# ===========================================================================
# The prompt is written to a 0600 temp file and cleaned up, even when the caller
# passed --prompt. Handing the launchers a file is what keeps the payload out of
# every argv downstream (claude-plugins-86ka); leaving the file behind would
# undo the point of the 0600.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
# A python3 shim in front of the socket helper: records its argv and the mode of
# the file it was handed, so "the payload travels as an owner-only path, never as
# an argument" is asserted rather than assumed.
write_python3_shim "$t/bin2" "$t/python-argv.log"
# The payload carries this run's PID, so the leak check below can tell THIS dial's
# temp file apart from one any other process left in the same shared directory.
ARGV_SENTINEL="PROMPT-ON-ARGV-SENTINEL-$$"
out=$(PATH="$t/bin2:$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-argv" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order --label "probe label" \
    --prompt "$ARGV_SENTINEL" --boot-timeout 5 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"

grep -q -- '--payload-file' "$t/python-argv.log" 2>/dev/null
check "the socket helper is handed a FILE path, not the payload" $? \
  "$(cat "$t/python-argv.log" 2>/dev/null)"

! grep -q 'PROMPT-ON-ARGV-SENTINEL' "$t/python-argv.log" 2>/dev/null
check "no payload text appears in the helper's argv" $? \
  "$(cat "$t/python-argv.log" 2>/dev/null)"

grep -q 'PAYLOAD_MODE 600' "$t/python-argv.log" 2>/dev/null
check "the file the helper reads is owner-only (0600)" $? \
  "$(grep PAYLOAD_MODE "$t/python-argv.log" 2>/dev/null)"

# ITS OWN FILE, found by its payload — not a count of the shared namespace.
# dial.sh mktemps into /tmp, which is MACHINE-global: any other hotline session
# dialing inside this window pushed the count up and failed this assertion, three
# times over (claude-plugins-iyau). Nothing but this dial wrote this sentinel, so a
# survivor bearing it is a real leak and nothing else can be mistaken for one.
LEAKED=""
for f in /tmp/hotline-prompt-*; do
  [[ -f "$f" ]] || continue
  grep -q "$ARGV_SENTINEL" "$f" 2>/dev/null && LEAKED+="$f "
done
[[ -z "$LEAKED" ]]
check "the dial's own prompt temp file does not outlive the dial" $? \
  "surviving files carrying this dial's payload: $LEAKED"

# ===========================================================================
# AN UNCONFIRMED FOLLOW-UP PASTE MUST NOT BECOME A SECOND DELIVERY.
#
# The reuse path pastes, cannot confirm, and used to answer with fallback:fresh —
# which dial.sh serves by opening a NEW surface and re-delivering the SAME prompt
# into a --resume of the SAME session. A payload that actually landed then runs
# TWICE. It reaches this state on its own: a previous exchange leaves
# "[Pasted text +N lines]" in the viewport, the recency baseline correctly discards
# that marker as stale, a new large paste renders as the same placeholder so the
# nonce is not on screen, and the transcript tier misses inside its poll budget.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
# A live REPL with a stale placeholder already on screen, and a socket that accepts
# the paste but echoes nothing back — so confirmation has nothing fresh to find.
printf 'some earlier output\n\xe2\x9d\xaf\xc2\xa0\n[Pasted text +40 lines]\nClaude Code v2.1.221\n' \
  > "$t/screen.txt"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-dup" --session "dddddddd-dddd-4ddd-8ddd-dddddddddddd" \
  --mode work_order --surface "SURFACE-UUID-777"
printf 'DUPLICATE-DELIVERY-SENTINEL work order body\nsecond line\n' > "$t/msg.txt"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  CMUX_SOCKET_PATH="$NOECHO_SOCK" SOCK_ECHO_FILE="" \
  HOTLINE_CALLER_SESSION_ID="caller-dup" HOTLINE_PENDING_DIR="$t/pending" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" \
  bash "$DIAL" --target "$t/target" --mode work_order --label "probe label" \
    --prompt-file "$t/msg.txt" --boot-timeout 5 2>"$t/err.txt")
rc=$?
DUP_CALL_DIR=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$DUP_CALL_DIR" ]] && note_leak "$DUP_CALL_DIR"

[[ "$rc" -eq 1 && "$(jq -r .status <<<"$out")" == "error" \
   && "$(jq -r .stage <<<"$out")" == "deliver" ]]
check "an unconfirmed follow-up paste is stage 'deliver', not a fresh fallback" $? \
  "rc=$rc out=$out"

# THE POINT: no second surface was opened, so the prompt was not delivered twice.
[[ ! -f "$t/side_log" ]] || [[ -z "$(cat "$t/side_log" 2>/dev/null)" ]]
check "…and NO fresh surface was opened (the payload is not delivered twice)" $? \
  "side_log=$(cat "$t/side_log" 2>/dev/null)"
[[ "$(grep -c 'DUPLICATE-DELIVERY-SENTINEL' "$SOCKROOT/noecho/requests.log" 2>/dev/null || echo 0)" -eq 1 ]]
check "…and the payload crossed the socket exactly ONCE" $? \
  "pastes: $(grep -c 'DUPLICATE-DELIVERY-SENTINEL' "$SOCKROOT/noecho/requests.log" 2>/dev/null || echo 0)"

jq -e '.recovery | test("Do NOT re-dial")' <<<"$out" >/dev/null 2>&1
check "…and the recovery forbids re-dialling rather than suggesting a retry" $? "out=$out"
jq -e '.recovery | test("transcript")' <<<"$out" >/dev/null 2>&1
check "…and points at the callee's transcript as the way to find out what happened" $? "out=$out"
[[ -s "$DUP_CALL_DIR/pending_paste.md" ]]
check "…and the prompt survives in the call dir (it is the only copy)" $? \
  "call dir: $(ls -A "$DUP_CALL_DIR" 2>/dev/null | tr '\n' ' ')"

# The other side of the line: a refusal BEFORE anything was sent still falls back to
# a fresh surface, because the callee received nothing.
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
printf 'Request interrupted by user\nWhat should Claude do instead?\nClaude Code v2.1.221\n\xe2\x9d\xaf\xc2\xa0\n' \
  > "$t/screen.txt"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-presend" --session "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee" \
  --mode work_order --surface "SURFACE-UUID-OLD"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-presend" HOTLINE_PENDING_DIR="$t/pending" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" \
  bash "$DIAL" --target "$t/target" --mode work_order --label "probe label" \
    --prompt "refused before anything was sent" --boot-timeout 5 2>"$t/err.txt")
[[ -n "$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)" ]] && note_leak "$(jq -r .call_dir <<<"$out")"
[[ "$(jq -r .status <<<"$out")" == "connected" ]] \
  && jq -e '.fallbacks | map(startswith("surface-reuse→fresh")) | any' <<<"$out" >/dev/null 2>&1
check "a pre-send refusal still takes the fresh-surface fallback (nothing was sent)" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

# ===========================================================================
# NO PAYLOAD ON ANY argv, on ANY transport. The audit, not a spot check.
#
# A `claude` shim records every argv it is ever handed, across all three
# transports: cmux first contact (bare launch + paste), headless (`claude -p`
# reading stdin), and conference (bare launch + paste). Then one assertion: the
# payload sentinel appears in none of them.
#
# This is the claim README.md and dial.sh's own comments make, and before this
# audit two of the three transports quietly contradicted it — headless handed the
# whole prompt to `claude -p "$PROMPT"`, and conference to a launch script's
# positional argument (claude-plugins-86ka, -92s5).
# ===========================================================================
ARGV_SENTINEL="ARGV-AUDIT-SENTINEL-7Q3"
ARGV_LOG=""
argv_audit_env() {   # argv_audit_env <scratch-root> — writes bin/claude, echoes nothing
  local t="$1"
  mkdir -p "$t/bin"
  cat > "$t/bin/claude" <<EOF
#!/usr/bin/env bash
# Record the argv of every claude invocation, whatever the transport.
printf '%q ' "\$@" >> "$ARGV_LOG"; printf '\n' >> "$ARGV_LOG"
SID="\${FAKE_CLAUDE_SESSION_ID:-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee}"
printf '{"type":"system","session_id":"%s"}\n' "\$SID"
printf '{"type":"result","session_id":"%s","result":"ok","num_turns":1}\n' "\$SID"
EOF
  chmod +x "$t/bin/claude"
}

ARGV_LOG=$(mktemp); LEAKED+=("$ARGV_LOG")

# The system-prompt override is a second class of sensitive content that also
# must never ride an argv: it goes through --append-system-prompt-file, so only
# the PATH is on the command line and the CONTENT stays in the file. Seed a file
# whose CONTENT carries its own sentinel and thread it through every audit dial;
# the closing assertion proves that content sentinel never reaches an argv, the
# same guard the payload gets (claude-plugins-86ka).
SP_CONTENT_SENTINEL="SYSPROMPT-CONTENT-SENTINEL-9K2"
SP_FILE=$(mktemp); LEAKED+=("$SP_FILE")
printf '%s\nbe terse.\n' "$SP_CONTENT_SENTINEL" > "$SP_FILE"

# (a) cmux first contact.
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"; argv_audit_env "$t"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-audit-1" HOTLINE_PENDING_DIR="$t/pending" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" \
  HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE="$SP_FILE" \
  bash "$DIAL" --target "$t/target" --mode work_order --label "probe label" \
    --prompt "$ARGV_SENTINEL cmux first contact" --boot-timeout 5 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
# The launch script is what the pane actually runs — collect its text too.
launch_script_of "$call_dir" >> "$ARGV_LOG"
[[ "$(jq -r .status <<<"$out")" == "connected" ]]
check "argv audit: the cmux dial completed" $? "out=$out stderr=$(cat "$t/err.txt")"

# (b) headless.
t=$(new_env); note_leak "$t"
argv_audit_env "$t"; make_ps "$t/bin"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" \
  HOTLINE_CALLER_SESSION_ID="caller-audit-2" HOTLINE_PENDING_DIR="$t/pending" \
  HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE="$SP_FILE" \
  bash "$DIAL" --target "$t/target" --mode quick --label "probe label" --headless \
    --prompt "$ARGV_SENTINEL headless" --boot-timeout 8 2>"$t/err.txt")
[[ "$(jq -r .status <<<"$out")" == "connected" ]]
check "argv audit: the headless dial completed" $? "out=$out stderr=$(cat "$t/err.txt")"
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"

# (c) conference.
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"; argv_audit_env "$t"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-audit-3" HOTLINE_PENDING_DIR="$t/pending" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" \
  HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE="$SP_FILE" \
  bash "$DIAL" --target "$t/target" --mode conference --label "probe label" \
    --prompt "$ARGV_SENTINEL conference" 2>"$t/err.txt")
[[ "$(jq -r .status <<<"$out")" == "connected" ]]
check "argv audit: the conference dial completed" $? "out=$out stderr=$(cat "$t/err.txt")"
conf_launch=$(grep -oE '/tmp/hotline-cmux-launch-[A-Za-z0-9]+' "$t/send_calls" 2>/dev/null | head -1)
[[ -n "$conf_launch" ]] && { note_leak "$conf_launch"; cat "$conf_launch" >> "$ARGV_LOG" 2>/dev/null; }

# THE ASSERTION.
if grep -qF "$ARGV_SENTINEL" "$ARGV_LOG"; then
  fail "NO transport puts payload text on an argv or in a launch script" \
       "$(grep -F "$ARGV_SENTINEL" "$ARGV_LOG" | head -3)"
else
  pass "NO transport puts payload text on an argv or in a launch script"
fi
# The audit is only meaningful if claude was actually invoked.
[[ -s "$ARGV_LOG" ]]
check "…and the audit actually saw claude invocations (the log is non-empty)" $? \
  "the argv log is empty — the shim never ran, so the assertion above proves nothing"

# System-prompt override: the FLAG threaded (so the absence below is not vacuous),
# but the file's CONTENT never reached an argv — only its path did.
grep -q -- '--append-system-prompt-file' "$ARGV_LOG"
check "…and the system-prompt override threaded as --append-system-prompt-file" $? \
  "no transport carried the flag, so the content-absence check would prove nothing"
if grep -qF "$SP_CONTENT_SENTINEL" "$ARGV_LOG"; then
  fail "NO transport puts system-prompt CONTENT on an argv (only its file path)" \
       "$(grep -F "$SP_CONTENT_SENTINEL" "$ARGV_LOG" | head -3)"
else
  pass "NO transport puts system-prompt CONTENT on an argv (only its file path)"
fi
# `claude -p` with no positional prompt: the prompt arrives on stdin.
grep -qE '^-p ' "$ARGV_LOG" || grep -q "'-p'" "$ARGV_LOG"
check "…and headless invoked 'claude -p' with no positional prompt" $? \
  "$(cat "$ARGV_LOG")"

# ===========================================================================
# The capability preflight distinguishes its failure modes.
#
# The first version funnelled a missing python3, an unreachable socket and a
# genuine capability miss through one `2>/dev/null || true` and reported all three
# as terminal-paste-unavailable — which sends a reader off to upgrade cmux when the
# real problem is a socket nobody is listening on.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_claude "$t/bin"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  CMUX_SOCKET_PATH="$SOCKROOT/definitely-not-a-socket" \
  HOTLINE_CALLER_SESSION_ID="caller-nosock" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order --label "probe label" \
    --prompt "no socket here" --boot-timeout 5 2>"$t/err.txt")
[[ -n "$(jq -r '.call_dir // empty' <<<"$out")" ]] && note_leak "$(jq -r .call_dir <<<"$out")"
jq -e '.fallbacks | map(startswith("cmux-socket-unreachable→headless")) | any' <<<"$out" >/dev/null 2>&1
check "an unreachable control socket is reported as such, not as a capability miss" $? \
  "out=$out"
jq -e '.fallbacks | map(test("No such file|refused|socket")) | any' <<<"$out" >/dev/null 2>&1
check "…and the socket's own diagnostic rides along in the reason" $? "out=$out"

# A PATH with no python3 on it at all. Built by symlinking the tools dial.sh needs
# rather than by stripping one entry out of the real PATH: python3 shares /usr/bin
# with most of them, so subtraction is not an option.
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_claude "$t/bin"
mkdir -p "$t/nopy"
for _tool in bash sh env jq sed grep egrep cat cut tr head tail wc ls mktemp rm \
             mkdir dirname basename date realpath awk sort uniq find ps openssl \
             od stat sleep chmod cp mv ln xargs id uname touch printf; do
  _src="$(command -v "$_tool" 2>/dev/null || true)"
  [[ -n "$_src" ]] && ln -sf "$_src" "$t/nopy/$_tool"
done
if [[ -n "$(PATH="$t/nopy" command -v python3 2>/dev/null)" ]]; then
  fail "a missing python3 is reported as a missing python3" \
       "the scratch PATH still resolves python3, so this case proves nothing"
else
out=$(PATH="$t/bin:$t/nopy" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-nopy" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order --label "probe label" \
    --prompt "no python here" --boot-timeout 5 2>"$t/err.txt")
[[ -n "$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)" ]] && note_leak "$(jq -r .call_dir <<<"$out")"
jq -e '.fallbacks | map(startswith("python3-missing→headless")) | any' <<<"$out" >/dev/null 2>&1
check "a missing python3 is reported as a missing python3" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
fi

# ===========================================================================
# Boot signal B needs freshness: a plain resume's transcript ALREADY EXISTS.
#
# `[[ -s $transcript ]]` fired on the first poll for every resume, in the same
# millisecond the launch command was sent — reporting a booted REPL before claude
# had exec'd. Everything downstream then proceeded against a shell, and with
# delivery being a paste that is not a lost message but a work order typed at a
# prompt. Signal B now requires the file to have GROWN.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
# A screen that offers NO boot evidence: no banner, no input box. Only signal B
# could fire here, and it must not.
printf 'some old scrollback with no repl on it\n' > "$t/screen.txt"
RESUME_SID="9a9a9a9a-9b9b-4c9c-8d9d-9e9e9e9e9e9e"
TARGET_REAL=$(cd "$t/target" && pwd -P)
STALE_ENC=$(printf '%s' "$TARGET_REAL" | sed 's|[^a-zA-Z0-9]|-|g')
mkdir -p "$t/home/.claude/projects/$STALE_ENC"
# The prior session's transcript: present, non-empty, and untouched from here on.
printf '{"type":"user","message":{"role":"user","content":"a turn from last week"}}\n' \
  > "$t/home/.claude/projects/$STALE_ENC/${RESUME_SID}.jsonl"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-stale" --session "$RESUME_SID" \
  --mode work_order --surface "SURFACE-UUID-OLD"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-stale" HOTLINE_PENDING_DIR="$t/pending" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" \
  bash "$DIAL" --target "$t/target" --mode work_order --label "probe label" \
    --prompt "resume into a stale transcript" --boot-timeout 3 2>"$t/err.txt")
[[ -n "$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)" ]] && note_leak "$(jq -r .call_dir <<<"$out")"
[[ "$(jq -r '.status // empty' <<<"$out")" == "error" \
   && "$(jq -r '.stage // empty' <<<"$out")" == "boot" ]]
check "a pre-existing transcript does NOT count as a booted REPL on resume" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

# Both directions of signal B, driven straight at wait-for-session.sh — the only
# place the preset session id is an INPUT rather than a random value the launcher
# picked, which is what makes the fresh case deterministic instead of a race.
WFS="$HOTLINE_DIR/skills/dial/scripts/wait-for-session.sh"
signal_b_case() {   # signal_b_case <name> <pre-existing-bytes|""> <grow:yes|no>
  local name="$1" pre="$2" grow="$3"
  local d; d=$(mktemp -d "$TMP_ROOT"/hotline-sigb-XXXXXX); note_leak "$d"
  mkdir -p "$d/bin" "$d/home" "$d/call"
  # A screen with NO banner and NO input box: signal B is the only one that can fire.
  cat > "$d/bin/cmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  read-screen) printf 'old scrollback, no repl here\n' ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$d/bin/cmux"
  local sid="7f7f7f7f-7f7f-4f7f-8f7f-7f7f7f7f7f7f"
  echo "$sid" > "$d/call/session_id_preset.txt"
  echo "SURFACE-SIGB" > "$d/call/surface_ref.txt"
  echo "$d/target" > "$d/call/cwd.txt"
  mkdir -p "$d/target"
  local enc; enc=$(printf '%s' "$d/target" | sed 's|[^a-zA-Z0-9]|-|g')
  mkdir -p "$d/home/.claude/projects/$enc"
  local tr="$d/home/.claude/projects/$enc/${sid}.jsonl"
  [[ -n "$pre" ]] && printf '%s' "$pre" > "$tr"
  if [[ "$grow" == "yes" ]]; then
    ( sleep 1; printf '{"type":"user","message":{"role":"user","content":"fresh turn"}}\n' >> "$tr" ) &
  fi
  SIGB_OUT="$(PATH="$d/bin:$PATH" HOME="$d/home" \
    bash "$WFS" "$d/call" --timeout 6 2>&1)"
  SIGB_RC=$?
  wait 2>/dev/null || true
}

# STALE: the file is already there and never changes. This is every plain resume,
# and a bare existence check fired on the first poll — reporting a booted REPL in
# the same millisecond the launch command was sent.
signal_b_case stale '{"type":"user","message":{"role":"user","content":"a turn from last week"}}
' no
[[ "$SIGB_RC" -ne 0 && "$SIGB_OUT" == *"Timed out"* ]]
check "signal B: a pre-existing, unchanged transcript is NOT a booted REPL" $? \
  "rc=$SIGB_RC out=$SIGB_OUT"

# FRESH-GROWN: the same pre-existing file, appended to mid-wait. A resume that
# really does start writing must still be detected.
signal_b_case grown '{"type":"user","message":{"role":"user","content":"a turn from last week"}}
' yes
[[ "$SIGB_RC" -eq 0 && "$SIGB_OUT" == "7f7f7f7f-7f7f-4f7f-8f7f-7f7f7f7f7f7f" ]]
check "signal B: a transcript that GROWS during the wait is a booted REPL" $? \
  "rc=$SIGB_RC out=$SIGB_OUT"

# FRESH-CREATED: first contact, where the file does not exist at all beforehand.
signal_b_case created "" yes
[[ "$SIGB_RC" -eq 0 ]]
check "signal B: a transcript that APPEARS during the wait is a booted REPL" $? \
  "rc=$SIGB_RC out=$SIGB_OUT"

# ===========================================================================
# ONE definition of the boot budget, and the docs must match it.
#
# The box wait and the boot wait are waiting for the same event, and they lived in
# two places with two values: wait-for-session.sh hardcoded 60 while dial.sh read
# ${BOOT_TIMEOUT:-20} against a variable that is empty unless --boot-timeout was
# passed — so the real default box wait was 20s while README and SKILL.md promised
# 60. A string canary, because what broke was agreement between files.
# ===========================================================================
REPL_STATE="$HOTLINE_DIR/scripts/repl-state.sh"
SHARED_CMUX_DEFAULT=$(sed -n 's/^HOTLINE_BOOT_TIMEOUT_CMUX="\${HOTLINE_BOOT_TIMEOUT_CMUX:-\([0-9]*\)}"/\1/p' "$REPL_STATE")
[[ "$SHARED_CMUX_DEFAULT" == "60" ]]
check "repl-state.sh defines the cmux boot budget as 60" $? "got: '$SHARED_CMUX_DEFAULT'"

grep -q 'TIMEOUT="\$HOTLINE_BOOT_TIMEOUT_CMUX"' "$HOTLINE_DIR/skills/dial/scripts/wait-for-session.sh"
check "wait-for-session.sh takes its default from the shared constant" $? \
  "$(grep -n 'TIMEOUT=6\|TIMEOUT=3\|HOTLINE_BOOT_TIMEOUT' "$HOTLINE_DIR/skills/dial/scripts/wait-for-session.sh")"

grep -q 'PASTE_BOX_TIMEOUT="\${HOTLINE_PASTE_BOX_TIMEOUT:-\${BOOT_TIMEOUT:-\$HOTLINE_BOOT_TIMEOUT_CMUX}}"' "$DIAL"
check "dial.sh resolves the box wait from the same constant, once" $? \
  "$(grep -n 'PASTE_BOX_TIMEOUT=' "$DIAL")"

# No hardcoded 20 left at either delivery site — that was the untrue default.
# Comment lines are excluded: the fix's own comment quotes the old
# ${BOOT_TIMEOUT:-20} to explain what was wrong, and a canary that cannot tell code
# from prose fails on its own explanation.
HARDCODED=$(grep -nE 'BOOT_TIMEOUT:-2?0\}|PASTE_BOX_TIMEOUT:-2?0\}' \
  "$DIAL" "$HOTLINE_DIR/skills/dial/scripts/cmux-call.sh" 2>/dev/null \
  | grep -vE ':[0-9]+:[[:space:]]*#' || true)
if [[ -n "$HARDCODED" ]]; then
  fail "no delivery site hardcodes a 20s box wait any more" "$HARDCODED"
else
  pass "no delivery site hardcodes a 20s box wait any more"
fi

# Conference is a delivery site too, and dial.sh never forwarded the budget to it.
grep -q -- '--box-timeout "\$PASTE_BOX_TIMEOUT"' "$DIAL"
check "dial.sh forwards the box wait to the conference launcher" $? \
  "$(grep -n 'CONF_ARGS+=' "$DIAL")"

# And the documented number is the shared one, in both places a reader looks.
for doc in "$HOTLINE_DIR/skills/dial/SKILL.md" "$HOTLINE_DIR/README.md"; do
  rel="${doc#"$HOTLINE_DIR/"}"
  grep -qi 'HOTLINE_PASTE_BOX_TIMEOUT' "$doc"
  check "$rel documents HOTLINE_PASTE_BOX_TIMEOUT" $? "not mentioned"
  grep -qiE 'boot-timeout' "$doc"
  check "$rel ties it to --boot-timeout rather than naming a second number" $? "no --boot-timeout reference"
done

dial_wrapper_finish
