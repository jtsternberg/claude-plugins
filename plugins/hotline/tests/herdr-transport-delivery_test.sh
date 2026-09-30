#!/usr/bin/env bash
# =============================================================================
# herdr transport regression tests: delivery (herdr-prompt.sh), the waiters' herdr
# branch, and blocked-state reporting (sections 3, 4, 7).
#
# One shard of the herdr-transport suite. What the suite pins, the stubs and
# their knobs live in lib/herdr-transport-harness.sh; the sibling
# herdr-transport-*_test.sh shards hold the other sections.
# =============================================================================
set -u
# shellcheck source=lib/herdr-transport-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/herdr-transport-harness.sh"

# ===========================================================================
echo ""
echo "3. Delivery (herdr-prompt.sh) — one proof tier, and no pretending:"
# ===========================================================================

t=$(new_env)
SID="herdr-deliver-1"
NONCE="ab12cd34ef56aa01"
TRANS="$t/home/.claude/projects/$(encode_cwd "$t/target")/$SID.jsonl"
printf '[CALL_ID: %s]\nthe work order\n' "$NONCE" > "$t/payload.md"
mkdir -p "$t/state"; printf '%s' "$SID" > "$t/state/session_id"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_TRANSCRIPT="$TRANS" \
      bash "$HERDR_PROMPT" --agent hotline-x-1 --payload-file "$t/payload.md" \
        --call-id "$NONCE" --cwd "$t/target" --session "$SID" 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "true" \
   && "$(jq -r '.confirmed' <<<"$out" 2>/dev/null)" == "transcript" ]]
check "nonce lands in the callee's transcript → delivered, confirmed:transcript" $? "out=$out"
grep -q 'agent prompt hotline-x-1' <(tr -d '\\' < "$t/herdr.log")
check "…submitted by AGENT NAME (no surface to resolve, no input box to prove)" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"
! grep -q -- '--wait' "$t/herdr.log" 2>/dev/null
check "…without --wait (a quietly thinking callee would return agent_prompt_stalled)" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# The symlinked-cwd case: the callee writes under the REALPATH encoding, so a
# confirmation derived only from the path we were handed would miss — silently.
t=$(new_env)
SID="herdr-deliver-2"
NONCE="bb22cc33dd44ee55"
LINKED="$t/link-to-target"
ln -s "$t/target" "$LINKED"
REAL_TRANS="$t/home/.claude/projects/$(encode_cwd "$(cd "$t/target" && pwd -P)")/$SID.jsonl"
printf '[CALL_ID: %s]\nwork\n' "$NONCE" > "$t/payload.md"
printf '%s' "$SID" > "$t/state/session_id"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_TRANSCRIPT="$REAL_TRANS" \
      bash "$HERDR_PROMPT" --agent hotline-x-2 --payload-file "$t/payload.md" \
        --call-id "$NONCE" --cwd "$LINKED" --session "$SID" 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "true" ]]
check "a symlinked cwd is confirmed via the REALPATH transcript spelling too" $? "out=$out"

# --- the argv exposure boundary (claude-plugins-bwu1) -----------------------
# The repo rule is that payloads ride files or stdin, never argv (compounding.md,
# claude-plugins-86ka). herdr 0.8.0 offers no file or stdin form for a prompt, so
# this one delivery verb is the documented exception — and an exception is only
# scoped if its edge is pinned. The payload may appear in the `agent prompt` argv
# and NOWHERE else: not in a second herdr call, not in the status read that precedes
# it, not in the JSON this script emits.
t=$(new_env)
SID="herdr-argv-1"
NONCE="cc33dd44ee55ff66"
TRANS="$t/home/.claude/projects/$(encode_cwd "$t/target")/$SID.jsonl"
SENTINEL="PAYLOAD-SENTINEL-DO-NOT-LEAK-9f3a"
printf '[CALL_ID: %s]\n%s\n' "$NONCE" "$SENTINEL" > "$t/payload.md"
printf '%s' "$SID" > "$t/state/session_id"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_TRANSCRIPT="$TRANS" \
      bash "$HERDR_PROMPT" --agent hotline-x-argv --payload-file "$t/payload.md" \
        --call-id "$NONCE" --cwd "$t/target" --session "$SID" 2>/dev/null)
[[ "$(grep -c "$SENTINEL" "$t/herdr.log" 2>/dev/null)" == "1" ]]
check "the payload reaches EXACTLY ONE herdr invocation (the argv exception, scoped)" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"
[[ "$(grep "$SENTINEL" "$t/herdr.log" 2>/dev/null)" == *"agent prompt"* ]]
check "…and that one is \`agent prompt\`, the verb with no file or stdin form" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"
[[ "$out" != *"$SENTINEL"* ]]
check "…and never the emitted JSON, which names the payload FILE instead" $? "out=$out"

t=$(new_env)
printf 'x' > "$t/payload.md"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_GONE=1 \
      bash "$HERDR_PROMPT" --agent hotline-x-3 --payload-file "$t/payload.md" \
        --call-id nonce3 --cwd "$t/target" --session s3 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "false" \
   && "$(jq -r '.sent' <<<"$out" 2>/dev/null)" == "false" ]]
check "a dead agent → delivered:false sent:FALSE (safe to re-dial: nobody got anything)" $? "out=$out"
! grep -q 'agent prompt' "$t/herdr.log" 2>/dev/null
check "…and nothing is submitted after that check fails" $? "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

t=$(new_env)
printf 'x' > "$t/payload.md"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_PROMPT_FAIL=1 \
      bash "$HERDR_PROMPT" --agent hotline-x-4 --payload-file "$t/payload.md" \
        --call-id nonce4 --cwd "$t/target" --session s4 2>/dev/null)
[[ "$(jq -r '.sent' <<<"$out" 2>/dev/null)" == "false" ]]
check "a refused submit → sent:false (herdr validates before writing any bytes)" $? "out=$out"

t=$(new_env)
printf 'x' > "$t/payload.md"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 \
      bash "$HERDR_PROMPT" --agent hotline-x-5 --payload-file "$t/payload.md" \
        --call-id nonce5 --cwd "$t/target" --session s5 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "false" \
   && "$(jq -r '.sent' <<<"$out" 2>/dev/null)" == "true" ]] \
  && [[ "$(jq -r '.reason' <<<"$out" 2>/dev/null)" == *"no screen fallback"* ]]
check "submitted but never confirmed → sent:TRUE and an honest 'no screen fallback' reason" $? "out=$out"

# --- A slash command with a body is delivered in TWO writes (claude-plugins-fvhx) --
# One atomic `agent prompt` collapses the multi-line paste, the invocation stops being
# the literal start of the input, and the callee reads the work order as plain text:
# no ringing protocol, no STATUS, no call_id, and transcript-extract.sh exits 10
# forever. The nonce below lives in the INVOCATION LINE only, so a confirmed delivery
# proves both writes reached the same input box.

