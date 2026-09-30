#!/usr/bin/env bash
# =============================================================================
# dial.sh wrapper regression tests — follow-ups: surface reuse, refusal and
# resume, the reuse guard's fallbacks, and clearing the cached surface (sections
# 5-6c).
#
# One shard of the dial_wrapper suite. The stubs, sockets and scratch-env
# helpers live in lib/dial-wrapper-harness.sh; the sibling
# dial_wrapper-*_test.sh shards hold the other sections.
# =============================================================================
set -u
# shellcheck source=lib/dial-wrapper-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/dial-wrapper-harness.sh"

echo "dial.sh wrapper regression:"

# ===========================================================================
# 5. Follow-up reuses the surface the session already lives in.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"
# An idle claude REPL: an empty input box, no spinner, no interrupt prompt.
printf 'some earlier output\n\xe2\x9d\xaf\xc2\xa0\n' > "$t/screen.txt"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-5555" --session "55555555-5555-4555-8555-555555555555" \
  --mode work_order --surface "SURFACE-UUID-777"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-5555" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order --label "probe label" \
    --prompt "one more thing" --boot-timeout 5 2>"$t/err.txt")
rc=$?
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"

[[ "$rc" -eq 0 && "$(jq -r .status <<<"$out")" == "connected" \
   && "$(jq -r .first_contact <<<"$out")" == "false" ]]
check "follow-up connects with first_contact=false" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"

# A follow-up into a live REPL re-invokes the ringing command, tagged [FOLLOW_UP],
# and rides the same two-paste delivery as first contact: invocation line alone on
# paste 1, message on paste 2. Pasted RAW, a multi-line message reaches the callee
# as a <pasted_content> block, which the harness tells it not to take instructions
# from — so the callee refused the work it was sent (claude-plugins-2i6g). Through
# the command, the message lands in command-args, the channel first contact uses.
# The request log is suite-wide, so this delivery's pastes are the LAST two.
n=$(paste_count)
invite="$(nth_paste $((n - 1)))"
pasted="$(nth_paste "$n")"
[[ "$pasted" == 'one more thing' \
   && "$(nth_paste $((n - 1)) surface_id)" == "SURFACE-UUID-777" \
   && "$(nth_paste "$n" surface_id)" == "SURFACE-UUID-777" ]]
check "the follow-up message is pasted into the existing surface, invocation then body" $? \
  "invite=$invite pasted=$pasted count=$(paste_count) surface=$(last_paste surface_id)"

[[ "$invite" == '/hotline:hotline-ringing [CALL_ID: '*'] [FOLLOW_UP] [MODE: work_order] [CALLER: '*'] [SESSION: caller-5555]' ]]
check "the follow-up invocation carries the nonce inline, then [FOLLOW_UP] and the protocol tags" $? \
  "invite=$(printf '%q' "$invite")"

[[ "$invite" != *$'\n'* && "$invite" != *'one more thing'* ]]
check "the follow-up invocation paste is one line with no message glued on" $? \
  "invite=$(printf '%q' "$invite")"

# No `cmux send` of the payload: it never touches the transport that used to lose
# bytes from it. The one Enter is the split's submit, sent as a key event outside
# either bracketed paste.
if [[ "$(grep -c . "$t/sendkey_calls" 2>/dev/null || true)" -le 1 ]]; then
  pass "reuse sends at most the split's one submit Enter"
else
  fail "reuse sends at most the split's one submit Enter" "sendkey_calls=$(cat "$t/sendkey_calls")"
fi
if grep -q 'one more thing' "$t/send_calls" 2>/dev/null; then
  fail "the payload never goes out through cmux send" "send_calls=$(cat "$t/send_calls")"
else
  pass "the payload never goes out through cmux send"
fi

# Reuse must not open a surface, so no launch script is ever written.
[[ -n "$call_dir" && ! -f "$call_dir/launch_script.txt" ]]
check "reuse opens no new surface (no launch script)" $? "call_dir=$call_dir"

target_real=$(cd "$t/target" && pwd -P)
[[ "$(jq -r --arg t "$target_real" '.connections[$t].exchange_count' \
      "$t/home/.agents-hotline/sessions/caller-5555.json" 2>/dev/null)" == "2" ]]
