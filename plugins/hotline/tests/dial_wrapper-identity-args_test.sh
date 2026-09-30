#!/usr/bin/env bash
# =============================================================================
# dial.sh wrapper regression tests — caller identity (cached, replayed,
# disambiguated, headless fold-in, pending, native, a session id as --target) and
# the argument, error and output contracts, conference mode, and --label (sections
# 1-4, 7-14, 15, 16, N).
#
# One shard of the dial_wrapper suite. The stubs, sockets and scratch-env
# helpers live in lib/dial-wrapper-harness.sh; the sibling
# dial_wrapper-*_test.sh shards hold the other sections.
# =============================================================================
set -u
FAKE_CLAUDE_PID=990001
# shellcheck source=lib/dial-wrapper-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/dial-wrapper-harness.sh"

echo "dial.sh wrapper regression:"

# ===========================================================================
# 1. Cached identity, first contact, cmux side-by-side — one invocation.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
# The OK socket log accumulates across cases; reset it so this case's paste count
# and paste indices (nth_paste) are its own.
: > "$OK_REQUESTS"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-1111" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order --label "probe label" \
    --prompt "run the suite" --boot-timeout 5 2>"$t/err.txt")
rc=$?
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
launch=$(launch_script_of "$call_dir")

[[ "$rc" -eq 0 && "$(jq -r .status <<<"$out")" == "connected" ]]
check "cached identity connects in ONE invocation (exit 0, status=connected)" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"

[[ "$(jq -r .transport <<<"$out")" == "cmux" \
   && "$(jq -r .placement <<<"$out")" == "side" \
   && "$(jq -r .first_contact <<<"$out")" == "true" \
   && "$(jq -r .caller_session_id <<<"$out")" == "caller-1111" \
   && "$(jq -r .workspace <<<"$out")" == "$(cd "$t/target" && pwd -P)" ]]
check "payload reports transport/placement/first_contact/caller/workspace" $? "out=$out"

[[ "$(jq -r .surface_ref <<<"$out")" == "SURFACE-UUID-777" ]]
check "payload carries the stable surface handle" $? "out=$out"

[[ "$(jq -r '.remote_session_id' <<<"$out")" =~ ^[0-9a-f]{8}- ]]
check "payload carries the callee session id from wait-for-session" $? "out=$out"

[[ "$(jq -r '.fallbacks | length' <<<"$out")" -eq 0 ]]
check "clean cmux path records no fallbacks" $? "out=$out"

[[ "$(jq -r .awaiting_response <<<"$out")" == "true" ]]
check "async modes flag awaiting_response=true (wait-for-response is a separate step)" $? "out=$out"

# First contact is PASTED, not launched, and in TWO pastes: the slash invocation +
# its protocol tags ride paste 1 ALONE so it renders verbatim and the command
# parses; the work-order body rides paste 2, whose placeholder CC expands back
# inside the command args on submit (claude-plugins-pmgb). A single paste of the
# whole thing is the regression — a body over CC's ~800-char / 3-line threshold
# collapses the invocation's leading `/` and the ringing protocol never loads.
# The launch script is asserted free of the prompt: the prompt on claude's argv is
# the claude-plugins-86ka leak that scope B of the paste rework exists to close.
invite="$(nth_paste 1)"
body="$(nth_paste 2)"
[[ "$(paste_count)" -eq 2 ]] \
  && grep -q '/hotline:hotline-ringing' <<<"$invite" \
  && grep -qF '[MODE: work_order]' <<<"$invite" \
  && grep -qF '[SESSION: caller-1111]' <<<"$invite" \
  && grep -qF '[CALLER: ' <<<"$invite" \
  && grep -qF 'run the suite' <<<"$body"
check "first contact PASTES the ringing command + tags on paste 1, body on paste 2" $? \
  "invite=$invite body=$body count=$(paste_count)"

[[ "$invite" == '/hotline:hotline-ringing [CALL_ID: '* ]]
check "the nonce follows the slash command (a leading header would break parsing)" $? \
  "invite=$invite"

# The invocation line carries no work-order body, so nothing can push it past CC's
# collapse threshold and take the leading `/` down with it.
[[ "$invite" != *$'\n'* && "$invite" != *'run the suite'* ]]
check "the invocation paste is one line with no body glued on" $? \
  "invite=$invite"

launch_plain=$(unquoted <<<"$launch")
if grep -qF 'run the suite' <<<"$launch_plain" \
   || grep -q 'hotline-ringing' <<<"$launch_plain"; then
  fail "the prompt never reaches claude's argv" "launch=$launch"
else
  pass "the prompt never reaches claude's argv"
fi

[[ "$(nth_paste 1 surface_id)" == "SURFACE-UUID-777" \
   && "$(nth_paste 1 workspace_id)" == "WORKSPACE-UUID-1" \
   && "$(nth_paste 1 submit_key)" == "none" \
   && "$(nth_paste 2 submit_key)" == "none" ]]
check "both pastes go to the new surface by UUID, submit_key=none" $? \
  "surf=$(nth_paste 1 surface_id) ws=$(nth_paste 1 workspace_id) k1=$(nth_paste 1 submit_key) k2=$(nth_paste 2 submit_key)"

# The two-paste sequence is submitted by a real Enter key event, outside any paste.
grep -qiE '(^| )(enter|return)( |$)' "$t/sendkey_calls" 2>/dev/null
check "first contact submits with a separate Enter keystroke" $? \
  "sendkey_calls=$(cat "$t/sendkey_calls" 2>/dev/null)"

[[ "$(capability_count)" -ge 1 ]]
check "the dial preflights terminal.paste over the socket" $? \
  "capability calls: $(capability_count)"

[[ ! -f "$call_dir/pending_paste.md" ]]
check "pending_paste.md is removed once the prompt has landed" $? \
  "still present in $call_dir"

grep -q -- '--resume' <<<"$launch"
if [[ $? -eq 0 ]]; then
  fail "fresh first contact passes neither --resume nor --fork-session" "launch=$launch"
else
  pass "fresh first contact passes neither --resume nor --fork-session"
fi

# The registry write is script-level (wait-for-session → register-call), so the
# wrapper must not need to do it — assert it happened.
[[ -s "$t/home/.agents-hotline/sessions/caller-1111.json" ]]
check "first contact is registered in the sessions registry" $? \
  "$(ls -R "$t/home/.agents-hotline" 2>/dev/null)"