t=$(new_env)
SID="herdr-split-1"
NONCE="ee55ff66aa77bb88"
TRANS="$t/home/.claude/projects/$(encode_cwd "$t/target")/$SID.jsonl"
{ printf '/hotline:hotline-ringing [CALL_ID: %s] [MODE: work_order]\n' "$NONCE"
  printf 'line one of the work order\nline two\nline three\nline four\n'; } > "$t/payload.md"
printf '%s' "$SID" > "$t/state/session_id"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_TRANSCRIPT="$TRANS" \
      HERDR_STUB_AGENT_PANE="w1:p7" \
      bash "$HERDR_PROMPT" --agent hotline-s-1 --payload-file "$t/payload.md" \
        --call-id "$NONCE" --cwd "$t/target" --session "$SID" --first-contact 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "true" ]]
check "a slash-command payload with a body is delivered and confirmed" $? "out=$out"
log=$(tr -d '\\' < "$t/herdr.log")
grep -q 'pane send-text w1:p7 /hotline:hotline-ringing' <<<"$log"
check "…the INVOCATION LINE goes out alone via pane send-text (no Enter, no submit)" $? \
  "herdr calls: $log"
# Both line numbers are required to EXIST: bash reads an empty string as 0 in an
# arithmetic comparison, so "no send-text call at all" would otherwise satisfy
# "send-text came first" — the exact failure this case exists to catch.
SENDTEXT_LINE=$(grep -n 'pane send-text' <<<"$log" | head -1 | cut -d: -f1)
PROMPT_LINE=$(grep -n 'agent prompt' <<<"$log" | head -1 | cut -d: -f1)
[[ -n "$SENDTEXT_LINE" && -n "$PROMPT_LINE" && "$SENDTEXT_LINE" -lt "$PROMPT_LINE" ]]
check "…before the body's submit, never after" $? \
  "send-text=$SENDTEXT_LINE prompt=$PROMPT_LINE herdr calls: $log"
! grep 'agent prompt' <<<"$log" | grep -q '/hotline:hotline-ringing'
check "…and the submitted half carries the BODY only (the head is already in the box)" $? \
  "herdr calls: $log"
grep -q "$NONCE" "$TRANS" 2>/dev/null && grep -q 'line four' "$TRANS" 2>/dev/null
check "…so the callee's turn holds head AND body, byte-for-byte one payload" $? \
  "transcript: $(cat "$TRANS" 2>/dev/null)"

# A ONE-LINE slash command needs no split: nothing collapses, and a second write
# would only add a round trip.
t=$(new_env)
SID="herdr-split-2"
NONCE="ff66aa77bb88cc99"
TRANS="$t/home/.claude/projects/$(encode_cwd "$t/target")/$SID.jsonl"
printf '/hotline:hotline-ringing [CALL_ID: %s] status?' "$NONCE" > "$t/payload.md"
printf '%s' "$SID" > "$t/state/session_id"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_TRANSCRIPT="$TRANS" \
      bash "$HERDR_PROMPT" --agent hotline-s-2 --payload-file "$t/payload.md" \
        --call-id "$NONCE" --cwd "$t/target" --session "$SID" --first-contact 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "true" ]] \
  && ! grep -q 'pane send-text' "$t/herdr.log" 2>/dev/null
check "a single-line slash command takes the one-write path unchanged" $? \
  "out=$out herdr calls: $(tr -d '\\' < "$t/herdr.log")"

# A MULTI-LINE payload that is not a slash command needs no split either: there is no
# invocation for a placeholder to swallow.
t=$(new_env)
SID="herdr-split-3"
NONCE="aa77bb88cc99dd00"
TRANS="$t/home/.claude/projects/$(encode_cwd "$t/target")/$SID.jsonl"
printf '[CALL_ID: %s]\nfollow-up question\nsecond line\nthird line\n' "$NONCE" > "$t/payload.md"
printf '%s' "$SID" > "$t/state/session_id"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_TRANSCRIPT="$TRANS" \
      bash "$HERDR_PROMPT" --agent hotline-s-3 --payload-file "$t/payload.md" \
        --call-id "$NONCE" --cwd "$t/target" --session "$SID" --first-contact 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "true" ]] \
  && ! grep -q 'pane send-text' "$t/herdr.log" 2>/dev/null
check "a multi-line payload with no slash command takes the one-write path" $? \
  "out=$out herdr calls: $(tr -d '\\' < "$t/herdr.log")"

# The PREDICATE decides, not the --first-contact flag: a follow-up that happens to be
# a slash command with a body would lose its invocation exactly the same way.
t=$(new_env)
SID="herdr-split-4"
NONCE="bb88cc99dd00ee11"
TRANS="$t/home/.claude/projects/$(encode_cwd "$t/target")/$SID.jsonl"
{ printf '/hotline:hotline-ringing [CALL_ID: %s]\n' "$NONCE"; printf 'body\nmore body\n'; } > "$t/payload.md"
printf '%s' "$SID" > "$t/state/session_id"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_TRANSCRIPT="$TRANS" \
      bash "$HERDR_PROMPT" --agent hotline-s-4 --payload-file "$t/payload.md" \
        --call-id "$NONCE" --cwd "$t/target" --session "$SID" 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "true" ]] \
  && grep -q 'pane send-text' <(tr -d '\\' < "$t/herdr.log")
check "a FOLLOW-UP slash command with a body splits too (the predicate decides)" $? \
  "out=$out herdr calls: $(tr -d '\\' < "$t/herdr.log")"

# The first write failing is pre-submit: nothing is in the box, nothing was submitted.
t=$(new_env)
{ printf '/hotline:hotline-ringing [CALL_ID: n]\n'; printf 'body\nmore\n'; } > "$t/payload.md"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_SENDTEXT_FAIL=1 \
      bash "$HERDR_PROMPT" --agent hotline-s-5 --payload-file "$t/payload.md" \
        --call-id n --cwd "$t/target" --session s-s5 --first-contact 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "false" \
   && "$(jq -r '.sent' <<<"$out" 2>/dev/null)" == "false" ]]
check "a failed invocation-line write → delivered:false sent:FALSE (re-dial is safe)" $? "out=$out"
! grep -q 'agent prompt' "$t/herdr.log" 2>/dev/null
check "…and the body is never submitted on its own" $? \
  "herdr calls: $(tr -d '\\' < "$t/herdr.log")"