check "reuse bumps the cache's exchange_count" $? \
  "$(cat "$t/home/.agents-hotline/sessions/caller-5555.json" 2>/dev/null)"

[[ "$(jq -r '.fallbacks | length' <<<"$out")" -eq 0 ]]
check "a successful reuse records no fallbacks" $? "out=$out"

# HOW it landed travels with the connection. `confirmed` names the tier that proved
# delivery (transcript is definitive, screen is inference) and `retried_enter` says
# whether the paste's own submit key had to be rescued by a corrective Enter — a run
# of those is the submit_key race resurfacing (claude-plugins-fkgv, -y4rl), which is
# invisible to the caller if the wrapper drops the fields cmux-paste.sh reports.
jq -e '(.confirmed | type == "string") and (.confirmed | length > 0)
       and (.retried_enter | type == "boolean")' <<<"$out" >/dev/null 2>&1
check "a successful reuse reports .confirmed and .retried_enter" $? "out=$out"

# ===========================================================================
# 6. Follow-up whose surface refuses the message → resume into a fresh surface.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
# One screen has to serve three readers here: cmux-reuse-surface.sh sees the
# post-interrupt prompt and declines; wait-for-session.sh (polling the NEW surface
# through the same stub) needs the REPL banner to confirm boot; and cmux-paste.sh
# needs a drawn input box before it will paste into that new surface.
printf 'Request interrupted by user\nWhat should Claude do instead?\nClaude Code v2.1.221\n\xe2\x9d\xaf\xc2\xa0\n' \
  > "$t/screen.txt"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-6666" --session "66666666-6666-4666-8666-666666666666" \
  --mode work_order --surface "SURFACE-UUID-OLD"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-6666" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order --label "probe label" \
    --prompt "please continue" --boot-timeout 5 2>"$t/err.txt")
rc=$?
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
launch=$(launch_script_of "$call_dir")

[[ "$rc" -eq 0 && "$(jq -r .status <<<"$out")" == "connected" \
   && "$(jq -r .first_contact <<<"$out")" == "false" ]]
check "a refused reuse still completes via the fresh-surface path" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"

jq -e '.fallbacks | map(startswith("surface-reuse→fresh")) | any' <<<"$out" >/dev/null 2>&1
check "the refusal (and its reason) is recorded in fallbacks" $? "out=$out"

grep -q -- '--resume 66666666-6666-4666-8666-666666666666' <<<"$launch"
check "resume-fresh resumes OUR cached session" $? "launch=$launch"

grep -q -- '--fork-session' <<<"$launch"
if [[ $? -eq 0 ]]; then
  fail "resume-fresh never forks our own session" "launch=$launch"
else
  pass "resume-fresh never forks our own session"
fi

grep -q -- '--session-id' <<<"$launch"
if [[ $? -eq 0 ]]; then
  fail "plain resume omits --session-id (claude rejects the combination)" "launch=$launch"
else
  pass "plain resume omits --session-id (claude rejects the combination)"
fi

[[ "$(jq -r .surface_ref <<<"$out")" == "SURFACE-UUID-777" ]]
check "the new surface handle replaces the dead one in the payload" $? "out=$out"

target_real=$(cd "$t/target" && pwd -P)
[[ "$(jq -r --arg t "$target_real" '.connections[$t].surface_ref' \
      "$t/home/.agents-hotline/sessions/caller-6666.json" 2>/dev/null)" == "SURFACE-UUID-777" ]]
check "the cache is self-healed to the new surface for the next follow-up" $? \
  "$(cat "$t/home/.agents-hotline/sessions/caller-6666.json" 2>/dev/null)"

# A multi-line follow-up REUSES the live surface (claude-plugins-i8fb). It used
# to skip reuse outright, which is what stacked a new pane on every substantive
# work-order follow-up — and then, briefly, to reuse it by writing the payload to
# a sidecar file and typing a pointer. Now the payload itself is pasted, whole.
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
printf 'some earlier output\n\xe2\x9d\xaf\xc2\xa0\nClaude Code v2.1.221\n' > "$t/screen.txt"
# A work-order-sized payload with a sentinel at the very END: a delivery that
# truncates or splits the body loses the tail first, so the sentinel arriving is
# what proves the whole thing went in one piece.
{ for i in $(seq 1 12); do echo "follow-up detail line $i of the work order"; done
  echo 'TAIL-SENTINEL-9Q'; } > "$t/msg.txt"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-7777" --session "77777777-7777-4777-8777-777777777777" \
  --mode work_order --surface "SURFACE-UUID-OLD"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-7777" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order --label "probe label" \
    --prompt-file "$t/msg.txt" --boot-timeout 5 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"