# ===========================================================================
# 2. Replay round-trip: plant → re-run the identical command → connected.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_claude "$t/bin"; make_ps "$t/bin"
mkdir -p "$t/home/.claude/projects/testproj"
rm -f "$STRAY_SESSION_CACHE"

DIAL_ARGS=(--target "$t/target" --mode quick --headless --label "probe label"
           --prompt "what branch are you on?" --boot-timeout 8)
run_replay() {
  ( cd "$t/work" && PATH="$t/bin:$PATH" HOME="$t/home" \
      FAKE_CLAUDE_PID="$FAKE_CLAUDE_PID" HOTLINE_PENDING_DIR="$t/pending" \
      FAKE_CLAUDE_SESSION_ID="cccccccc-dddd-4eee-8fff-000000000000" \
      "${STRIP_NATIVE_ID[@]}" bash "$DIAL" "${DIAL_ARGS[@]}" 2>>"$t/err.txt" )
}

out1=$(run_replay); rc1=$?
fp=$(jq -r '.fingerprint // empty' <<<"$out1" 2>/dev/null)

[[ "$rc1" -eq 2 && "$(jq -r .status <<<"$out1")" == "replay" ]]
check "identity cache miss emits status=replay and exits 2" $? "rc=$rc1 out=$out1"

[[ "$fp" == SESSION_FINGERPRINT_* ]]
check "replay payload carries the fingerprint (so it reaches the transcript)" $? "out=$out1"

[[ -s "$t/pending/hotline-pending-${FAKE_CLAUDE_PID}" ]]
check "pending state is persisted keyed by the claude pid" $? \
  "$(ls "$t/pending" 2>/dev/null)"

[[ "$(sed -n '1p' "$t/pending/hotline-pending-${FAKE_CLAUDE_PID}" 2>/dev/null)" == "$fp" ]]
check "pending file holds the same fingerprint that was emitted" $? \
  "$(cat "$t/pending/hotline-pending-${FAKE_CLAUDE_PID}" 2>/dev/null)"

# Simulate the harness flushing that output into the caller's transcript.
CALLER_SID="12345678-1234-4123-8123-123456789abc"
printf '{"type":"user","cwd":"%s","content":"%s"}\n' "$t/work" "$fp" \
  > "$t/home/.claude/projects/testproj/${CALLER_SID}.jsonl"