# No pane to write the invocation line into → REFUSE. Delivering unsplit instead would
# be a false success: the nonce would reach the transcript, delivery would report
# confirmed, and the caller would wait forever for a protocol that never engaged.
t=$(new_env)
SID="herdr-split-6"
NONCE="cc99dd00ee11ff22"
TRANS="$t/home/.claude/projects/$(encode_cwd "$t/target")/$SID.jsonl"
{ printf '/hotline:hotline-ringing [CALL_ID: %s]\n' "$NONCE"; printf 'body\nmore\n'; } > "$t/payload.md"
printf '%s' "$SID" > "$t/state/session_id"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_TRANSCRIPT="$TRANS" \
      HERDR_STUB_NO_PANE_ID=1 \
      bash "$HERDR_PROMPT" --agent hotline-s-6 --payload-file "$t/payload.md" \
        --call-id "$NONCE" --cwd "$t/target" --session "$SID" --first-contact 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "false" \
   && "$(jq -r '.sent' <<<"$out" 2>/dev/null)" == "false" \
   && "$(jq -r '.reason' <<<"$out" 2>/dev/null)" == *"no pane_id"* ]]
check "an agent with no pane_id → refused sent:false rather than delivered unsplit" $? "out=$out"
! grep -qE 'agent prompt|pane send-text' "$t/herdr.log" 2>/dev/null
check "…with nothing written into the callee at all" $? \
  "herdr calls: $(tr -d '\\' < "$t/herdr.log")"

# --- First contact is gated harder than a follow-up (claude-plugins-7wze.12) --
# The opening payload is the one delivery that can lose the whole work order, and it
# did, live, under load. Everything below is PRE-SUBMIT: the gate refuses with
# sent:false, so a caller may re-dial without risking a double-run.

# The readiness RACE, which is the whole reason the gate exists: `agent start`
# claimed the REPL was ready, the first re-probe disagrees, the next one agrees.
t=$(new_env)
SID="herdr-first-1"
NONCE="cc11dd22ee33ff44"
TRANS="$t/home/.claude/projects/$(encode_cwd "$t/target")/$SID.jsonl"
printf '[CALL_ID: %s]\nthe work order\n' "$NONCE" > "$t/payload.md"
printf '%s' "$SID" > "$t/state/session_id"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_TRANSCRIPT="$TRANS" \
      HERDR_STUB_READY_AFTER=1 \
      bash "$HERDR_PROMPT" --agent hotline-f-1 --payload-file "$t/payload.md" \
        --call-id "$NONCE" --cwd "$t/target" --session "$SID" --first-contact 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "true" ]]
check "first contact waits out an interactive_ready:false blink and then delivers" $? "out=$out"
log=$(tr -d '\\' < "$t/herdr.log")
[[ "$(grep -c 'agent get hotline-f-1' <<<"$log")" -ge 2 ]] \
  && [[ "$(grep -n 'agent prompt' <<<"$log" | head -1 | cut -d: -f1)" -gt \
        "$(grep -n 'agent get' <<<"$log" | tail -1 | cut -d: -f1)" ]]
check "…re-probing until it agrees, and submitting only AFTER the last probe" $? \
  "herdr calls: $log"

# Never ready → refused, and refused sent:false. `agent start`'s claim is not a
# submit-time fact, and a payload into whatever IS there would be lost silently.
t=$(new_env)
printf 'x' > "$t/payload.md"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_GET_READY=false \
      bash "$HERDR_PROMPT" --agent hotline-f-2 --payload-file "$t/payload.md" \
        --call-id nonce-f2 --cwd "$t/target" --session s-f2 --first-contact 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "false" \
   && "$(jq -r '.sent' <<<"$out" 2>/dev/null)" == "false" \
   && "$(jq -r '.reason' <<<"$out" 2>/dev/null)" == *"never reported interactive_ready"* ]]
check "an agent that never becomes interactive-ready → refused, sent:FALSE (re-dial is safe)" $? \
  "out=$out"
! grep -q 'agent prompt' "$t/herdr.log" 2>/dev/null
check "…with nothing submitted at all" $? "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# BLOCKED before first contact: the likelier half of the live failure. A startup
# trust prompt IS interactive — the dialog takes keystrokes — so submitting there
# answers the gate and the work order never becomes a turn.
t=$(new_env)
printf 'x' > "$t/payload.md"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_STATUS=blocked \
      bash "$HERDR_PROMPT" --agent hotline-f-3 --payload-file "$t/payload.md" \
        --call-id nonce-f3 --cwd "$t/target" --session s-f3 --first-contact 2>/dev/null)
[[ "$(jq -r '.sent' <<<"$out" 2>/dev/null)" == "false" \
   && "$(jq -r '.reason' <<<"$out" 2>/dev/null)" == *"blocked"* ]]
check "a callee BLOCKED before first contact → refused sent:false, not fed into the gate" $? \
  "out=$out"
[[ "$(jq -r '.reason' <<<"$out" 2>/dev/null)" == *"herdr agent attach hotline-f-3"* ]]
check "…naming the attach command that shows what it is asking" $? "out=$out"
! grep -q 'agent prompt' "$t/herdr.log" 2>/dev/null
check "…and submitting nothing" $? "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# THE STARTUP TRUST DIALOG (claude-plugins-59ry). herdr reports a callee sitting on it
# as interactive_ready:true and NOT blocked — the dialog really does take keystrokes —
# so the readiness gate above passes it and the payload answers the dialog's default
# option, `No, exit`. Live-confirmed on CC 2.1.251 / herdr 0.8.0 in a fresh `git init`
# directory. Only a screen read catches this.

t=$(new_env)
trust_dialog_screen "$t/screen.txt" "$t/target"
printf '/hotline:hotline-ringing [CALL_ID: n-t1]\nthe work order\nmore of it\n' > "$t/payload.md"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_SCREEN="$t/screen.txt" \
      bash "$HERDR_PROMPT" --agent hotline-t-1 --payload-file "$t/payload.md" \
        --call-id n-t1 --cwd "$t/target" --session s-t1 --first-contact 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "false" \
   && "$(jq -r '.sent' <<<"$out" 2>/dev/null)" == "false" ]]
check "a callee on the startup TRUST DIALOG → refused sent:FALSE, though herdr calls it ready" $? \
  "out=$out"
reason=$(jq -r '.reason' <<<"$out" 2>/dev/null)
[[ "$reason" == *"TRUST DIALOG"* && "$reason" == *"$t/target"* ]]
check "…naming the dialog and the cwd Claude Code has not trusted" $? "reason=$reason"
[[ "$reason" == *"No, exit"* && "$reason" == *"herdr agent attach hotline-t-1"* \
   && "$reason" == *"HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS does not cover"* ]]
check "…what a submit would have answered, how to look, and that the skip flag is no fix" $? \
  "reason=$reason"
# REMEDY BEFORE DIAGNOSIS, as a convention: dial.sh no longer cuts a detail string
# (claude-plugins-e3xr, and a dial-level test below holds that), but the reader of a
# failed dial scans the front of it, and the first wording of this reason put the
# diagnosis there and buried every instruction (live-caught, claude-plugins-59ry).
[[ "${reason:0:300}" == *"$t/target"* && "${reason:0:300}" == *"trust that directory"* \
   && "${reason:0:300}" == *"re-dial"* ]]