[[ "$(jq -r .status <<<"$out")" == "connected" \
   && "$(jq -r .surface_ref <<<"$out")" == "SURFACE-UUID-OLD" \
   && -n "$call_dir" && ! -f "$call_dir/launch_script.txt" ]]
check "a multi-line follow-up reuses the live surface, opening no second one" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

# The WHOLE message, in the body paste, tail included.
[[ "$(last_paste)" == "$(cat "$t/msg.txt")" \
   && "$(nth_paste $(( $(paste_count) - 1 )))" == '/hotline:hotline-ringing '*'[FOLLOW_UP]'* ]]
check "the multi-line message is pasted byte-identical as the body, tail sentinel and all" $? \
  "pasted=$(printf '%q' "$(last_paste)")"

# No sidecar, and nothing for the callee to go read outside its own workspace.
[[ ! -f "$call_dir/message.md" ]]
check "no message.md sidecar is written" $? "call_dir contents: $(ls -A "$call_dir" 2>/dev/null | tr '\n' ' ')"

[[ ! -f "$call_dir/payload.txt" ]]
check "the payload vehicle is cleaned out of the call dir" $? \
  "call_dir contents: $(ls -A "$call_dir" 2>/dev/null | tr '\n' ' ')"

if grep -q 'TAIL-SENTINEL-9Q' "$t/send_calls" 2>/dev/null; then
  fail "the payload never crosses cmux send" "send_calls=$(cat "$t/send_calls")"
else
  pass "the payload never crosses cmux send"
fi

[[ "$(jq -r '.fallbacks | length' <<<"$out")" -eq 0 ]]
check "reusing for a multi-line follow-up records no fallback (nothing degraded)" $? \
  "out=$out"

target_real=$(cd "$t/target" && pwd -P)
[[ "$(jq -r --arg t "$target_real" '.connections[$t].exchange_count' \
      "$t/home/.agents-hotline/sessions/caller-7777.json")" == "2" \
   && "$(jq -r --arg t "$target_real" '.connections[$t].last_call_id' \
      "$t/home/.agents-hotline/sessions/caller-7777.json")" == "$(jq -r .call_id <<<"$out")" ]]
check "the reuse bumps the cache and records this exchange's nonce" $? \
  "$(cat "$t/home/.agents-hotline/sessions/caller-7777.json" 2>/dev/null)"

# ===========================================================================
# 6b. Every bail out of the reuse guard records a fallback (claude-plugins-6nbr).
#
# The add_fallback for a refusal used to live inside the block the guard skipped,
# so a follow-up that opened a second pane reported fallbacks:[] — identical to a
# clean first-contact dial, with nothing to explain the new tab.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
printf 'some earlier output\n\xe2\x9d\xaf\xc2\xa0\nClaude Code v2.1.221\n' > "$t/screen.txt"
# A cached session with NO surface: what a headless or detached first contact
# leaves behind, and what --clear-surface leaves after a degraded follow-up.
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-6b" --session "6b6b6b6b-6b6b-4b6b-8b6b-6b6b6b6b6b6b" \
  --mode work_order
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-6b" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order --label "probe label" \
    --prompt "single line, but nowhere to type it" --boot-timeout 5 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
launch_script_of "$call_dir" >/dev/null

jq -e '.fallbacks | index("surface-reuse-skipped(no-cached-surface)")' <<<"$out" >/dev/null 2>&1
check "a follow-up with no cached surface records the skip" $? "out=$out"

[[ "$(jq -r .first_contact <<<"$out")" == "false" && "$(jq -r .status <<<"$out")" == "connected" ]]
check "…and still completes as a follow-up via the fresh path" $? "out=$out"

