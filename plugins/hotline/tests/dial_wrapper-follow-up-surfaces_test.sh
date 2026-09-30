#!/usr/bin/env bash
# =============================================================================
# dial.sh wrapper regression tests — follow-ups into detached callees, mid-turn
# delivery, superseded-surface cleanup, and --fresh (sections 6d2-6j).
#
# One shard of the dial_wrapper suite. The stubs, sockets and scratch-env
# helpers live in lib/dial-wrapper-harness.sh; the sibling
# dial_wrapper-*_test.sh shards hold the other sections.
# =============================================================================
set -u
FAKE_CLAUDE_PID=990003
# shellcheck source=lib/dial-wrapper-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/dial-wrapper-harness.sh"

echo "dial.sh wrapper regression:"

# ===========================================================================
# 6d2. A DETACHED callee is reusable (claude-plugins-zaus).
#
# A detached placement puts the callee in its own workspace tab, and the launcher
# used to record only that workspace. So the session cache held no surface, every
# follow-up recorded `surface-reuse-skipped(no-cached-surface)`, and a
# conversation of N turns opened N tabs — the callee mid-exchange in the first one
# and nobody ever speaking to it again.
#
# The launcher now resolves the surface inside that workspace and records its
# UUID, so a follow-up re-addresses the tab the callee is actually living in.
# Which host the WAITERS poll and close is decided by placement.txt instead, so
# the detached tab still auto-closes on completion (see wait-for-response_test.sh).
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"
# A REPL banner for the boot wait, and an idle input box so the first contact's
# paste has somewhere to land.
printf 'some earlier output\n\xe2\x9d\xaf\xc2\xa0\nClaude Code v2.1.221\n' > "$t/screen.txt"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-6d3" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order --placement detached \
    --label "probe label" --prompt "first contact, detached" --boot-timeout 8 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
launch_script_of "$call_dir" >/dev/null
target_real=$(cd "$t/target" && pwd -P)
cache_6d3="$t/home/.agents-hotline/sessions/caller-6d3.json"

[[ "$(jq -r .placement <<<"$out")" == "detached" \
   && "$(jq -r .first_contact <<<"$out")" == "true" \
   && "$(jq -r .status <<<"$out")" == "connected" ]]
check "a detached first contact connects and reports placement detached" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

# THE UUID, not the positional surface:900 the same tree entry carries. A ref names
# whatever sits in slot N, and slots renumber between now and the follow-up that
# reads this.
[[ "$(cat "$call_dir/surface_ref.txt" 2>/dev/null)" == "SURFACE-UUID-DETACHED" ]]
check "a detached first contact records the surface inside its workspace, by UUID" $? \
  "surface_ref=$(cat "$call_dir/surface_ref.txt" 2>/dev/null || echo NONE)"

[[ "$(cat "$call_dir/placement.txt" 2>/dev/null)" == "detached" \
   && "$(cat "$call_dir/workspace_ref.txt" 2>/dev/null)" == "workspace:123" \
   && "$(cat "$call_dir/workspace_id.txt" 2>/dev/null)" == "WORKSPACE-UUID-DETACHED" ]]
check "…alongside placement.txt=detached and the workspace as a UUID" $? \
  "placement=$(cat "$call_dir/placement.txt" 2>/dev/null) ws=$(cat "$call_dir/workspace_ref.txt" 2>/dev/null) wsid=$(cat "$call_dir/workspace_id.txt" 2>/dev/null)"

[[ "$(jq -r --arg t "$target_real" '.connections[$t].surface_ref' "$cache_6d3")" == "SURFACE-UUID-DETACHED" ]]
check "…and the session cache learns it, which is what a follow-up reads" $? \
  "$(cat "$cache_6d3" 2>/dev/null)"

# The follow-up: same target, cached session, live idle REPL in that surface. It
# must REUSE the tab rather than record the skip and open another one.
#
# `done` IS THE PRECONDITION, and it is in the fixture because the real flow puts
# it there: the caller runs wait-for-response.sh after dial.sh, and every terminal
# path of that wait writes `done` — including the AWAITING_REVIEW checkpoint, which
# is the detached exchange that ends with its tab still live and a follow-up
# expected. Without it the prior exchange is still waiting, and its own auto-close
# would destroy this message (see 6d-bis).
touch "$call_dir/done"
ws_before=$(grep -c 'new-workspace' "$t/cmux_calls" 2>/dev/null || echo 0)
out2=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-6d3" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order --placement detached \
    --label "probe label" --prompt "and now step 2" --boot-timeout 8 2>"$t/err2.txt")