check "…with the cwd and the remedy in the reason's first 300 characters, ahead of the diagnosis" $? \
  "first 300: ${reason:0:300}"
! grep -qE 'agent prompt|pane send-text' "$t/herdr.log" 2>/dev/null
check "…and writing nothing into the dialog" $? "herdr calls: $(tr -d '\\' < "$t/herdr.log")"

# The read is PRE-SUBMIT, which is the only place it can help.
t=$(new_env)
SID="herdr-trust-2"
NONCE="dd00ee11ff22aa33"
TRANS="$t/home/.claude/projects/$(encode_cwd "$t/target")/$SID.jsonl"
printf '[CALL_ID: %s]\nwork\n' "$NONCE" > "$t/payload.md"
printf '%s' "$SID" > "$t/state/session_id"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_TRANSCRIPT="$TRANS" \
      bash "$HERDR_PROMPT" --agent hotline-t-2 --payload-file "$t/payload.md" \
        --call-id "$NONCE" --cwd "$t/target" --session "$SID" --first-contact 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "true" ]]
check "an ordinary REPL screen is no obstacle: first contact still delivers" $? "out=$out"
log=$(tr -d '\\' < "$t/herdr.log")
READ_LINE=$(grep -n 'agent read' <<<"$log" | head -1 | cut -d: -f1)
SUBMIT_LINE=$(grep -n 'agent prompt' <<<"$log" | head -1 | cut -d: -f1)
[[ -n "$READ_LINE" && -n "$SUBMIT_LINE" && "$READ_LINE" -lt "$SUBMIT_LINE" ]]
check "…having read the screen BEFORE submitting anything" $? \
  "read=$READ_LINE submit=$SUBMIT_LINE herdr calls: $log"

# An unreadable screen is permission to proceed, not a refusal — the probe can prove a
# dialog is there, never that one is not, and a herdr whose `agent read` changes shape
# must not make delivery impossible.
t=$(new_env)
SID="herdr-trust-3"
NONCE="ee11ff22aa33bb44"
TRANS="$t/home/.claude/projects/$(encode_cwd "$t/target")/$SID.jsonl"
printf '[CALL_ID: %s]\nwork\n' "$NONCE" > "$t/payload.md"
printf '%s' "$SID" > "$t/state/session_id"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_TRANSCRIPT="$TRANS" \
      HERDR_STUB_READ_FAIL=1 \
      bash "$HERDR_PROMPT" --agent hotline-t-3 --payload-file "$t/payload.md" \
        --call-id "$NONCE" --cwd "$t/target" --session "$SID" --first-contact 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "true" ]]
check "a screen that cannot be read proceeds (unproven, not impossible)" $? "out=$out"

# FIRST CONTACT ONLY, like the readiness gate beside it: a follow-up's agent has
# already taken a prompt and answered one, which no startup dialog survives.
t=$(new_env)
trust_dialog_screen "$t/screen.txt" "$t/target"
printf 'x' > "$t/payload.md"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_SCREEN="$t/screen.txt" \
      bash "$HERDR_PROMPT" --agent hotline-t-4 --payload-file "$t/payload.md" \
        --call-id n-t4 --cwd "$t/target" --session s-t4 2>/dev/null)
[[ "$(jq -r '.sent' <<<"$out" 2>/dev/null)" == "true" ]] \
  && ! grep -q 'agent read' "$t/herdr.log" 2>/dev/null
check "without --first-contact no screen is read at all (the gate is the opening one)" $? \
  "out=$out herdr calls: $(tr -d '\\' < "$t/herdr.log")"

# THE NARROW PANE, end to end. Same dialog, reflowed by a ~16-column pane, and it must
# refuse exactly the same way — this is the live-caught case the predicate's whitespace
# normalization exists for.
t=$(new_env)
trust_dialog_screen_wrapped "$t/screen.txt" "$t/target"
printf '/hotline:hotline-ringing [CALL_ID: n-t5]\nthe work order\nmore of it\n' > "$t/payload.md"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_SCREEN="$t/screen.txt" \
      bash "$HERDR_PROMPT" --agent hotline-t-5 --payload-file "$t/payload.md" \
        --call-id n-t5 --cwd "$t/target" --session s-t5 --first-contact 2>/dev/null)
[[ "$(jq -r '.sent' <<<"$out" 2>/dev/null)" == "false" \
   && "$(jq -r '.reason' <<<"$out" 2>/dev/null)" == *"TRUST DIALOG"* ]]
check "a NARROW pane's wrapped trust dialog is refused too (no raw substring survives it)" $? \
  "out=$out"
! grep -qE 'agent prompt|pane send-text' "$t/herdr.log" 2>/dev/null
check "…writing nothing into it either" $? "herdr calls: $(tr -d '\\' < "$t/herdr.log")"
# The fixture has to be genuinely wrapped, or the case above proves nothing.
! grep -qF 'I trust this folder' "$t/screen.txt" && ! grep -qF 'Quick safety check' "$t/screen.txt"
check "…and the fixture really does break every wording across lines" $? \
  "screen: $(cat "$t/screen.txt")"
# `--source recent`, not `visible`: a narrow pane's VIEWPORT clips the top of a wrapped
# dialog, so the wording can be off-screen entirely (measured live at ~16 columns).
grep -q 'agent read hotline-t-5 --source recent' <(tr -d '\\' < "$t/herdr.log")
check "…read from --source recent, which carries the whole dialog at any width" $? \
  "herdr calls: $(tr -d '\\' < "$t/herdr.log")"

# The predicate itself: the older wording of the same dialog must still fire, because a
# false negative kills the callee while a false positive only costs a refusal.
source "$HOTLINE_DIR/scripts/repl-state.sh"
# Its own full-width fixture: $t/screen.txt belongs to the case above, and reading that
# one here would quietly test the WRAPPED text under the unwrapped label.
trust_dialog_screen "$t/fullwidth.txt" /private/tmp/x
repl_trust_dialog_present "$(cat "$t/fullwidth.txt")" \
  && pass "trust dialog: the shipped CC 2.1.251 wording" \
  || fail "trust dialog: the shipped CC 2.1.251 wording"
repl_trust_dialog_present ' Do you trust the files in this folder?
 ❯ 1. Yes, proceed
   2. No, exit' \
  && pass "trust dialog: the older 'Do you trust the files in this folder?' wording" \
  || fail "trust dialog: the older 'Do you trust the files in this folder?' wording"
! repl_trust_dialog_present "$(printf '\xe2\x9d\xaf\xc2\xa0\n  what would you like me to do?\n')" \
  && pass "trust dialog: an ordinary idle REPL is not one" \
  || fail "trust dialog: an ordinary idle REPL is not one"