# The same fall-through, DETACHED: the label still has to reach the new workspace.
# FIRST_CONTACT stays false here — it answers "did this dial have a cached session"
# and one existed — but the launch it falls through to opens a BRAND-NEW workspace,
# and a detached callee's workspace name is the only name the tab strip has for it.
# Gating --label on FIRST_CONTACT named that workspace a bare `hotline`.
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"
printf 'some earlier output\n\xe2\x9d\xaf\xc2\xa0\nClaude Code v2.1.221\n' > "$t/screen.txt"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-6b2" --session "6b2b6b2b-6b2b-4b2b-8b2b-6b2b6b2b6b2b" \
  --mode work_order
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-6b2" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order --placement detached \
    --label "probe label" --prompt "and now step 2" --boot-timeout 8 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"

[[ "$(jq -r .first_contact <<<"$out")" == "false" \
   && "$(jq -r .placement <<<"$out")" == "detached" ]] \
  && jq -e '.fallbacks | index("surface-reuse-skipped(no-cached-surface)")' <<<"$out" >/dev/null 2>&1
check "a detached follow-up falls through to a fresh workspace (first_contact false)" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

grep -q -- 'new-workspace .*--name hotline: probe label' "$t/cmux_calls"
check "…and that workspace carries the label, not a bare 'hotline'" $? \
  "cmux calls: $(cat "$t/cmux_calls" 2>/dev/null)"

# ===========================================================================
# 6c. A follow-up that ends with NO surface CLEARS the cached one
#     (claude-plugins-2caw).
#
# Two ways to get there: the cmux→headless fold-in, and side placement degrading
# to detached. Both used to leave the previous surface_ref in the cache, so the
# next follow-up passed the reuse guard and typed into a surface this session had
# already left — the message landing in a REPL nobody was reading.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_claude "$t/bin"
# The reuse guard runs BEFORE the transport fold-in, so a usable cached surface
# would be reused and the headless path never reached. Stage a REPL that refuses
# the follow-up (post-interrupt state) so the call falls through to the transport
# decision, which is what this case is about.
printf 'Request interrupted by user\nWhat should Claude do instead?\nClaude Code v2.1.221\n\xe2\x9d\xaf\xc2\xa0\n' \
  > "$t/screen.txt"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-6c" --session "6c6c6c6c-6c6c-4c6c-8c6c-6c6c6c6c6c6c" \
  --mode work_order --surface "SURFACE-UUID-STALE"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-6c" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/nope.sh" HOTLINE_PLUGINS_DIR="$t/empty" \
  HOTLINE_PENDING_DIR="$t/pending" \
  FAKE_CLAUDE_SESSION_ID="6c6c6c6c-6c6c-4c6c-8c6c-6c6c6c6c6c6c" \
  FAKE_CLAUDE_STDIN_LOG="$t/claude_stdin.txt" \
  bash "$DIAL" --target "$t/target" --mode work_order --label "probe label" \
    --prompt "fold me into headless" --boot-timeout 8 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
target_real=$(cd "$t/target" && pwd -P)
cache_6c="$t/home/.agents-hotline/sessions/caller-6c.json"

[[ "$(jq -r .transport <<<"$out")" == "headless" ]]
check "the headless fold-in still applies on a follow-up" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

[[ "$(jq -r --arg t "$target_real" '.connections[$t] | has("surface_ref")' "$cache_6c")" == "false" ]]
check "a headless follow-up CLEARS the stale surface_ref" $? "$(cat "$cache_6c" 2>/dev/null)"

# The [FOLLOW_UP] invocation is for an interactive REPL, where a raw paste reaches
# the callee as <pasted_content>. `claude -p --resume` takes the message as the
# prompt itself, so it stays raw — even when the dial decided the transport was
# cmux first and folded into headless afterwards.
for _ in $(seq 1 40); do [[ -s "$t/claude_stdin.txt" ]] && break; sleep 0.1; done
[[ "$(cat "$t/claude_stdin.txt" 2>/dev/null)" == *'fold me into headless' ]] \
  && ! grep -q 'hotline-ringing' "$t/claude_stdin.txt"