out2=$(run_replay); rc2=$?
call_dir=$(jq -r '.call_dir // empty' <<<"$out2" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"

[[ "$rc2" -eq 0 && "$(jq -r .status <<<"$out2")" == "connected" ]]
check "the identical re-run discovers the session and completes the call" $? \
  "rc=$rc2 out=$out2 stderr=$(cat "$t/err.txt")"

[[ "$(jq -r .caller_session_id <<<"$out2")" == "$CALLER_SID" ]]
check "re-run adopts the discovered caller session id" $? "out=$out2"

[[ ! -e "$t/pending/hotline-pending-${FAKE_CLAUDE_PID}" ]]
check "pending state is cleared once discovery succeeds" $? \
  "$(ls "$t/pending" 2>/dev/null)"

[[ "$(jq -r .remote_session_id <<<"$out2")" == "cccccccc-dddd-4eee-8fff-000000000000" ]]
check "headless transport reports the callee session id from the stream" $? "out=$out2"

# A third run must NOT replay again — the discovered id is cached now.
out3=$(run_replay); rc3=$?
call_dir=$(jq -r '.call_dir // empty' <<<"$out3" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
[[ "$rc3" -eq 0 && "$(jq -r .status <<<"$out3")" == "connected" ]]
check "identity stays cached — a later dial never replays again" $? "rc=$rc3 out=$out3"
rm -f "$STRAY_SESSION_CACHE"

# ===========================================================================
# 3. Disambiguation surfaces as status=needs_disambiguation + candidates.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_dirmap "$t/bin"
mkdir -p "$t/home/alpha" "$t/home/beta"
jq -n --arg a "$t/home/alpha" --arg b "$t/home/beta" \
  '{alpha:$a, beta:$b}' > "$t/home/.dirmap.json"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" HOTLINE_CALLER_SESSION_ID="caller-3333" \
  HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "the mystery workspace" --mode quick --label "probe label" \
    --prompt "hello?" 2>"$t/err.txt")
rc=$?

[[ "$rc" -eq 3 && "$(jq -r .status <<<"$out")" == "needs_disambiguation" ]]
check "ambiguous reference exits 3 with status=needs_disambiguation" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"

[[ "$(jq -r '.candidates | length' <<<"$out")" -eq 2 ]]
check "candidates from resolve-workspace.sh are surfaced verbatim" $? "out=$out"

[[ "$(jq -r '.reference' <<<"$out")" == "the mystery workspace" ]]
check "the user's exact reference is echoed back for the ask" $? "out=$out"

[[ "$(jq -r '.candidates[0] | has("path") and has("id")' <<<"$out")" == "true" ]]
check "each candidate keeps its id and path" $? "out=$out"

# ===========================================================================
# 4. Headless fold-in: cmux up, cmux-cli missing → re-fire, record a fallback.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_claude "$t/bin"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-4444" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/nope.sh" HOTLINE_PLUGINS_DIR="$t/empty" \
  HOTLINE_PENDING_DIR="$t/pending" \
  FAKE_CLAUDE_SESSION_ID="44444444-4444-4444-8444-444444444444" \
  bash "$DIAL" --target "$t/target" --mode work_order --label "probe label" \
    --prompt "fold me in" --boot-timeout 8 2>"$t/err.txt")
rc=$?
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"

[[ "$rc" -eq 0 && "$(jq -r .status <<<"$out")" == "connected" \
   && "$(jq -r .transport <<<"$out")" == "headless" ]]
check "cmux-cli-missing folds into headless inside the wrapper (still connected)" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"

jq -e '.fallbacks | index("cmux-cli-missing→headless")' <<<"$out" >/dev/null 2>&1
check "the fold-in is recorded in fallbacks, not bounced to the model" $? "out=$out"

[[ "$(jq -r .placement <<<"$out")" == "none" ]]
check "headless transport reports placement=none" $? "out=$out"

[[ "$(jq -r .remote_session_id <<<"$out")" == "44444444-4444-4444-8444-444444444444" ]]
check "the re-fired headless call is the one we wait on" $? "out=$out"

# ===========================================================================
# 7. Conference mode early-returns after cmux-call.sh — no boot/response wait.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
# Reset the shared OK socket log so nth_paste indexes this case's pastes.
: > "$OK_REQUESTS"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-8888" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode conference --label "probe label" \
    --prompt "let us pair on this" 2>"$t/err.txt")
rc=$?
# cmux-call.sh's launch script self-deletes only when executed; ours never is.
conf_launch=$(grep -oE '/tmp/hotline-cmux-launch-[A-Za-z0-9]+' "$t/send_calls" 2>/dev/null | head -1)
[[ -n "$conf_launch" ]] && note_leak "$conf_launch"

[[ "$rc" -eq 0 && "$(jq -r .status <<<"$out")" == "connected" \
   && "$(jq -r .mode <<<"$out")" == "conference_call" ]]
check "conference mode connects through cmux-call.sh" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"

[[ "$(jq -r .awaiting_response <<<"$out")" == "false" ]]
check "conference mode reports awaiting_response=false (early return)" $? "out=$out"

[[ "$(jq -r 'has("call_dir")' <<<"$out")" == "false" ]]
check "conference mode emits no call_dir (nothing to poll)" $? "out=$out"

[[ "$(jq -r .remote_session_id <<<"$out")" =~ ^[0-9a-f]{8}- ]]
check "conference mode reports the callee session id" $? "out=$out"

# The prompt is PASTED, not launched: conference was the last hotline path putting a
# payload on claude's argv (claude-plugins-92s5), and its launch script must now be
# free of it.
# First contact splits into two pastes; the MODE tag rides paste 1 (the invocation).
[[ "$(nth_paste 1)" == *'[MODE: conference_call]'* ]]
check "conference first contact PASTES the conference_call MODE tag on paste 1" $? \
  "invite=$(nth_paste 1) launch=$(cat "$conf_launch" 2>/dev/null)"

if grep -qF 'MODE: conference_call' "$conf_launch" 2>/dev/null; then
  fail "the conference prompt never reaches claude's argv" "launch=$(cat "$conf_launch")"
else
  pass "the conference prompt never reaches claude's argv"
fi

# cmux-call.sh mints a nonce now — conference calls had none, so the receiver had
# nothing to echo and superseded-surface cleanup could never prove a conference
# surface's identity.
[[ "$(jq -r '.call_id // empty' <<<"$out")" =~ ^[0-9a-f]{16}$ ]]
check "a conference call carries a call_id nonce" $? "out=$out"
[[ "$(nth_paste 1)" == *"$(jq -r '.call_id' <<<"$out")"* ]]
check "…and the nonce is in paste 1, after the slash command" $? \
  "invite=$(nth_paste 1)"

# cmux-call.sh registers the session itself, so the wrapper must not have to.
[[ -s "$t/home/.agents-hotline/sessions/caller-8888.json" ]]
check "conference call is registered by cmux-call.sh" $? \
  "$(ls -R "$t/home/.agents-hotline" 2>/dev/null)"

# ...but cmux-call.sh has no --surface to register, so the wrapper must add it.
# Without this the next conference turn finds no surface_ref, skips the reuse
# guard, and opens a SECOND surface resuming a session whose REPL is still live.
target_real=$(cd "$t/target" && pwd -P)
[[ "$(jq -r --arg t "$target_real" '.connections[$t].surface_ref' \
      "$t/home/.agents-hotline/sessions/caller-8888.json" 2>/dev/null)" == "SURFACE-UUID-777" ]]
check "conference first contact records surface_ref for the next turn" $? \
  "$(cat "$t/home/.agents-hotline/sessions/caller-8888.json" 2>/dev/null)"

# ===========================================================================
# 8. Errors carry stage / detail / recovery.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
: > "$t/screen.txt"     # blank: never shows a banner → wait-for-session times out
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-9999" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order --label "probe label" \
    --prompt "never boots" --boot-timeout 1 2>"$t/err.txt")
rc=$?
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir" && launch_script_of "$call_dir" >/dev/null

[[ "$rc" -eq 1 && "$(jq -r .status <<<"$out")" == "error" \
   && "$(jq -r .stage <<<"$out")" == "boot" ]]
check "a REPL that never boots is status=error stage=boot (exit 1)" $? "rc=$rc out=$out"

[[ -n "$(jq -r '.detail // empty' <<<"$out")" \
   && -n "$(jq -r '.recovery // empty' <<<"$out")" ]]
check "boot errors carry both detail and recovery" $? "out=$out"

[[ -n "$(jq -r '.call_dir // empty' <<<"$out")" ]]
check "boot errors keep the call_dir so its diagnostics are readable" $? "out=$out"

# `boot` never gets a retry on this same call dir (a re-dial mints a new one),
# so the abandoned pending_paste.md is dropped right away instead of leaking
# forever — unlike `deliver`, where it is the surviving copy the recovery path
# reads (claude-plugins-x7m9). error.txt/surface_err.txt are untouched: only
# the payload goes.
[[ -n "$call_dir" && ! -f "$call_dir/pending_paste.md" ]]
check "…and drops pending_paste.md right away, since this call dir is never retried" $? \
  "call_dir contents: $(ls -A "$call_dir" 2>/dev/null | tr '\n' ' ')"

t=$(new_env); note_leak "$t"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" HOTLINE_CALLER_SESSION_ID="caller-aaaa" \
  HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/does-not-exist-anywhere" --mode quick --label "probe label" \
    --prompt "hi" 2>"$t/err.txt")
rc=$?
[[ "$rc" -eq 1 && "$(jq -r .stage <<<"$out")" == "resolve" ]]
check "an unresolvable absolute path is status=error stage=resolve" $? "rc=$rc out=$out"

# ===========================================================================
# 9. Output contract: every exit path emits exactly one JSON object.
# ===========================================================================
t=$(new_env); note_leak "$t"
for args in "--mode quick --prompt x" "--target /tmp --prompt x" \
            "--target /tmp --mode quick" "--target /tmp --mode bogus --prompt x" \
            "--target /tmp --mode quick --prompt x --placement window"; do
  o=$(PATH="$t/bin:$PATH" HOME="$t/home" HOTLINE_CALLER_SESSION_ID="caller-bbbb" \
      HOTLINE_PENDING_DIR="$t/pending" bash "$DIAL" $args 2>/dev/null)
  jq -e 'type == "object" and has("status")' <<<"$o" >/dev/null 2>&1
  check "invalid args ($args) still emit one JSON object with a status" $? "out=$o"