call_dir2=$(jq -r '.call_dir // empty' <<<"$out2" 2>/dev/null)
[[ -n "$call_dir2" ]] && note_leak "$call_dir2"
ws_after=$(grep -c 'new-workspace' "$t/cmux_calls" 2>/dev/null || echo 0)

[[ "$(jq -r .first_contact <<<"$out2")" == "false" \
   && "$(jq -r .status <<<"$out2")" == "connected" ]] \
  && ! jq -e '.fallbacks | index("surface-reuse-skipped(no-cached-surface)")' <<<"$out2" >/dev/null 2>&1
check "a follow-up into a live detached callee does NOT record no-cached-surface" $? \
  "out2=$out2 stderr=$(cat "$t/err2.txt")"

[[ "$(jq -r '.fallbacks | length' <<<"$out2")" == "0" ]]
check "…it reuses the tab outright, with no fallback at all" $? "out2=$out2"

[[ "$ws_before" == "$ws_after" ]]
check "…and opens no second workspace (new-workspace count unchanged)" $? \
  "before=$ws_before after=$ws_after calls=$(cat "$t/cmux_calls" 2>/dev/null)"

# Placement is irrelevant once reuse succeeds: the callee is mid-conversation in
# that tab, and the reuse step runs before any placement decision.
[[ "$(jq -r .surface_ref <<<"$out2")" == "SURFACE-UUID-DETACHED" ]]
check "…re-addressing the same surface the first contact recorded" $? "out2=$out2"

# ===========================================================================
# 6d-bis. A follow-up delivered MID-TURN into a live detached callee does NOT
#         reuse the tab — the prior exchange's own waiter would destroy it.
#
# The detached placement is the one that auto-closes: its waiter reaches
# cleanup_workspace_and_script with keep_workspace=false and closes the WORKSPACE
# the moment the prior response is captured. cmux-reuse-surface.sh cannot see that
# coming — a mid-turn REPL with an empty input box reads as reusable — so the paste
# is accepted and ENQUEUED behind the live turn, the callee then finishes the PRIOR
# turn, and the prior waiter closes the tab with this message still in the queue.
# Dropped work order, plus a second waiter polling a corpse to its full budget.
#
# So an unfinished prior exchange (no `done` in its call dir) refuses reuse and
# opens a fresh tab: the old behaviour, which cost an extra tab and DID deliver.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"
printf 'some earlier output\n\xe2\x9d\xaf\xc2\xa0\nClaude Code v2.1.221\n' > "$t/screen.txt"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-6dbis" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order --placement detached \
    --label "probe label" --prompt "first contact, detached" --boot-timeout 8 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
launch_script_of "$call_dir" >/dev/null
target_real=$(cd "$t/target" && pwd -P)
cache_6dbis="$t/home/.agents-hotline/sessions/caller-6dbis.json"

# The cache has to KNOW which call dir to ask about, or the gate has nothing to
# read and every follow-up reuses blind.
[[ "$(jq -r --arg t "$target_real" '.connections[$t].last_call_dir' "$cache_6dbis")" == "$call_dir" ]]
check "a first contact records its call dir in the session cache" $? \
  "$(cat "$cache_6dbis" 2>/dev/null)"

# NO `touch done` here: the first exchange's waiter is still running.
ws_before=$(grep -c 'new-workspace' "$t/cmux_calls" 2>/dev/null || echo 0)
out2=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-6dbis" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order --placement detached \
    --label "probe label" --prompt "and now step 2" --boot-timeout 8 2>"$t/err2.txt")
call_dir2=$(jq -r '.call_dir // empty' <<<"$out2" 2>/dev/null)
[[ -n "$call_dir2" ]] && note_leak "$call_dir2"
[[ -n "$call_dir2" ]] && launch_script_of "$call_dir2" >/dev/null
ws_after=$(grep -c 'new-workspace' "$t/cmux_calls" 2>/dev/null || echo 0)

jq -e '.fallbacks | index("surface-reuse→fresh(detached-mid-turn: prior exchange still waiting)")' \
  <<<"$out2" >/dev/null 2>&1
check "a mid-turn follow-up into a detached callee refuses reuse, and says why" $? \
  "out2=$out2 stderr=$(cat "$t/err2.txt")"

[[ "$ws_after" -gt "$ws_before" ]]
check "…opening a fresh tab instead, which is the path that delivers the message" $? \
  "before=$ws_before after=$ws_after calls=$(cat "$t/cmux_calls" 2>/dev/null)"