! repl_trust_dialog_present "" \
  && pass "trust dialog: an empty capture is not one" \
  || fail "trust dialog: an empty capture is not one"
trust_dialog_screen_wrapped "$t/wrapped.txt" /private/tmp/x
repl_trust_dialog_present "$(cat "$t/wrapped.txt")" \
  && pass "trust dialog: the wording reflowed across lines by a narrow pane" \
  || fail "trust dialog: the wording reflowed across lines by a narrow pane"

# An ABSENT interactive_ready must not make delivery impossible — only unproven. A
# herdr that stops reporting the field would otherwise block every first contact.
t=$(new_env)
SID="herdr-first-4"
NONCE="dd44ee55ff66aa77"
TRANS="$t/home/.claude/projects/$(encode_cwd "$t/target")/$SID.jsonl"
printf '[CALL_ID: %s]\nwork\n' "$NONCE" > "$t/payload.md"
printf '%s' "$SID" > "$t/state/session_id"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_TRANSCRIPT="$TRANS" \
      HERDR_STUB_GET_READY=omit \
      bash "$HERDR_PROMPT" --agent hotline-f-4 --payload-file "$t/payload.md" \
        --call-id "$NONCE" --cwd "$t/target" --session "$SID" --first-contact 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "true" ]]
check "an absent interactive_ready is permission to proceed, not a refusal" $? "out=$out"

# The gate is FIRST CONTACT ONLY. A follow-up's agent has already taken a prompt and
# answered one, which outranks any probe — and its refusals belong to the reuse
# script, where the caller can still fall back.
t=$(new_env)
printf 'x' > "$t/payload.md"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_GET_READY=false \
      bash "$HERDR_PROMPT" --agent hotline-f-5 --payload-file "$t/payload.md" \
        --call-id nonce-f5 --cwd "$t/target" --session s-f5 2>/dev/null)
[[ "$(jq -r '.sent' <<<"$out" 2>/dev/null)" == "true" ]]
check "without --first-contact the readiness gate is skipped (a follow-up is already proven)" $? \
  "out=$out"

# ===========================================================================
echo ""
echo "4. The waiters' herdr branch:"
# ===========================================================================

# --- wait-for-session ------------------------------------------------------
t=$(new_env)
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-w-1 "herdr-sess" "n0001" "$t/target"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" CMUX_LOG="$t/cmux.log" \
      bash "$WAIT_SESSION" "$cd_path" --timeout 5 2>"$t/err.txt"); rc=$?
[[ $rc -eq 0 && "$out" == "herdr-sess" ]]
check "wait-for-session (herdr) returns the id the launcher already wrote" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"
[[ ! -s "$t/cmux.log" ]]
check "…without a single cmux call" $? "cmux calls: $(cat "$t/cmux.log" 2>/dev/null)"
# session-cache.sh keys its connections by the REALPATH of the target.
REG="$t/home/.agents-hotline/sessions/caller-77.json"
[[ -s "$REG" ]] \
  && [[ "$(jq -r --arg t "$(cd "$t/target" && pwd -P)" '.connections[$t].surface_ref' \
            "$REG" 2>/dev/null)" == "hotline-w-1" ]]
check "…and registers the call with the AGENT NAME as the opaque host handle" $? \
  "registry: $(cat "$t/home/.agents-hotline/sessions/caller-77.json" 2>/dev/null)"

# The launcher-bug verdict: no agent name AND no error either. Nothing here says
# what went wrong, so the missing handle IS the diagnosis. The case below stages
# the same missing handle WITH the launcher's error beside it, and the two must
# reach opposite verdicts — that is the whole point of the ordering they pin.
t=$(new_env)
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-w-2 "s" "n" "$t/target"
rm -f "$cd_path/herdr_agent.txt"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" bash "$WAIT_SESSION" "$cd_path" --timeout 3 2>"$t/err.txt"); rc=$?
[[ $rc -ne 0 ]] && grep -q 'launcher bug' "$t/err.txt"
check "a herdr call dir with no agent name and no error fails loudly as a launcher bug" $? \
  "rc=$rc stderr=$(cat "$t/err.txt")"

# Staged the way fail_async ACTUALLY leaves the dir: herdr-call-async.sh writes
# herdr_agent.txt only after `agent start` succeeds, so a start that failed leaves
# error.txt + done and NO agent name. A fixture that kept the agent name modelled a
# state the launcher never produces, and so could not see the missing-handle guard
# firing ahead of the early-fail check and reporting herdr's own diagnostic — an
# agent_pane_busy among them — as a hotline launcher bug. (claude-plugins-r465.8: a
# fixture has to model the state the bug destroys.)
t=$(new_env)
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-w-3 "s" "n" "$t/target"
rm -f "$cd_path/session_id.txt" "$cd_path/herdr_agent.txt"
echo '{"error":"herdr agent start failed in pane w1:p9 after 4 attempt(s): agent_pane_busy"}' > "$cd_path/error.txt"
touch "$cd_path/done"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" bash "$WAIT_SESSION" "$cd_path" --timeout 3 2>"$t/err.txt"); rc=$?
[[ $rc -ne 0 ]] && grep -q 'agent_pane_busy' "$t/err.txt"
check "a launcher failure keeps ITS diagnostic, not the missing-handle guard's" $? \
  "rc=$rc stderr=$(cat "$t/err.txt")"
! grep -q 'launcher bug' "$t/err.txt"
check "…so the caller is never told 'launcher bug' about herdr's own refusal" $? \
  "stderr=$(cat "$t/err.txt")"

# The earliest failure of all: the pane split itself was refused, so the dir has
# neither an agent name nor a pane. Same verdict, and it is the shape the
# recovery advice in the guard's message would be most wrong about.
t=$(new_env)
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-w-4 "s" "n" "$t/target"
rm -f "$cd_path/session_id.txt" "$cd_path/herdr_agent.txt" "$cd_path/herdr_pane.txt"
echo '{"error":"herdr pane split from w1:p1 failed: pane_not_found"}' > "$cd_path/error.txt"
touch "$cd_path/done"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" bash "$WAIT_SESSION" "$cd_path" --timeout 3 2>"$t/err.txt"); rc=$?
[[ $rc -ne 0 ]] && grep -q 'pane_not_found' "$t/err.txt" && ! grep -q 'launcher bug' "$t/err.txt"
check "a refused pane split is reported as herdr said it, not as a missing handle" $? \
  "rc=$rc stderr=$(cat "$t/err.txt")"

# --- wait-for-response ----------------------------------------------------
t=$(new_env)
NONCE="ff00aa11bb22cc33"
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-r-1 "herdr-sess" "$NONCE" "$t/target"
transcript_with "$t/home/.claude/projects/$(encode_cwd "$t/target")/herdr-sess.jsonl" \
  "$NONCE" WORK_COMPLETE "the answer is 42"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" CMUX_LOG="$t/cmux.log" HERDR_STUB_AGENT_ANY=1 \
      HOTLINE_POLL_SLEEP=0 bash "$WAIT_RESPONSE" "$cd_path" --timeout 10 2>"$t/err.txt"); rc=$?
