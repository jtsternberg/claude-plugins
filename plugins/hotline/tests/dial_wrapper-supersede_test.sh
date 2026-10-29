#!/usr/bin/env bash
# =============================================================================
# dial.sh wrapper regression tests — a follow-up SUPERSEDES the same caller's
# previous, still-unresolved call into that session.
#
# Without the marker, the previous call's waiter read the follow-up's ringing
# prompt as a human reassigning the callee, sat out the 180s preempt grace and
# exited 3 naming the caller's own follow-up. The marker is written in the
# previous call dir; wait-for-response.sh turns it into exit 8
# (wait-for-response_test.sh pins that half).
#
# One shard of the dial_wrapper suite. The stubs, sockets and scratch-env
# helpers live in lib/dial-wrapper-harness.sh.
# =============================================================================
set -u
FAKE_CLAUDE_PID=990006
# shellcheck source=lib/dial-wrapper-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/dial-wrapper-harness.sh"

echo "dial.sh supersede marker:"

IDLE_SCREEN='some earlier output\n\xe2\x9d\xaf\xc2\xa0\n'
SID="66666666-6666-4666-8666-666666666666"

# A previous call dir, as a cmux side-placement first contact leaves it.
make_prev_call_dir() {  # $1 = scratch root, $2 = nonce → echoes the dir
  local d="$1/prev-call"
  mkdir -p "$d"
  echo "$2" > "$d/call_id.txt"
  echo "SURFACE-UUID-777" > "$d/surface_ref.txt"
  echo "true" > "$d/keep_workspace.txt"
  echo "$d"
}

follow_up_dial() {  # $1 = scratch root, $2 = caller session → stdout payload
  PATH="$1/bin:$PATH" HOME="$1/home" CMUX_FAKE_STATE="$1" \
    HOTLINE_CALLER_SESSION_ID="$2" HOTLINE_PENDING_DIR="$1/pending" \
    bash "$DIAL" --target "$1/target" --mode work_order --label "probe label" \
      --prompt "one more thing" --boot-timeout 5 2>"$1/err.txt"
}

# ===========================================================================
# 1. Same caller, previous call unresolved → the previous call dir names this one.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"
printf "$IDLE_SCREEN" > "$t/screen.txt"
prev=$(make_prev_call_dir "$t" "prevnonce000001")
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-6666" --session "$SID" --mode work_order \
  --surface "SURFACE-UUID-777" --call-id "prevnonce000001" --call-dir "$prev"
out=$(follow_up_dial "$t" "caller-6666")
rc=$?
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
new_nonce=$(jq -r '.call_id // empty' <<<"$out" 2>/dev/null)

[[ "$rc" -eq 0 && "$(jq -r .first_contact <<<"$out")" == "false" && -n "$call_dir" ]]
check "the follow-up connects into the live surface" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"

marker="$prev/superseded_by.json"
[[ -f "$marker" \
   && "$(jq -r .call_dir "$marker" 2>/dev/null)" == "$call_dir" \
   && "$(jq -r .call_id "$marker" 2>/dev/null)" == "$new_nonce" \
   && -n "$new_nonce" ]]
check "the previous call dir records superseded_by.json naming the new call dir and nonce" $? \
  "marker=$(cat "$marker" 2>/dev/null || echo '<missing>') call_dir=$call_dir nonce=$new_nonce"

# The NEXT follow-up must supersede THIS call, not the first one again.
[[ "$(HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" get "$t/target" \
       --caller-session "caller-6666" | jq -r '.last_call_dir // empty')" == "$call_dir" ]]
check "the cache's last_call_dir moves to the follow-up's call dir" $? \
  "cache=$(HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" get "$t/target" --caller-session caller-6666)"

# ===========================================================================
# 2. Previous call already resolved (`done`) → nothing to supersede.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"
printf "$IDLE_SCREEN" > "$t/screen.txt"
prev=$(make_prev_call_dir "$t" "prevnonce000002")
printf '{"session_id":"%s","response":"answered"}' "$SID" > "$prev/response.json"
touch "$prev/done"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-6666" --session "$SID" --mode work_order \
  --surface "SURFACE-UUID-777" --call-id "prevnonce000002" --call-dir "$prev"
out=$(follow_up_dial "$t" "caller-6666")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
[[ -n "$call_dir" && ! -e "$prev/superseded_by.json" ]]
check "a resolved previous call is not marked superseded" $? \
  "out=$out marker=$(cat "$prev/superseded_by.json" 2>/dev/null || echo '<none>')"

# ===========================================================================
# 3. A DIFFERENT caller's dial never touches this caller's call dir: the cache is
#    keyed by caller session, so it is first contact for them, and the other
#    caller's waiter keeps today's preempt verdict.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"
printf "$IDLE_SCREEN" > "$t/screen.txt"
prev=$(make_prev_call_dir "$t" "prevnonce000003")
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-AAAA" --session "$SID" --mode work_order \
  --surface "SURFACE-UUID-777" --call-id "prevnonce000003" --call-dir "$prev"
out=$(follow_up_dial "$t" "caller-BBBB")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
[[ ! -e "$prev/superseded_by.json" ]]
check "another caller's dial leaves this caller's call dir unmarked" $? \
  "out=$out marker=$(cat "$prev/superseded_by.json" 2>/dev/null || echo '<none>')"

dial_wrapper_finish