check "a follow-up folded into headless sends the RAW message, not the [FOLLOW_UP] invocation" $? \
  "stdin=$(cat "$t/claude_stdin.txt" 2>/dev/null)"

# Side placement degrading to detached: open-side-surface exits 2 with the
# identify diagnostic cmux-call-async.sh keys on, so the call lands in its own
# workspace instead — and records degraded.txt, which is what dial.sh reads to
# report the fallback now that the absence of a surface handle no longer means it.
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_claude "$t/bin"
# Same two-readers screen as case 6: cmux-reuse-surface.sh sees the post-interrupt
# prompt and declines (so the call reaches the placement decision), while
# wait-for-session.sh needs the REPL banner to confirm the detached boot.
printf 'Request interrupted by user\nWhat should Claude do instead?\nClaude Code v2.1.221\n\xe2\x9d\xaf\xc2\xa0\n' \
  > "$t/screen.txt"
cat > "$t/side-degrade.sh" <<'EOF'
#!/usr/bin/env bash
echo "open-side-surface: could not resolve caller pane from identify" >&2
exit 2
EOF
chmod +x "$t/side-degrade.sh"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-6d" --session "6d6d6d6d-6d6d-4d6d-8d6d-6d6d6d6d6d6d" \
  --mode work_order --surface "SURFACE-UUID-STALE"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-6d" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side-degrade.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order --label "probe label" \
    --prompt "degrade me to detached" --boot-timeout 8 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
launch_script_of "$call_dir" >/dev/null
target_real=$(cd "$t/target" && pwd -P)
cache_6d="$t/home/.agents-hotline/sessions/caller-6d.json"

[[ "$(jq -r .placement <<<"$out")" == "detached" ]] \
  && jq -e '.fallbacks | index("surface-context→detached")' <<<"$out" >/dev/null 2>&1
check "side placement degrades to detached and says so" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

# A DEGRADED-TO-DETACHED FOLLOW-UP RE-KEYS THE CACHE, it no longer clears it.
# Case 6c's rule is unchanged and is the reason this one reads the way it does: a
# follow-up must never leave the cache pointing at a surface this session has left
# (claude-plugins-2caw). What changed is that a detached callee HAS a surface —
# the one inside the workspace it just opened — so the honest value is that handle,
# not nothing. Clearing it was what made the next follow-up open a third tab
# (claude-plugins-zaus).
[[ "$(jq -r --arg t "$target_real" '.connections[$t].surface_ref' "$cache_6d")" == "SURFACE-UUID-DETACHED" ]]
check "a degraded-to-detached follow-up re-keys the cache to the detached surface" $? \
  "$(cat "$cache_6d" 2>/dev/null)"

[[ "$(jq -r .surface_ref <<<"$out")" == "SURFACE-UUID-DETACHED" ]]
check "…and reports that handle, so the caller can see which surface hosts it" $? "out=$out"

# The OTHER shape of the same failure: the caller's context resolved fine, but
# cmux then refused the target with `not_found` — open-side-surface exits 1, not
# 2. A callee dialing onward hits this, because its inherited CMUX_WORKSPACE_ID
# names a different workspace than the one hosting its pane. This used to
# hard-error at stage `boot` and make the user re-dial with --placement detached
# by hand, even though detached opens its own workspace and so never needed the
# caller's context at all.
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_claude "$t/bin"
printf 'Request interrupted by user\nWhat should Claude do instead?\nClaude Code v2.1.221\n\xe2\x9d\xaf\xc2\xa0\n' \
  > "$t/screen.txt"
cat > "$t/side-notfound.sh" <<'EOF'
#!/usr/bin/env bash
echo "open-side-surface: cmux new-surface --pane pane:7 --type terminal failed:" >&2
echo "Error: not_found: Workspace not found" >&2
exit 1
EOF
chmod +x "$t/side-notfound.sh"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-6d2" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side-notfound.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order --label "probe label" \
    --prompt "not_found should degrade too" --boot-timeout 8 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"

[[ "$(jq -r .placement <<<"$out")" == "detached" ]] \
  && jq -e '.fallbacks | index("surface-context→detached")' <<<"$out" >/dev/null 2>&1
check "a not_found from open-side-surface degrades to detached, not a boot error" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

dial_wrapper_finish