[[ $rc -eq 0 && "$(jq -r '.response' <<<"$out" 2>/dev/null)" == *"the answer is 42"* ]]
check "wait-for-response (herdr) extracts the answer via transcript-extract.sh" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"
[[ "$(jq -r '.session_id' <<<"$out" 2>/dev/null)" == "herdr-sess" ]]
check "…reporting the callee's CLAUDE session id, not a herdr handle" $? "out=$out"
[[ ! -s "$t/cmux.log" ]]
check "…with no cmux call anywhere in it" $? "cmux calls: $(cat "$t/cmux.log" 2>/dev/null)"
! grep -q 'pane close' "$t/herdr.log" 2>/dev/null
check "…and nothing is closed: the agent outlives the call (that is why herdr exists)" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# --- a herdr call dir NEVER file-watches to timeout (claude-plugins-r6jj) ----
# transport.sh accepts 'herdr' and this branch handles it, but the two are separate
# decisions, and the gap between them fails silently: a herdr dir that fell through
# to the host-handle inference has no handle to find, so it would take the headless
# file-watch path and poll a `done` nobody writes for the whole 1800s budget.
#
# Told apart by the failure they produce. The herdr branch names the agent and gives
# up inside FILE_GRACE; the file-watch path can only ever say "Timed out waiting for
# response", and only after the budget is gone. The generous --timeout is the point:
# the file-watch path would still be sleeping.
t=$(new_env)
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-r6jj-a "herdr-sess" "n0r6jj" "$t/target"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" CMUX_LOG="$t/cmux.log" HERDR_STUB_AGENT_ANY=1 \
      HOTLINE_POLL_SLEEP=0 bash "$WAIT_RESPONSE" "$cd_path" --timeout 600 \
      2>"$t/err.txt"); rc=$?
[[ $rc -ne 0 ]] && grep -q 'hotline-r6jj-a' "$t/err.txt"
check "a herdr call dir with no host handle fails as herdr, naming the agent" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"
! grep -q 'Timed out waiting for response' "$t/err.txt"
check "…never as the headless file-watch, which would sit on \`done\` for the budget" $? \
  "stderr=$(cat "$t/err.txt")"
[[ ! -s "$t/cmux.log" ]]
check "…and asks cmux nothing on the way out" $? \
  "cmux calls: $(cat "$t/cmux.log" 2>/dev/null)"

# The other half of the same gap: WITH a handle present the inference reads cmux, so
# a stale one must not be able to pull a herdr call onto the cmux path.
#
# Both paths read the transcript first, so a finished call cannot tell them apart.
# An UNFINISHED one can: the gate is what differs. herdr blocks on `herdr agent
# wait`; the cmux path asks cmux about the callee's screen and input box. So the
# transcript below carries the nonce with no terminal STATUS, and the evidence is
# which CLI got asked.
t=$(new_env)
NONCE="d00dd00dd00dd00d"
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-r6jj-b "herdr-sess" "$NONCE" "$t/target"
echo "workspace:99" > "$cd_path/workspace_ref.txt"
echo "/tmp/hotline-launch-FAKE-$$" > "$cd_path/launch_script.txt"
transcript_with "$t/home/.claude/projects/$(encode_cwd "$t/target")/herdr-sess.jsonl" \
  "$NONCE" "" "still working"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" CMUX_LOG="$t/cmux.log" HERDR_STUB_AGENT_ANY=1 \
      HERDR_STUB_STATUS=working HOTLINE_POLL_SLEEP=0 \
      HOTLINE_HERDR_WAIT_SLICE_MS=50 \
      bash "$WAIT_RESPONSE" "$cd_path" --timeout 6 2>"$t/err.txt"); rc=$?
grep -q 'agent wait hotline-r6jj-b' <(tr -d '\\' < "$t/herdr.log")
check "a stale cmux handle never diverts a herdr call off the \`agent wait\` gate" $? \
  "rc=$rc herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"
[[ ! -s "$t/cmux.log" ]]
check "…and cmux is asked nothing about a herdr callee's screen" $? \
  "cmux calls: $(cat "$t/cmux.log" 2>/dev/null)"

# The answer was already on disk, so the gate must not have been the thing that
# decided anything — but when it IS reached it must ask for the settled SET.
# `--until idle` alone would hang forever on a hotline callee: herdr reports an
# unfocused finished agent as `done`, not `idle`.
# --- the live-caught blocker: cwd.txt in one spelling, transcript in the other ---
# Delivery has always tried BOTH spellings of the callee's cwd; the wait derived only
# the literal one. Live consequence on a real callee under /tmp/herdr-live-smoke:
# `herdr-prompt.sh` confirmed the nonce, then the wait exited 1 with "the prompt never
# reached the agent" while STATUS: WORK_COMPLETE sat in the realpath-encoded
# transcript. Every fixture above uses an already-canonical path, which is exactly why
# none of them could see it.
t=$(new_env)
NONCE="cafe1234beef5678"
LINKED_CWD="$t/symlinked-target"
ln -s "$t/target" "$LINKED_CWD"
cd_path="$t/call"
# cwd.txt holds the SYMLINKED path — what an older call dir, or a hand-staged one,
# carries. The callee wrote its transcript under the REALPATH encoding, as Claude Code
# always does.
stage_herdr_dir "$cd_path" hotline-r-link "herdr-sess" "$NONCE" "$LINKED_CWD"
transcript_with "$t/home/.claude/projects/$(encode_cwd "$(cd "$t/target" && pwd -P)")/herdr-sess.jsonl" \
  "$NONCE" WORK_COMPLETE "the symlinked answer"
[[ ! -f "$t/home/.claude/projects/$(encode_cwd "$LINKED_CWD")/herdr-sess.jsonl" ]]
check "the fixture really has NO transcript under the literal cwd spelling (guards the guard)" $? \
  "literal-spelling path exists, so this case would pass without the fix"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HOTLINE_POLL_SLEEP=0 \
      bash "$WAIT_RESPONSE" "$cd_path" --timeout 10 2>"$t/err.txt"); rc=$?
[[ $rc -eq 0 && "$(jq -r '.response' <<<"$out" 2>/dev/null)" == *"the symlinked answer"* ]]
check "a symlinked cwd.txt still finds the REALPATH-encoded transcript (live-caught blocker)" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"

# And the launcher's half of the same fix: cwd.txt is canonicalized at write time, so
# the two spellings normally coincide by construction rather than by search.
t=$(new_env)
ln -s "$t/target" "$t/linked"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_PANE_ID="w1:p1" \
      bash "$HERDR_ASYNC" --cwd "$t/linked" --prompt "hi" 2>"$t/err.txt")