# Once that wait HAS finished, the same follow-up reuses. `done` is the whole
# difference, so both arms are asserted against one fixture.
touch "$call_dir/done"
ws_before=$(grep -c 'new-workspace' "$t/cmux_calls" 2>/dev/null || echo 0)
out3=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-6dbis" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order --placement detached \
    --label "probe label" --prompt "and now step 3" --boot-timeout 8 2>"$t/err3.txt")
call_dir3=$(jq -r '.call_dir // empty' <<<"$out3" 2>/dev/null)
[[ -n "$call_dir3" ]] && note_leak "$call_dir3"
ws_after=$(grep -c 'new-workspace' "$t/cmux_calls" 2>/dev/null || echo 0)

[[ "$(jq -r '.fallbacks | length' <<<"$out3")" == "0" && "$ws_before" == "$ws_after" ]]
check "…and a finished one reuses the tab outright, opening no second workspace" $? \
  "out3=$out3 before=$ws_before after=$ws_after stderr=$(cat "$t/err3.txt")"

# ===========================================================================
# 6e. A follow-up that opens a NEW surface closes the one it superseded
#     (claude-plugins-n7xo).
#
# `claude --resume` in the new surface takes the session over, so the old surface
# holds a REPL nobody will speak to again. Nothing used to close it, and a long
# exchange accumulated one dead tab per turn.
#
# Reuse has to fail while the old surface stays readable and idle, which is
# exactly the lossy-send case: the nudge goes out, its nonce never appears, reuse
# falls back — and the old REPL is still sitting there idle.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
# The prior exchange's nonce is in scrollback (proof of identity), the REPL is
# idle, and the banner lets wait-for-session confirm the replacement booted.
printf '\xe2\x9d\xaf [CALL_ID: nonce-prev-1] the previous follow-up\n\nClaude Code v2.1.221\n\xe2\x9d\xaf\xc2\xa0\n' \
  > "$t/screen.txt"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-6e" --session "6e6e6e6e-6e6e-4e6e-8e6e-6e6e6e6e6e6e" \
  --mode work_order --surface "aaaa0000-1111-4111-8111-111111111111" --call-id "nonce-prev-1"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" CMUX_SOCKET_PATH="$REJECT_STALE_SOCK" \
  HOTLINE_CALLER_SESSION_ID="caller-6e" HOTLINE_CLEANUP_SETTLE=0 \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order --label "probe label" \
    --prompt "carry on please" --boot-timeout 5 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
launch_script_of "$call_dir" >/dev/null

jq -e '.fallbacks | index("surface-cleanup→closed(aaaa0000-1111-4111-8111-111111111111)")' <<<"$out" >/dev/null 2>&1
check "the superseded surface is closed, and the close is reported" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

grep -q 'close-surface --workspace WORKSPACE-UUID-1 --surface aaaa0000-1111-4111-8111-111111111111' \
  "$t/close_calls" 2>/dev/null
check "the close targets the OLD surface by handle, with its workspace" $? \
  "close_calls=$(cat "$t/close_calls" 2>/dev/null)"

! grep -q 'surface SURFACE-UUID-777' "$t/close_calls" 2>/dev/null
check "the replacement surface is never the one closed" $? \
  "close_calls=$(cat "$t/close_calls" 2>/dev/null)"

# Without a recorded nonce there is nothing tying the handle to our exchange, so
# cleanup must refuse — and say so rather than closing on a weaker signal.
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
printf 'Request interrupted by user\nWhat should Claude do instead?\nClaude Code v2.1.221\n\xe2\x9d\xaf\xc2\xa0\n' \
  > "$t/screen.txt"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-6f" --session "6f6f6f6f-6f6f-4f6f-8f6f-6f6f6f6f6f6f" \
  --mode work_order --surface "aaaa0000-1111-4111-8111-111111111111"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-6f" HOTLINE_CLEANUP_SETTLE=0 \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order --label "probe label" \
    --prompt "carry on please" --boot-timeout 5 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
launch_script_of "$call_dir" >/dev/null

jq -e '.fallbacks | map(startswith("surface-cleanup-skipped")) | any' <<<"$out" >/dev/null 2>&1
check "a cleanup that cannot prove identity records a skip" $? "out=$out"

[[ ! -s "$t/close_calls" ]]
check "…and closes nothing" $? "close_calls=$(cat "$t/close_calls" 2>/dev/null)"