done

# ===========================================================================
# 10. Argument parsing can't hang, and can't silently misread a typo.
# ===========================================================================
# A trailing value flag used to spin the parse loop forever at full CPU with no
# JSON on stdout: `shift 2` with one arg left fails WITHOUT shifting, and there
# is no `set -e` to stop it. `--prompt-file "$VAR"` with an empty VAR reaches it.
t=$(new_env); note_leak "$t"
for flag in --target --mode --prompt-file --prompt --placement --window \
            --tools --resume --caller-session --boot-timeout; do
  o=$(PATH="$t/bin:$PATH" HOME="$t/home" HOTLINE_CALLER_SESSION_ID="caller-cccc" \
      HOTLINE_PENDING_DIR="$t/pending" \
      timeout 5 bash "$DIAL" --mode quick --label "probe label" --prompt x "$flag" 2>/dev/null)
  rc=$?
  [[ "$rc" -eq 1 && "$(jq -r '.stage // empty' <<<"$o" 2>/dev/null)" == "args" ]]
  check "trailing bare $flag errors immediately instead of spinning" $? \
    "rc=$rc (124 = still hanging) out=$o"
done

o=$(PATH="$t/bin:$PATH" HOME="$t/home" HOTLINE_CALLER_SESSION_ID="caller-cccc" \
    HOTLINE_PENDING_DIR="$t/pending" \
    timeout 5 bash "$DIAL" --target /tmp --mode quick --label "probe label" --prompt-fil /tmp/x 2>/dev/null)
[[ "$(jq -r '.stage // empty' <<<"$o" 2>/dev/null)" == "args" ]] \
  && grep -q 'prompt-fil' <<<"$o"
check "a misspelled flag errors and names itself (never silently ignored)" $? "out=$o"

o=$(PATH="$t/bin:$PATH" HOME="$t/home" HOTLINE_CALLER_SESSION_ID="caller-cccc" \
    HOTLINE_PENDING_DIR="$t/pending" \
    timeout 5 bash "$DIAL" --target /tmp --mode quick --label "probe label" --prompt x --boot-timeout soon 2>/dev/null)
[[ "$(jq -r '.stage // empty' <<<"$o" 2>/dev/null)" == "args" ]]
check "a non-numeric --boot-timeout is rejected before it reaches arithmetic" $? "out=$o"

# HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE: a missing/unreadable path fails at
# the args stage, before any launch — otherwise it is an opaque cmux boot
# timeout. The error names the variable so the reader knows what to fix.
o=$(PATH="$t/bin:$PATH" HOME="$t/home" HOTLINE_CALLER_SESSION_ID="caller-cccc" \
    HOTLINE_PENDING_DIR="$t/pending" \
    HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE="$t/no-such-prompt.txt" \
    timeout 5 bash "$DIAL" --target /tmp --mode quick --label "probe label" --prompt x 2>/dev/null)
[[ "$(jq -r '.stage // empty' <<<"$o" 2>/dev/null)" == "args" ]] \
  && grep -q 'HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE' <<<"$o"
check "an unreadable HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE fails at args and names itself" $? "out=$o"

# ...and a readable one passes validation: the dial gets past args (here it goes
# on to fail at resolve on the bogus target, which proves args did not reject it).
printf 'be terse.' > "$t/real-prompt.txt"
o=$(PATH="$t/bin:$PATH" HOME="$t/home" HOTLINE_CALLER_SESSION_ID="caller-cccc" \
    HOTLINE_PENDING_DIR="$t/pending" \
    HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE="$t/real-prompt.txt" \
    timeout 10 bash "$DIAL" --target "$t/nope-not-here" --mode quick --label "probe label" --prompt x 2>/dev/null)
[[ "$(jq -r '.stage // empty' <<<"$o" 2>/dev/null)" != "args" ]]
check "a readable HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE passes the args gate" $? "out=$o"

# --window outranks --placement per SKILL.md, and must do so in EITHER order.
for order in "--placement detached --window winname" "--window winname --placement detached"; do
  o=$(PATH="$t/bin:$PATH" HOME="$t/home" HOTLINE_CALLER_SESSION_ID="caller-cccc" \
      HOTLINE_PENDING_DIR="$t/pending" \
      timeout 10 bash "$DIAL" --target "$t/nope-not-here" --mode quick --label "probe label" --prompt x \
        $order 2>/dev/null)
  # Reaching the resolve stage proves placement validated as `window` (a stray
  # `detached` would too, so pair this with the args-stage check below).
  [[ "$(jq -r '.stage // empty' <<<"$o" 2>/dev/null)" == "resolve" ]]
  check "--window is order-independent ($order)" $? "out=$o"
done
# ...and the pairing: an invalid --placement alongside --window is fine, because
# --window replaces it. Order-dependent code would reject one of these two.
for order in "--placement bogus --window winname" "--window winname --placement bogus"; do
  o=$(PATH="$t/bin:$PATH" HOME="$t/home" HOTLINE_CALLER_SESSION_ID="caller-cccc" \
      HOTLINE_PENDING_DIR="$t/pending" \
      timeout 10 bash "$DIAL" --target "$t/nope-not-here" --mode quick --label "probe label" --prompt x \
        $order 2>/dev/null)
  [[ "$(jq -r '.stage // empty' <<<"$o" 2>/dev/null)" != "args" ]]
  check "--window overrides an unusable --placement ($order)" $? "out=$o"
done

# ===========================================================================
# 11. Conference follow-ups reuse the live surface instead of stacking one.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
printf 'some earlier conference output\n\xe2\x9d\xaf\xc2\xa0\n' > "$t/screen.txt"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-conf" --session "cfcfcfcf-cfcf-4fcf-8fcf-cfcfcfcfcfcf" \
  --mode conference_call --surface "SURFACE-UUID-777"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-conf" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode conference --label "probe label" \
    --prompt "next thought" --boot-timeout 5 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"

[[ "$(jq -r .status <<<"$out")" == "connected" \
   && "$(jq -r .first_contact <<<"$out")" == "false" ]]
check "conference follow-up connects with first_contact=false" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

