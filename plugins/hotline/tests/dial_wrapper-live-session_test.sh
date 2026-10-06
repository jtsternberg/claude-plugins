#!/usr/bin/env bash
# =============================================================================
# dial.sh wrapper regression tests — a session-id target that is still LIVE in a
# surface the cache has forgotten (claude-plugins-wpbx).
#
# The cache is keyed caller→workspace, so a later dial into the same workspace takes
# the slot and the earlier session drops out of it while its REPL stays up.
# `--target <id> --no-fork` then used to `claude --resume` a second REPL onto it.
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
out=$(dial_live "$t" --no-fork)
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

dial_wrapper_finish