# A cache written by an older plugin version holds a POSITIONAL surface:N ref.
# Closing on that is unsafe in a way the nonce cannot rescue: the replacement
# resumed the same session, so its scrollback replays the same nonce, and a
# repositioned ref could name the replacement rather than the superseded surface.
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
printf '\xe2\x9d\xaf [CALL_ID: nonce-prev-3] the previous follow-up\n\nClaude Code v2.1.221\n\xe2\x9d\xaf\xc2\xa0\n' \
  > "$t/screen.txt"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-6h" --session "6h6h6h6h-6h6h-4h6h-8h6h-6h6h6h6h6h6h" \
  --mode work_order --surface "surface:211" --call-id "nonce-prev-3"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" CMUX_SOCKET_PATH="$REJECT_STALE_SOCK" \
  HOTLINE_CALLER_SESSION_ID="caller-6h" HOTLINE_CLEANUP_SETTLE=0 \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order --label "probe label" \
    --prompt "carry on please" --boot-timeout 5 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
launch_script_of "$call_dir" >/dev/null

jq -e '.fallbacks | map(contains("positional-ref-unsafe")) | any' <<<"$out" >/dev/null 2>&1
check "a positional cached ref is never closed, and says why" $? "out=$out"

[[ ! -s "$t/close_calls" ]]
check "…and nothing is closed for it" $? "close_calls=$(cat "$t/close_calls" 2>/dev/null)"

# The opt-out reaches the cleanup through dial.sh, not just the script.
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
printf '\xe2\x9d\xaf [CALL_ID: nonce-prev-2] the previous follow-up\n\nClaude Code v2.1.221\n\xe2\x9d\xaf\xc2\xa0\n' \
  > "$t/screen.txt"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-6g" --session "6g6g6g6g-6g6g-4g6g-8g6g-6g6g6g6g6g6g" \
  --mode work_order --surface "aaaa0000-1111-4111-8111-111111111111" --call-id "nonce-prev-2"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" CMUX_SOCKET_PATH="$REJECT_STALE_SOCK" \
  HOTLINE_CALLER_SESSION_ID="caller-6g" HOTLINE_CLOSE_SUPERSEDED=0 \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order --label "probe label" \
    --prompt "carry on please" --boot-timeout 5 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
launch_script_of "$call_dir" >/dev/null

jq -e '.fallbacks | index("surface-cleanup-skipped(disabled)")' <<<"$out" >/dev/null 2>&1
check "HOTLINE_CLOSE_SUPERSEDED=0 reaches cleanup through dial.sh" $? "out=$out"

[[ ! -s "$t/close_calls" ]]
check "…and nothing is closed when it is off" $? \
  "close_calls=$(cat "$t/close_calls" 2>/dev/null)"

# ===========================================================================
# 6j. --fresh ignores the cached session AND its surface (claude-plugins-osrz).
#
# Without it, forcing a new callee session meant hand-deleting the caller→target
# entry from the sessions registry — and an orchestration run that skipped that
# step got its "reviewer" as the implementer resumed. The flag has to do three
# things at once: not resume, leave the cache pointing at the NEW session (or the
# next dial routes back to the abandoned one), and hand the surface it walked away
# from to the same cleanup a follow-up's superseded surface gets.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
: > "$OK_REQUESTS"
# The prior exchange's nonce is in scrollback (cleanup's identity proof), the REPL
# is idle, and the banner + input box let the REPLACEMENT surface confirm boot and
# take the paste through the same stub screen.
printf '\xe2\x9d\xaf [CALL_ID: nonce-fresh-1] the previous exchange\n\nClaude Code v2.1.221\n\xe2\x9d\xaf\xc2\xa0\n' \
  > "$t/screen.txt"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-6j" --session "6a6a6a6a-6a6a-4a6a-8a6a-6a6a6a6a6a6a" \
  --mode work_order --surface "aaaa0000-1111-4111-8111-111111111111" --call-id "nonce-fresh-1"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-6j" HOTLINE_CLEANUP_SETTLE=0 \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order --label "probe label" --fresh \
    --prompt "review the branch with no prior context" --boot-timeout 5 2>"$t/err.txt")
rc=$?
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
launch=$(launch_script_of "$call_dir")
cache_6j="$t/home/.agents-hotline/sessions/caller-6j.json"
target_real=$(cd "$t/target" && pwd -P)

[[ "$rc" -eq 0 && "$(jq -r .status <<<"$out")" == "connected" \
   && "$(jq -r .first_contact <<<"$out")" == "true" ]]
check "--fresh connects and reports first_contact=true despite a cached session" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"

grep -q -- '--resume' <<<"$launch"
if [[ $? -eq 0 ]]; then
  fail "--fresh resumes nothing — the whole point of the flag" "launch=$launch"