[[ "$(last_paste)" == *'next thought' ]] \
  && ! grep -q 'hotline-cmux-launch' "$t/send_calls" 2>/dev/null
check "conference follow-up is pasted into the live surface, opens no second one" $? \
  "pasted=$(last_paste) send_calls=$(cat "$t/send_calls" 2>/dev/null)"

target_real=$(cd "$t/target" && pwd -P)
[[ "$(jq -r --arg t "$target_real" '.connections[$t].exchange_count' \
      "$t/home/.agents-hotline/sessions/caller-conf.json" 2>/dev/null)" == "2" ]]
check "conference follow-up bumps exchange_count" $? \
  "$(cat "$t/home/.agents-hotline/sessions/caller-conf.json" 2>/dev/null)"

# Refused reuse on a conference call: falls back to cmux-call.sh --resume, and
# the cache still has to move (a raw follow-up carries no tags, so cmux-call.sh
# registers nothing at all on this path).
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
# Interrupted (so reuse refuses) but with a drawn box (so the FRESH conference
# surface, read through the same stub, accepts the paste).
printf 'Request interrupted by user\nWhat should Claude do instead?\nClaude Code v2.1.221\n\xe2\x9d\xaf\xc2\xa0\n' > "$t/screen.txt"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-conf2" --session "c2c2c2c2-c2c2-42c2-82c2-c2c2c2c2c2c2" \
  --mode conference_call --surface "SURFACE-UUID-OLD"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-conf2" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode conference --label "probe label" \
    --prompt "carry on" 2>"$t/err.txt")
conf_launch=$(grep -oE '/tmp/hotline-cmux-launch-[A-Za-z0-9]+' "$t/send_calls" 2>/dev/null | head -1)
[[ -n "$conf_launch" ]] && note_leak "$conf_launch"

[[ "$(jq -r .status <<<"$out")" == "connected" ]] \
  && grep -q -- '--resume c2c2c2c2-c2c2-42c2-82c2-c2c2c2c2c2c2' "$conf_launch" 2>/dev/null
check "a refused conference reuse resumes into a fresh surface" $? \
  "out=$out launch=$(cat "$conf_launch" 2>/dev/null)"

target_real=$(cd "$t/target" && pwd -P)
[[ "$(jq -r --arg t "$target_real" '.connections[$t].exchange_count' \
      "$t/home/.agents-hotline/sessions/caller-conf2.json" 2>/dev/null)" == "2" ]]
check "the conference fresh-surface path still bumps the cache" $? \
  "$(cat "$t/home/.agents-hotline/sessions/caller-conf2.json" 2>/dev/null)"

[[ "$(jq -r --arg t "$target_real" '.connections[$t].surface_ref' \
      "$t/home/.agents-hotline/sessions/caller-conf2.json" 2>/dev/null)" == "SURFACE-UUID-777" ]]
check "the conference fresh-surface path self-heals surface_ref" $? \
  "$(cat "$t/home/.agents-hotline/sessions/caller-conf2.json" 2>/dev/null)"

# ===========================================================================
# 12. A multi-line refusal reason stays ONE fallbacks entry.
# ===========================================================================
# fb_json serializes one entry per line, so an embedded newline used to split a
# single refusal into several bogus array entries.
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
# `send` fails with a two-line diagnostic, which lands in the refusal reason.
cat > "$t/bin/cmux" <<'EOF'
#!/usr/bin/env bash
ST="${CMUX_FAKE_STATE:?}"
echo "$*" >> "$ST/cmux_calls"
case "$1" in
  ping)        exit 0 ;;
  read-screen) cat "$ST/screen.txt" 2>/dev/null ;;
  send)
    if [[ "$*" == *"--surface SURFACE-UUID-OLD"* ]]; then
      printf 'cmux: send failed
second line of the diagnostic
' >&2
      exit 9
    fi
    echo "$*" >> "$ST/send_calls" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$t/bin/cmux"
printf 'idle
â¯ 
Claude Code v2.1.221
' > "$t/screen.txt"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-dddd" --session "dddddddd-dddd-4ddd-8ddd-dddddddddddd" \
  --mode work_order --surface "SURFACE-UUID-OLD"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-dddd" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order --label "probe label" \
    --prompt "reason has newlines" --boot-timeout 5 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir" && launch_script_of "$call_dir" >/dev/null

# One entry for the refusal — the point of the case. Superseded-surface cleanup
# legitimately adds a second entry of its own, so count the refusal's entries
# rather than the whole array.
[[ "$(jq -r '[.fallbacks[] | select(startswith("surface-reuse→fresh"))] | length' \
      <<<"$out" 2>/dev/null)" -eq 1 ]]
check "a multi-line refusal reason is one fallbacks entry, not several" $? "out=$out"

jq -e '.fallbacks[0] | startswith("surface-reuse→fresh")' <<<"$out" >/dev/null 2>&1
check "that entry still names the refusal" $? "out=$out"

# ===========================================================================
# 13. Pending identity state: expiry restarts the retry budget.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_claude "$t/bin"; make_ps "$t/bin"
mkdir -p "$t/home/.claude/projects/testproj"
rm -f "$STRAY_SESSION_CACHE"

# An old pending file that already burned the whole budget. It must be discarded
# as a leftover (or a recycled PID) rather than inherited into an error.
printf 'SESSION_FINGERPRINT_STALE-NEVER-PLANTED\n3\n1000000000\n' \
  > "$t/pending/hotline-pending-${FAKE_CLAUDE_PID}"
out=$( cd "$t/work" && PATH="$t/bin:$PATH" HOME="$t/home" \
  FAKE_CLAUDE_PID="$FAKE_CLAUDE_PID" HOTLINE_PENDING_DIR="$t/pending" \
  "${STRIP_NATIVE_ID[@]}" \
  bash "$DIAL" --target "$t/target" --mode quick --label "probe label" --headless --prompt "hi" 2>/dev/null )
rc=$?
[[ "$rc" -eq 2 && "$(jq -r .status <<<"$out")" == "replay" \
   && "$(jq -r .attempt <<<"$out")" == "1" ]]
check "an expired pending fingerprint restarts the retry budget at attempt 1" $? \
  "rc=$rc out=$out"

# A FRESH pending file that has already used the budget must still give up,
# rather than replaying forever.
printf 'SESSION_FINGERPRINT_FRESH-BUT-NEVER-PLANTED\n3\n%s\n' "$(date +%s)" \
  > "$t/pending/hotline-pending-${FAKE_CLAUDE_PID}"