cd_path=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ "$(cat "$cd_path/cwd.txt" 2>/dev/null)" == "$(cd "$t/target" && pwd -P)" ]]
check "the launcher canonicalizes cwd.txt, so every consumer derives the encoding the callee uses" $? \
  "cwd.txt='$(cat "$cd_path/cwd.txt" 2>/dev/null)' want='$(cd "$t/target" && pwd -P)'"
grep -q -- "--cwd $(cd "$t/target" && pwd -P) " <(tr -d '\\' < "$t/herdr.log")
check "…and splits the pane in that same canonical cwd, so the callee resolves there" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

t=$(new_env)
NONCE="1122334455667788"
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-r-2 "herdr-sess" "$NONCE" "$t/target"
transcript_with "$t/home/.claude/projects/$(encode_cwd "$t/target")/herdr-sess.jsonl" \
  "$NONCE" "" "still working"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_STATUS=working \
      HOTLINE_POLL_SLEEP=0 HOTLINE_HERDR_WAIT_SLICE_MS=50 \
      bash "$WAIT_RESPONSE" "$cd_path" --timeout 6 2>"$t/err.txt"); rc=$?
[[ $rc -ne 0 ]] && grep -q 'Timed out' "$cd_path/error.txt"
check "WORK_IN_PROGRESS keeps waiting, then times out (never a false completion)" $? \
  "rc=$rc out=$out error=$(cat "$cd_path/error.txt" 2>/dev/null)"
grep -q 'agent wait hotline-r-2 --until idle --until done --until blocked' \
  <(tr -d '\\' < "$t/herdr.log")
check "…gating on the settled SET (idle+done+blocked), never on idle alone" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"
[[ -s "$cd_path/waiter_timeout.txt" ]]
check "…and marks the budget resumable, so re-running gets a fresh one" $? \
  "call_dir: $(ls "$cd_path" | tr '\n' ' ')"

t=$(new_env)
NONCE="aaaabbbbccccdddd"
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-r-3 "herdr-sess" "$NONCE" "$t/target"
transcript_with "$t/home/.claude/projects/$(encode_cwd "$t/target")/herdr-sess.jsonl" \
  "$NONCE" AWAITING_REVIEW "step 1 of 3 done"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HOTLINE_POLL_SLEEP=0 \
      bash "$WAIT_RESPONSE" "$cd_path" --timeout 10 2>"$t/err.txt"); rc=$?
[[ $rc -eq 4 && "$(jq -r '.awaiting_review' <<<"$out" 2>/dev/null)" == "true" ]]
check "AWAITING_REVIEW → exit 4 with the same additive marker as cmux" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"

t=$(new_env)
NONCE="9999888877776666"
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-r-4 "herdr-sess" "$NONCE" "$t/target"
TR="$t/home/.claude/projects/$(encode_cwd "$t/target")/herdr-sess.jsonl"
transcript_with "$TR" "$NONCE" "" "on it"
printf '{"type":"user","sessionId":"herdr-sess","message":{"content":"actually do the migration instead"}}\n' >> "$TR"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HOTLINE_POLL_SLEEP=0 \
      bash "$WAIT_RESPONSE" "$cd_path" --timeout 10 2>"$t/err.txt"); rc=$?
[[ $rc -eq 3 ]] && grep -q 'reassigned mid-call' "$t/err.txt"
check "a preempted callee → exit 3, naming the preempting prompt" $? \
  "rc=$rc stderr=$(cat "$t/err.txt")"

# A call dir with no agent name is still a launcher bug — but the ANSWER may already
# be on disk, and refusing to look because the GATE is missing throws away a finished
# work order. So the transcript is read first, and the loud refusal happens only at
# the point of actually needing the gate.
t=$(new_env)
NONCE="d0d0d0d0e1e1e1e1"
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-r-noagent "herdr-sess" "$NONCE" "$t/target"
rm -f "$cd_path/herdr_agent.txt"
transcript_with "$t/home/.claude/projects/$(encode_cwd "$t/target")/herdr-sess.jsonl" \
  "$NONCE" WORK_COMPLETE "answered before the handle went missing"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HOTLINE_POLL_SLEEP=0 \
      bash "$WAIT_RESPONSE" "$cd_path" --timeout 10 2>"$t/err.txt"); rc=$?
[[ $rc -eq 0 && "$(jq -r '.response' <<<"$out" 2>/dev/null)" == *"answered before the handle went missing"* ]]
check "no agent name but an answer on disk → the answer, not a launcher-bug error" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"

# …and with nothing on disk to salvage, it still fails loudly rather than degrading
# into a bare file poll that would sit out the whole budget.
t=$(new_env)
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-r-noagent2 "herdr-sess" "n-na2" "$t/target"
rm -f "$cd_path/herdr_agent.txt"
transcript_with "$t/home/.claude/projects/$(encode_cwd "$t/target")/herdr-sess.jsonl" \
  "n-na2" "" "still working"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HOTLINE_POLL_SLEEP=0 \
      bash "$WAIT_RESPONSE" "$cd_path" --timeout 600 2>"$t/err.txt"); rc=$?
[[ $rc -ne 0 ]] && grep -q 'no herdr_agent.txt' "$t/err.txt" && grep -q 'launcher bug' "$t/err.txt"
check "…and with no answer on disk it still fails loudly as a launcher bug" $? \
  "rc=$rc stderr=$(cat "$t/err.txt")"

t=$(new_env)
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-r-5 "herdr-sess" "n5" "$t/target"
rm -f "$cd_path/cwd.txt"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HOTLINE_POLL_SLEEP=0 \
      bash "$WAIT_RESPONSE" "$cd_path" --timeout 5 2>"$t/err.txt"); rc=$?
[[ $rc -ne 0 ]] && grep -q 'no screen fallback' "$t/err.txt" \
  && grep -q 'cwd.txt=MISSING' "$t/err.txt"
check "no derivable transcript → a hard stop that names the MISSING input" $? \
  "rc=$rc stderr=$(cat "$t/err.txt")"
[[ ! -s "$t/herdr.log" ]]
check "…decided before any herdr call (there is no weaker tier to try)" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

t=$(new_env)
NONCE="5555444433332222"
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-r-6 "herdr-sess" "$NONCE" "$t/target"
transcript_with "$t/home/.claude/projects/$(encode_cwd "$t/target")/herdr-sess.jsonl" \
  "$NONCE" "" "started, then died"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_GONE=1 HOTLINE_POLL_SLEEP=0 \
      bash "$WAIT_RESPONSE" "$cd_path" --timeout 600 2>"$t/err.txt"); rc=$?
[[ $rc -ne 0 ]] && grep -q 'exited before answering' "$t/err.txt"
check "an agent that vanished mid-call fails FAST instead of sitting out the budget" $? \
  "rc=$rc stderr=$(cat "$t/err.txt")"

