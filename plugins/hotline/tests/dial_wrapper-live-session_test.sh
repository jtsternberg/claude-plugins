#!/usr/bin/env bash
# =============================================================================
# dial.sh wrapper regression tests — a session-id target that is still LIVE in a
# surface the cache has forgotten (claude-plugins-wpbx).
#
# The cache is keyed caller→workspace, so a later dial into the same workspace takes
# the slot and the earlier session drops out of it while its REPL stays up.
# `--target <id> --no-fork` must not `claude --resume` a second REPL onto it:
# find-live-surface.sh recovers the surface from the call dirs, behind the same
# nonce-in-scrollback proof the cleanup path demands.
#
# One shard of the dial_wrapper suite; the stubs live in lib/dial-wrapper-harness.sh.
# =============================================================================
set -u
FAKE_CLAUDE_PID=990003
# shellcheck source=lib/dial-wrapper-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/dial-wrapper-harness.sh"

echo "dial.sh wrapper regression (live session id):"

LIVE_SESSION="a27965ca-f7bb-497e-8e19-e92b950cbda0"
LIVE_SURFACE="aaaa0000-1111-4111-8111-111111111111"
LIVE_NONCE="4aea15c2b450184f"

# live_env <screen-has-nonce:yes|no> → a scratch root where LIVE_SESSION lives in
# LIVE_SURFACE (a call dir says so) while the workspace's cache slot has moved on to
# a DIFFERENT session — the exact state the orchestrator hit.
live_env() {
  local t p enc
  t=$(new_env); note_leak "$t"
  make_cmux "$t/bin"; make_side_opener "$t/side.sh"
  if [[ "$1" == yes ]]; then
    printf 'turn %s\n\xe2\x9d\xaf\xc2\xa0\n' "$LIVE_NONCE" > "$t/screen.txt"
  else
    printf 'some other output\n\xe2\x9d\xaf\xc2\xa0\n' > "$t/screen.txt"
  fi
  p=$(cd "$t/target" && pwd -P)
  enc=$(printf '%s' "$p" | sed 's|[^a-zA-Z0-9]|-|g')
  mkdir -p "$t/home/.claude/projects/$enc" "$t/calls/hotline-call-OLD"
  printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n' "$p" "$LIVE_SESSION" \
    > "$t/home/.claude/projects/$enc/$LIVE_SESSION.jsonl"
  printf '%s' "$LIVE_SESSION" > "$t/calls/hotline-call-OLD/session_id.txt"
  printf '%s' "$LIVE_SURFACE" > "$t/calls/hotline-call-OLD/surface_ref.txt"
  printf '%s' "$LIVE_NONCE"   > "$t/calls/hotline-call-OLD/call_id.txt"
  HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$p" \
    --caller-session "caller-live" --session "11111111-2222-4333-8444-555555555555" \
    --mode work_order --surface "SURFACE-UUID-777"
  echo "$t"
}

# A live REPL writes the delivered turn into its transcript; the stubs have no callee,
# so this stands in for one: every NEW call id the socket stub echoes is appended to
# the session's transcript.
transcript_writer() {  # transcript_writer <root>  → background pid on stdout
  local t="$1" p enc base
  p=$(cd "$t/target" && pwd -P); enc=$(printf '%s' "$p" | sed 's|[^a-zA-Z0-9]|-|g')
  base=$(grep -o 'CALL_ID: [0-9a-f]\{16\}' "$SOCK_ECHO_FILE" 2>/dev/null | sort -u)
  (
    for _ in $(seq 1 200); do
      grep -o 'CALL_ID: [0-9a-f]\{16\}' "$SOCK_ECHO_FILE" 2>/dev/null | sort -u \
        | grep -vxF "$base" >> "$t/home/.claude/projects/$enc/$LIVE_SESSION.jsonl" 2>/dev/null
      sleep 0.05
    done
  ) >/dev/null 2>&1 &
  echo $!
}

# dial_live <root> [extra dial flags…]
dial_live() {
  local t="$1"; shift
  PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" HOTLINE_CALL_HOME="$t/calls" \
    HOTLINE_CALLER_SESSION_ID="caller-live" HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" \
    HOTLINE_PENDING_DIR="$t/pending" \
    bash "$DIAL" --target "$LIVE_SESSION" --mode work_order --label "live sid" \
      --prompt "next step" --boot-timeout 5 "$@" 2>"$t/err.txt"
}

# 1. Live session → follow-up into ITS surface, nothing launched.
t=$(live_env yes)
wpid=$(transcript_writer "$t")
out=$(dial_live "$t" --no-fork)
kill "$wpid" 2>/dev/null
cd_=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ "$(jq -r .status <<<"$out")" == "connected" && "$(jq -r .first_contact <<<"$out")" == "false" ]]
check "a live session id dials as a follow-up (first_contact=false)" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
[[ -n "$cd_" && ! -f "$cd_/launch_script.txt" && "$(last_paste surface_id)" == "$LIVE_SURFACE" \
   && "$(jq -r .surface_ref <<<"$out")" == "$LIVE_SURFACE" ]]