out=$( cd "$t/work" && PATH="$t/bin:$PATH" HOME="$t/home" \
  FAKE_CLAUDE_PID="$FAKE_CLAUDE_PID" HOTLINE_PENDING_DIR="$t/pending" \
  "${STRIP_NATIVE_ID[@]}" \
  bash "$DIAL" --target "$t/target" --mode quick --label "probe label" --headless --prompt "hi" 2>/dev/null )
rc=$?
[[ "$rc" -eq 1 && "$(jq -r .stage <<<"$out")" == "identity" ]]
check "an exhausted retry budget gives up with an identity error" $? "rc=$rc out=$out"

grep -q 'HOTLINE_CALLER_SESSION_ID' <<<"$out"
check "the identity error names the escape hatch" $? "out=$out"
rm -f "$STRAY_SESSION_CACHE"

# Default pending location must be under ~/.agents-hotline, never /tmp.
grep -q 'HOTLINE_PENDING_DIR:-\$HOME/.agents-hotline/pending' "$DIAL"
check "pending state defaults into ~/.agents-hotline, not /tmp" $? \
  "$(grep -n 'PENDING_DIR=' "$DIAL")"

# ===========================================================================
# 14. Native identity ($CLAUDE_CODE_SESSION_ID) connects in ONE invocation.
# ===========================================================================
# Claude Code >= 2.1.132 exports the session ID into every Bash subprocess, so
# session-init.sh answers "cached"/"native" without the fingerprint dance. No
# fake `ps` is stubbed here on purpose: the native rung must not depend on
# process ancestry at all, so a real `ps` finding no claude has to be harmless.
t=$(new_env); note_leak "$t"
make_claude "$t/bin"
NATIVE_SID="9e1c7a3b-2d4f-4a6b-8c1d-0f2e3a4b5c6d"
out=$( cd "$t/work" && PATH="$t/bin:$PATH" HOME="$t/home" \
  HOTLINE_PENDING_DIR="$t/pending" \
  FAKE_CLAUDE_SESSION_ID="eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee" \
  env -u HOTLINE_CALLER_SESSION_ID -u CODEX_THREAD_ID \
      CLAUDE_CODE_SESSION_ID="$NATIVE_SID" \
  bash "$DIAL" --target "$t/target" --mode quick --label "probe label" --headless \
    --prompt "who am I talking to?" --boot-timeout 8 2>"$t/err.txt" )
rc=$?
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"

[[ "$rc" -eq 0 && "$(jq -r .status <<<"$out")" == "connected" ]]
check "native identity connects in ONE invocation (no replay, exit 0)" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"

[[ "$(jq -r .caller_session_id <<<"$out")" == "$NATIVE_SID" ]]
check "the native session id is adopted verbatim as caller_session_id" $? "out=$out"

[[ "$(jq -r .caller_kind <<<"$out")" == "native" ]]
check "the payload reports caller_kind=native" $? "out=$out"

# Nothing may be persisted for a replay that never has to happen — a pending
# file here would make the NEXT dial try to discover a fingerprint from it.
[[ -z "$(ls -A "$t/pending" 2>/dev/null)" ]]
check "the native path plants no pending fingerprint state" $? \
  "$(ls -A "$t/pending" 2>/dev/null)"

[[ -s "$t/home/.agents-hotline/sessions/${NATIVE_SID}.json" ]]
check "the call is registered under the native caller session id" $? \
  "$(ls -R "$t/home/.agents-hotline" 2>/dev/null)"

# ===========================================================================
# 15. --label is REQUIRED, and it names the callee through the SESSION NAME.
#
# claude publishes its `-n` session name as the terminal title and cmux renders
# that live in the tab strip, glyph included — `◑ hotline: fix 500s (work_order)`.
# So naming the session names the tab, and nothing has to pin a static title.
# These cases pin both halves: the requirement, and where the value lands.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"

# --- MISSING --label is an args error, refused before any side effect --------
out=$(PATH="$t/bin:$PATH" HOME="$t/home" HOTLINE_CALLER_SESSION_ID="caller-nolabel-1" \
  HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order \
    --prompt "do the thing" --boot-timeout 5 2>"$t/err.txt"); rc=$?
[[ "$rc" -eq 1 && "$(jq -r .status <<<"$out")" == "error" \
   && "$(jq -r .stage <<<"$out")" == "args" ]]
check "a dial with no --label is an args error" $? "rc=$rc out=$out"
[[ "$(jq -r .recovery <<<"$out")" == *'--label "<2-4 word slug of the task>"'* ]]
check "…and the recovery text names the flag and its shape verbatim" $? "out=$out"
[[ "$(jq -r .recovery <<<"$out")" == *"cmux tab strip"* ]]
check "…and says where the label shows up, so the agent knows what it is for" $? \
  "out=$out"

# NOTHING WAS OPENED. An args refusal costs the caller nothing to retry, and the
# whole reason the gate sits before the side-effect stages is that re-running the
# fixed command must be safe.
[[ ! -s "$t/cmux_calls" ]]
check "an args refusal reaches no cmux call at all" $? \
  "cmux calls: $(cat "$t/cmux_calls" 2>/dev/null)"

# --- EMPTY --label is the same refusal --------------------------------------
# `--label "$VAR"` with an unset VAR is reachable and arrives as a present flag
# with no value. A presence-only check would pass it and name the callee "".
for empty_label in "" "   "; do
  out=$(PATH="$t/bin:$PATH" HOME="$t/home" HOTLINE_CALLER_SESSION_ID="caller-nolabel-2" \
    HOTLINE_PENDING_DIR="$t/pending" \
    bash "$DIAL" --target "$t/target" --mode work_order --label "$empty_label" \
      --prompt "do the thing" --boot-timeout 5 2>"$t/err.txt"); rc=$?
  [[ "$rc" -eq 1 && "$(jq -r .stage <<<"$out")" == "args" \
     && "$(jq -r .recovery <<<"$out")" == *'--label "<2-4 word slug of the task>"'* ]]
  check "--label '$empty_label' is refused at the same gate, with the same recovery" $? \
    "rc=$rc out=$out"
done