t=$(new_env)
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-r-7 "herdr-sess" "n7" "$t/target"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HOTLINE_POLL_SLEEP=0 \
      bash "$WAIT_RESPONSE" "$cd_path" --timeout 30 2>"$t/err.txt"); rc=$?
# The message names EVERY derived candidate, not one path: naming a single path is
# how it once asserted "the prompt never reached the agent" about a callee whose
# finished answer was in the other spelling.
[[ $rc -ne 0 ]] && grep -q 'No transcript after' "$t/err.txt" \
  && grep -q 'at any derived path' "$t/err.txt"
check "a transcript that never appears is reported as 'the prompt never landed', naming every candidate" $? \
  "rc=$rc stderr=$(cat "$t/err.txt")"

# ===========================================================================
echo ""
echo "7. Blocked-state reporting — a human is needed, not more time:"
# ===========================================================================
# herdr reports `blocked` natively: the callee is waiting on INPUT (a permission
# gate, or a genuine question). Spending the full 30-minute budget on that and then
# calling it a timeout sends a reader hunting a slow work order instead of a dialog
# box. It is NOT a new terminal STATUS — the protocol is untouched; the LIFECYCLE
# is saying why no STATUS is coming.

t=$(new_env)
NONCE="b10cked0000aaaa1"
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-blk-1 "herdr-sess" "$NONCE" "$t/target"
transcript_with "$t/home/.claude/projects/$(encode_cwd "$t/target")/herdr-sess.jsonl" \
  "$NONCE" "" "reading the repo"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_STATUS=blocked \
      HOTLINE_POLL_SLEEP=0 HOTLINE_HERDR_WAIT_SLICE_MS=50 \
      bash "$WAIT_RESPONSE" "$cd_path" --timeout 600 2>"$t/err.txt"); rc=$?
[[ $rc -eq 5 ]]
check "a blocked settle with no terminal STATUS → exit 5, its own outcome" $? \
  "rc=$rc stderr=$(cat "$t/err.txt")"
grep -q 'waiting on INPUT' "$t/err.txt" && grep -q 'agent attach hotline-blk-1' "$t/err.txt"
check "…saying it is waiting on input and how to look at it" $? "stderr=$(cat "$t/err.txt")"
! grep -qi 'timed out' "$t/err.txt"
check "…and never calling it a timeout" $? "stderr=$(cat "$t/err.txt")"
[[ -s "$cd_path/waiter_timeout.txt" ]] && grep -q 'settle=blocked' "$cd_path/waiter_timeout.txt"
check "…marked RESUMABLE, so re-running after a human unblocks it reads the answer" $? \
  "marker=$(cat "$cd_path/waiter_timeout.txt" 2>/dev/null)"
! grep -q 'pane close' "$t/herdr.log" 2>/dev/null
check "…leaving the agent live (it is mid-question; closing it would end the call)" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# The answer outranks the lifecycle. A callee that emits its terminal STATUS and
# then blocks on the NEXT thing it wants to do has answered us.
t=$(new_env)
NONCE="b10cked0000aaaa2"
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-blk-2 "herdr-sess" "$NONCE" "$t/target"
transcript_with "$t/home/.claude/projects/$(encode_cwd "$t/target")/herdr-sess.jsonl" \
  "$NONCE" WORK_COMPLETE "done, and now asking about something else"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_STATUS=blocked \
      HOTLINE_POLL_SLEEP=0 HOTLINE_HERDR_WAIT_SLICE_MS=50 \
      bash "$WAIT_RESPONSE" "$cd_path" --timeout 30 2>"$t/err.txt"); rc=$?
[[ $rc -eq 0 && "$(jq -r '.response' <<<"$out" 2>/dev/null)" == *"done, and now asking"* ]]
check "a blocked agent that ALREADY answered still exits 0 with the answer" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"

# A blocked callee with no transcript at all is still blocked, and that is the more
# useful thing to say than "the prompt never reached the agent" — a gate raised
# before the callee could record anything looks identical to a lost delivery.
t=$(new_env)
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-blk-3 "herdr-sess" "n-blk3" "$t/target"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_STATUS=blocked \
      HOTLINE_POLL_SLEEP=0 HOTLINE_HERDR_WAIT_SLICE_MS=50 \
      bash "$WAIT_RESPONSE" "$cd_path" --timeout 600 2>"$t/err.txt"); rc=$?
[[ $rc -eq 5 ]] && grep -q 'waiting on INPUT' "$t/err.txt"
check "blocked with no transcript reports the block, not a phantom delivery failure" $? \
  "rc=$rc stderr=$(cat "$t/err.txt")"

# …but that path confirms too, like every other one that ends a call on `blocked`.
# It used to act on a SINGLE read — the one exception, and the reason the documented
# "always re-probed" promise was not actually true (claude-plugins-7wze.13). A blink
# refuted here now reports what the confirming probe found instead.
t=$(new_env)
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-blk-5 "herdr-sess" "n-blk5" "$t/target"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_BLOCKED_ONCE=1 \
      HOTLINE_POLL_SLEEP=0 HOTLINE_HERDR_WAIT_SLICE_MS=50 \
      bash "$WAIT_RESPONSE" "$cd_path" --timeout 600 2>"$t/err.txt"); rc=$?
[[ $rc -eq 1 ]] && grep -q 'No transcript after' "$t/err.txt" \
  && ! grep -q 'waiting on INPUT' "$t/err.txt"
check "a blocked BLINK with no transcript is NOT reported as blocked (the probe refuted it)" $? \
  "rc=$rc stderr=$(cat "$t/err.txt")"
[[ "$(grep -c 'agent get hotline-blk-5' <(tr -d '\\' < "$t/herdr.log"))" -ge 2 ]]
check "…because the no-transcript path re-probes now, like every other blocked exit" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# A blocked BLINK is not a verdict: the state is re-probed before the call ends, so
# a gate that cleared itself leaves the wait running.
t=$(new_env)
NONCE="b10cked0000aaaa4"
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-blk-4 "herdr-sess" "$NONCE" "$t/target"
transcript_with "$t/home/.claude/projects/$(encode_cwd "$t/target")/herdr-sess.jsonl" \
  "$NONCE" "" "still working"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_STATUS=working \
      HERDR_STUB_WAIT_STATUS=blocked \
      HOTLINE_POLL_SLEEP=0 HOTLINE_HERDR_WAIT_SLICE_MS=50 \
      bash "$WAIT_RESPONSE" "$cd_path" --timeout 6 2>"$t/err.txt"); rc=$?
[[ $rc -eq 1 ]] && grep -q 'Timed out' "$cd_path/error.txt"
check "a blocked settle the confirming probe does not reproduce keeps waiting" $? \
  "rc=$rc error=$(cat "$cd_path/error.txt" 2>/dev/null)"

herdr_suite_finish