else
  pass "--fresh resumes nothing — the whole point of the flag"
fi

jq -e '.fallbacks | index("session-cache→fresh(6a6a6a6a-6a6a-4a6a-8a6a-6a6a6a6a6a6a)")' \
  <<<"$out" >/dev/null 2>&1
check "the ignored session is named in fallbacks, not silently dropped" $? "out=$out"

# A brand-new session needs the ringing protocol loaded, which is the first-contact
# wrapper — a --fresh dial that sent the raw message would reach a callee that
# never loaded the skill.
grep -q '/hotline:hotline-ringing' <<<"$(nth_paste 1)" \
  && ! grep -qF '[FOLLOW_UP]' <<<"$(nth_paste 1)"
check "--fresh delivers the first-contact ringing invocation, not a [FOLLOW_UP]" $? "paste1=$(nth_paste 1)"

new_session=$(jq -r .remote_session_id <<<"$out")
[[ -n "$new_session" && "$new_session" != "6a6a6a6a-6a6a-4a6a-8a6a-6a6a6a6a6a6a" ]]
check "the callee session is a new one, not the cached one" $? "out=$out"

[[ "$(jq -r --arg t "$target_real" '.connections[$t].session_id' "$cache_6j")" == "$new_session" ]]
check "the cache is rewritten to the NEW session (the next dial must not route back)" $? \
  "$(cat "$cache_6j" 2>/dev/null)"

[[ "$(jq -r --arg t "$target_real" '.connections[$t].surface_ref' "$cache_6j")" == "SURFACE-UUID-777" ]]
check "…and to the new surface" $? "$(cat "$cache_6j" 2>/dev/null)"

[[ "$(jq -r --arg t "$target_real" '.connections[$t].exchange_count' "$cache_6j")" == "1" ]]
check "…as a fresh entry, not a bumped one" $? "$(cat "$cache_6j" 2>/dev/null)"

jq -e '.fallbacks | index("surface-cleanup→closed(aaaa0000-1111-4111-8111-111111111111)")' \
  <<<"$out" >/dev/null 2>&1
check "the surface --fresh walked away from goes through the normal cleanup" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

grep -q 'close-surface --workspace WORKSPACE-UUID-1 --surface aaaa0000-1111-4111-8111-111111111111' \
  "$t/close_calls" 2>/dev/null
check "the close targets the abandoned surface by handle, with its workspace" $? \
  "close_calls=$(cat "$t/close_calls" 2>/dev/null)"

! grep -q 'surface SURFACE-UUID-777' "$t/close_calls" 2>/dev/null
check "the new surface is never the one closed" $? \
  "close_calls=$(cat "$t/close_calls" 2>/dev/null)"

# 6j-b. --fresh with nothing cached is an ordinary first contact — no fallback,
# because nothing was worked around.
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-6j-b" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order --label "probe label" --fresh \
    --prompt "nothing to ignore here" --boot-timeout 5 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
launch_script_of "$call_dir" >/dev/null

[[ "$(jq -r .status <<<"$out")" == "connected" \
   && "$(jq -r '.fallbacks | length' <<<"$out")" -eq 0 ]]
check "--fresh with no cached session records no fallback" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

[[ ! -s "$t/close_calls" ]]
check "…and closes nothing (there was no surface to supersede)" $? \
  "close_calls=$(cat "$t/close_calls" 2>/dev/null)"

# 6j-c. --fresh and --resume are opposite instructions about which session to talk
# to. Resolving it either way silently hands the caller the one they did not ask
# for, so it is an args error — the same stage every other flag contradiction uses.
t=$(new_env); note_leak "$t"
for order in "--fresh --resume 12345678-1234-4234-8234-123456789abc" \
             "--resume 12345678-1234-4234-8234-123456789abc --fresh"; do
  o=$(PATH="$t/bin:$PATH" HOME="$t/home" HOTLINE_CALLER_SESSION_ID="caller-6j-c" \
      HOTLINE_PENDING_DIR="$t/pending" \
      timeout 10 bash "$DIAL" --target "$t/target" --mode quick --label "probe label" --prompt x \
        $order 2>/dev/null)
  rc=$?
  [[ "$rc" -eq 1 && "$(jq -r '.stage // empty' <<<"$o" 2>/dev/null)" == "args" ]] \
    && grep -q -- '--fresh' <<<"$o"
  check "--fresh with --resume is an args error ($order)" $? "rc=$rc out=$o"
done

dial_wrapper_finish