# --- THE LABEL REACHES `claude -n`, side placement --------------------------
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
: > "$OK_REQUESTS"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-label-1" SIDE_OPENER_LOG="$t/side_calls" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order --label "fix 500s" \
    --prompt "audit the timeouts" --boot-timeout 5 2>"$t/err.txt"); rc=$?
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
launch=$(launch_script_of "$call_dir")

[[ "$rc" -eq 0 && "$(jq -r .status <<<"$out")" == "connected" ]]
check "a labelled dial connects" $? "rc=$rc out=$out err=$(cat "$t/err.txt" 2>/dev/null)"

# THE WHOLE POINT: the session name is `hotline: <label> (<mode>)` and nothing
# else. The caller and target directories are recorded in the call registry, the
# switchboard and dial history — none of which is a 30-character tab.
# %q-quoted in the launch script, so the expected form is built the same way —
# a plain substring match would fail on the escaping rather than on the name.
[[ "$launch" == *"-n $(printf '%q' 'hotline: fix 500s (work_order)')"* ]]
check "the label IS the session name: 'hotline: <label> (<mode>)', one argv word" $? \
  "got=$launch"
[[ "$launch" != *" → "* ]]
check "…with the caller→callee directory pair dropped from it" $? "got=$launch"

# NO --title, ANYWHERE. A pinned title outranks claude's dynamic one for the life
# of the tab, which costs the ◑/✳/⏺ activity glyph — the thing that shows a callee
# is stuck. CONTRACT GUARD: this absence-assertion is the whole feature, so it is
# meant to pass today and to fail the moment a rename is reintroduced.
if grep -q -- '--title' "$t/side_calls" 2>/dev/null; then
  fail "hotline passes NO --title to the side opener" \
    "side calls: $(cat "$t/side_calls" 2>/dev/null)"
else
  pass "hotline passes NO --title to the side opener"
fi
# CONTRACT GUARD, same reason: nothing in hotline may pin a tab title.
if grep -qE 'rename-tab|tab-action' "$t/cmux_calls" 2>/dev/null; then
  fail "no cmux rename-tab is issued for a label" \
    "cmux calls: $(cat "$t/cmux_calls" 2>/dev/null)"
else
  pass "no cmux rename-tab is issued for a label"
fi
[[ ! -e "$call_dir/label_status.txt" ]]
check "and no label_status.txt is minted — there is no title outcome to report" $? \
  "call_dir=$call_dir"
[[ "$(jq -r '.fallbacks | join(" ")' <<<"$out")" != *"label"* ]]
check "a first-contact label records no fallback" $? "out=$out"

# ===========================================================================
# 16. A FOLLOW-UP still has to carry --label, and the value is IGNORED.
#
# Whether a dial is first contact comes out of the session-cache lookup, hundreds
# of lines after the arguments are read — so the args gate cannot exempt a
# follow-up. It requires the flag and the reuse path throws the value away: the
# callee keeps the name first contact gave it, because a label typed against "and
# now step 2" is worse than the one chosen when the job was described in full.
# ===========================================================================
followup_label_case() {  # followup_label_case <caller-id> <cached-surface> [extra dial args...]
  local caller="$1" surface="$2"; shift 2
  t=$(new_env); note_leak "$t"
  make_cmux "$t/bin"
  printf 'some earlier output\n\xe2\x9d\xaf\xc2\xa0\n' > "$t/screen.txt"
  HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
    --caller-session "$caller" --session "55555555-5555-4555-8555-555555555555" \
    --mode work_order --surface "$surface" >/dev/null
  FOLLOWUP_OUT=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
    HOTLINE_CALLER_SESSION_ID="$caller" HOTLINE_PENDING_DIR="$t/pending" \
    bash "$DIAL" --target "$t/target" --mode work_order "$@" \
      --prompt "and now step 2" --boot-timeout 5 2>"$t/err.txt")
  FOLLOWUP_CMUX_CALLS="$t/cmux_calls"
  local cd_path
  cd_path=$(jq -r '.call_dir // empty' <<<"$FOLLOWUP_OUT" 2>/dev/null)
  [[ -n "$cd_path" ]] && note_leak "$cd_path"
}

LIVE_SURFACE="aaaa0000-1111-4111-8111-111111111111"
followup_label_case caller-fu-1 "$LIVE_SURFACE" --label "step 2 of 3"
[[ "$(jq -r .status <<<"$FOLLOWUP_OUT")" == "connected" \
   && "$(jq -r .first_contact <<<"$FOLLOWUP_OUT")" == "false" ]]
check "a follow-up carrying --label still connects" $? "out=$FOLLOWUP_OUT"
# The value is dropped SILENTLY: `.fallbacks` logs what the wrapper worked around,
# and a clean reuse worked around nothing. An entry here would fire on every
# follow-up and teach a reader to skim the array.
[[ "$(jq -r '.fallbacks | length' <<<"$FOLLOWUP_OUT")" -eq 0 ]]
check "…recording nothing about the ignored label: a clean reuse stays fallbacks:[]" $? \
  "out=$FOLLOWUP_OUT"
# CONTRACT GUARD: a follow-up must not rename the live host. The rename plumbing
# is gone, so this asserts an absence deliberately — it fails if one comes back.
if grep -qE 'rename-tab|tab-action' "$FOLLOWUP_CMUX_CALLS" 2>/dev/null; then
  fail "a follow-up renames nothing, whatever label it carried" \
    "cmux calls: $(cat "$FOLLOWUP_CMUX_CALLS" 2>/dev/null)"
else
  pass "a follow-up renames nothing, whatever label it carried"
fi

# A follow-up with NO --label is refused BEFORE the cache is read, so it never
# reaches the reuse path at all: the gate cannot know it is a follow-up.
followup_label_case caller-fu-2 "$LIVE_SURFACE"
[[ "$(jq -r .status <<<"$FOLLOWUP_OUT")" == "error" \
   && "$(jq -r .stage <<<"$FOLLOWUP_OUT")" == "args" ]]
check "a follow-up with no --label is refused at the args gate like any other dial" $? \
  "out=$FOLLOWUP_OUT"