check "…pasted into the surface it lives in, launching no second REPL" $? \
  "call_dir=$cd_ surface=$(last_paste surface_id) out=$out"
[[ "$(jq -r '.fallbacks | map(select(startswith("live-session-adopted"))) | length' <<<"$out")" == "1" ]]
check "…and the adoption is reported in fallbacks" $? "out=$out"
[[ "$(jq -r .confirmed <<<"$out")" == "transcript" ]]
check "…delivery proven by the transcript tier" $? "out=$out"
[[ "$(jq -r '.fallbacks[] | select(startswith("live-session-adopted"))' <<<"$out")" == *"displaced cached 11111111-2222-4333-8444-555555555555"* ]]
check "…and names the cached session it displaced" $? "out=$out"

# 2. Surface no longer carries the exchange's nonce (repurposed or gone) → today's resume.
t=$(live_env no)
out=$(dial_live "$t" --no-fork)
cd_=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$cd_" ]] && launch_script_of "$cd_" >/dev/null
[[ "$(jq -r .first_contact <<<"$out")" == "true" && -n "$cd_" && -s "$cd_/launch_script.txt" \
   && "$(jq -r '.fallbacks | map(select(startswith("live-session-adopted"))) | length' <<<"$out")" == "0" ]]
check "an unprovable surface keeps today's resume in a new surface" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

# 3. The forked default is a NEW session, so a new surface is right and untouched.
t=$(live_env yes)
out=$(dial_live "$t")
cd_=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$cd_" ]] && launch_script_of "$cd_" >/dev/null
[[ "$(jq -r .first_contact <<<"$out")" == "true" && -n "$cd_" && -s "$cd_/launch_script.txt" \
   && "$(launch_script_of "$cd_")" == *"--fork-session"* ]]
check "the forked default still opens its own surface and forks" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

# 4. Reuse REFUSES the adopted session (no input box: its REPL is not at a prompt) →
#    an error naming the surface, and nothing launched. The fallback to a fresh
#    surface would `claude --resume` a second REPL onto the live session.
t=$(live_env yes)
printf 'turn %s\n$ \n' "$LIVE_NONCE" > "$t/screen.txt"
out=$(SIDE_OPENER_LOG="$t/side.log" dial_live "$t" --no-fork)
[[ "$(jq -r .status <<<"$out")" == "error" && "$(jq -r .stage <<<"$out")" == "deliver" \
   && "$(jq -r .detail <<<"$out")" == *"$LIVE_SURFACE"* ]]
check "an adopted session whose reuse refuses is an error naming its surface" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
[[ ! -e "$t/side.log" ]] && ! grep -q 'new-workspace\|new-surface\|new-split' "$t/cmux_calls" 2>/dev/null \
   && [[ -z "$(jq -r '.call_dir // empty' <<<"$out" | xargs -I{} sh -c 'cat {}/launch_script.txt 2>/dev/null')" ]]
check "…and launches nothing" $? "side=$(cat "$t/side.log" 2>/dev/null) calls=$(cat "$t/cmux_calls" 2>/dev/null)"

# 5. Screen-only confirmation of an adopted session: the surface may now host a
#    different session, so it is the unconfirmed-delivery error, not "connected".
t=$(live_env yes)
out=$(dial_live "$t" --no-fork)
[[ "$(jq -r .status <<<"$out")" == "error" && "$(jq -r .stage <<<"$out")" == "deliver" \
   && "$(jq -r .recovery <<<"$out")" == *"Do NOT re-dial"* ]]
check "a screen-only confirmation on an adopted session is an unconfirmed deliver error" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

# 6. The NEWEST call dir naming the session decides which surface it lives in.
t=$(live_env yes)
OTHER_SURFACE="bbbb0000-2222-4222-8222-222222222222"
mkdir -p "$t/calls/hotline-call-NEW"
printf '%s' "$LIVE_SESSION" > "$t/calls/hotline-call-NEW/session_id.txt"
printf '%s' "$OTHER_SURFACE" > "$t/calls/hotline-call-NEW/surface_ref.txt"
printf '%s' "$LIVE_NONCE"    > "$t/calls/hotline-call-NEW/call_id.txt"
touch -t 202001010000 "$t/calls/hotline-call-OLD/session_id.txt"
found=$(HOTLINE_CALL_HOME="$t/calls" PATH="$t/bin:$PATH" CMUX_FAKE_STATE="$t" \
  bash "$HOTLINE_DIR/skills/dial/scripts/find-live-surface.sh" "$LIVE_SESSION")
[[ "$(jq -r .surface_ref <<<"$found")" == "$OTHER_SURFACE" ]]
check "several call dirs name the session: the newest one wins" $? "found=$found"

dial_wrapper_finish