# ===========================================================================
# N. A SESSION ID IN --target CONTINUES THAT CONVERSATION.
# ===========================================================================
# The id already names its workspace, so reading it as a directory handle gives
# the caller a callee that has never seen the conversation they asked for — and
# nothing in the payload says so (status connected, .workspace correct,
# .fallbacks empty, and the reply reads plausibly). There is deliberately no
# opt-out flag: "that repo, blank slate" is spelled by passing the workspace.
#
# The fixture is what makes the id resolvable at all: resolve-workspace.sh
# reverse-looks-up $HOME/.claude/projects/<encoded-cwd>/<uuid>.jsonl and reads the
# real cwd out of the transcript rather than decoding the lossy dir name, so the
# planted transcript carries a "cwd" field pointing at this sandbox's target.
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
TARGET_SESSION="5b1dda91-a3c1-45f9-b967-aa9dac221e59"
TGT_PATH=$(cd "$t/target" && pwd -P)
TGT_ENC=$(printf '%s' "$TGT_PATH" | sed 's|[^a-zA-Z0-9]|-|g')
mkdir -p "$t/home/.claude/projects/$TGT_ENC"
printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n' "$TGT_PATH" "$TARGET_SESSION" \
  > "$t/home/.claude/projects/$TGT_ENC/$TARGET_SESSION.jsonl"

: > "$OK_REQUESTS"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-sess1" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$TARGET_SESSION" --mode work_order --label "session target" \
    --prompt "what went wrong?" --boot-timeout 5 2>"$t/err.txt")
rc=$?
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
launch=$(launch_script_of "$call_dir")

[[ "$rc" -eq 0 && "$(jq -r .status <<<"$out")" == "connected" \
   && "$(jq -r .workspace <<<"$out")" == "$TGT_PATH" ]]
check "a session-id target connects, into the workspace that session lives in" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"

grep -q -- "--resume $TARGET_SESSION" <<<"$launch"
check "a session-id target RESUMES that session (no --resume flag needed)" $? \
  "launch=$launch"

# Forked by default, so hotline's protocol noise stays out of the original
# transcript. --session-id is REQUIRED alongside a fork and forbidden on a plain
# resume, which is why this asserts both halves.
grep -q -- '--fork-session' <<<"$launch"
check "…and forks it by default" $? "launch=$launch"
grep -q -- '--session-id' <<<"$launch"
check "…with --session-id, which a fork requires" $? "launch=$launch"

# --- --fresh contradicts it, and is refused rather than resolved -------------
# One says continue that conversation, the other says ignore what exists. Picking
# a winner would discard something the caller typed on purpose.
t2=$(new_env); note_leak "$t2"
make_cmux "$t2/bin"; make_side_opener "$t2/side.sh"
mkdir -p "$t2/home/.claude/projects/$TGT_ENC"
printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n' "$TGT_PATH" "$TARGET_SESSION" \
  > "$t2/home/.claude/projects/$TGT_ENC/$TARGET_SESSION.jsonl"
FRESH_OUT=$(PATH="$t2/bin:$PATH" HOME="$t2/home" CMUX_FAKE_STATE="$t2" \
  HOTLINE_CALLER_SESSION_ID="caller-sess2" \
  HOTLINE_OPEN_SIDE_SURFACE="$t2/side.sh" HOTLINE_PENDING_DIR="$t2/pending" \
  bash "$DIAL" --target "$TARGET_SESSION" --mode work_order --label "session+fresh" \
    --prompt "hi" --fresh --boot-timeout 5 2>/dev/null)
[[ "$(jq -r .status <<<"$FRESH_OUT")" == "error" \
   && "$(jq -r .stage <<<"$FRESH_OUT")" == "args" ]]
check "a session-id target with --fresh is refused at the args gate" $? "out=$FRESH_OUT"
# The refusal must name what the caller TYPED. Talking about --resume, a flag they
# never passed, reads as a bug in hotline rather than a choice they can act on.
[[ "$(jq -r .detail <<<"$FRESH_OUT")" == *"session id in --target"* ]]
check "…naming the session-id target, not a --resume flag nobody passed" $? \
  "detail=$(jq -r .detail <<<"$FRESH_OUT")"

# --- herdr cannot adopt a session, and a session-id target is one ------------
HERDR_OUT=$(PATH="$t2/bin:$PATH" HOME="$t2/home" CMUX_FAKE_STATE="$t2" \
  HOTLINE_CALLER_SESSION_ID="caller-sess3" \
  HOTLINE_OPEN_SIDE_SURFACE="$t2/side.sh" HOTLINE_PENDING_DIR="$t2/pending" \
  bash "$DIAL" --target "$TARGET_SESSION" --mode work_order --label "session+herdr" \
    --prompt "hi" --transport herdr --boot-timeout 5 2>/dev/null)
[[ "$(jq -r .status <<<"$HERDR_OUT")" == "error" \
   && "$(jq -r .stage <<<"$HERDR_OUT")" == "args" \
   && "$(jq -r .detail <<<"$HERDR_OUT")" == *"session id in --target"* ]]
check "a session-id target with --transport herdr is refused, naming the target" $? \
  "out=$HERDR_OUT"

# --- A WORKSPACE target is untouched by all of this --------------------------
# The regression this guards: making the id imply a resume must not make every
# dial imply one. Case 1 already pins "no --resume on a fresh first contact"; this
# pins that --fresh still WORKS on a workspace target, which is the combination
# the refusal above could have swallowed.
t3=$(new_env); note_leak "$t3"
make_cmux "$t3/bin"; make_side_opener "$t3/side.sh"
WS_FRESH_OUT=$(PATH="$t3/bin:$PATH" HOME="$t3/home" CMUX_FAKE_STATE="$t3" \
  HOTLINE_CALLER_SESSION_ID="caller-sess4" \
  HOTLINE_OPEN_SIDE_SURFACE="$t3/side.sh" HOTLINE_PENDING_DIR="$t3/pending" \
  bash "$DIAL" --target "$t3/target" --mode work_order --label "ws+fresh" \
    --prompt "hi" --fresh --boot-timeout 5 2>/dev/null)
ws_cd=$(jq -r '.call_dir // empty' <<<"$WS_FRESH_OUT" 2>/dev/null)
[[ -n "$ws_cd" ]] && note_leak "$ws_cd"
[[ -n "$ws_cd" ]] && note_leak "$(launch_script_of "$ws_cd" >/dev/null; true)"
[[ "$(jq -r .status <<<"$WS_FRESH_OUT")" == "connected" ]]
check "a workspace target with --fresh still connects (the refusal is scoped)" $? \
  "out=$WS_FRESH_OUT"

dial_wrapper_finish
