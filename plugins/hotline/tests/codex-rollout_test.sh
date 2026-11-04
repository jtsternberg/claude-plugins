#!/usr/bin/env bash
# =============================================================================
# Codex rollout → transcript-extract.sh. The fixture rows copy the shapes of a real
# codex-cli 0.165.0 rollout (session_meta, developer/user/assistant response_item
# messages with `phase`, event_msg task_started/task_complete/turn_aborted); the
# extractor itself is the unmodified Claude reader, so these cases pin the adapter.
# =============================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
EXTRACT="$PLUGIN/skills/dial/scripts/transcript-extract.sh"
# shellcheck source=../scripts/codex-rollout.sh
source "$PLUGIN/scripts/codex-rollout.sh"

PASS=0; FAIL=0
check() { if [[ "$2" -eq 0 ]]; then PASS=$((PASS+1)); echo "  ✓ $1"; else FAIL=$((FAIL+1)); echo "  ✗ $1"; [[ -n "${3:-}" ]] && echo "    $3"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/codex-rollout-test-XXXXXX")
trap 'rm -rf "$T"' EXIT
N=abc123def4567890
SID=01a1a28d-f07a-76a3-bbc7-21b555a6a8dc

meta()  { jq -nc --arg s "$SID" '{type:"session_meta",payload:{id:$s,cwd:"/x"}}'; }
umsg()  { jq -nc --arg t "$1" '{type:"response_item",payload:{type:"message",role:"user",content:[{type:"input_text",text:$t}]}}'; }
dmsg()  { jq -nc --arg t "$1" '{type:"response_item",payload:{type:"message",role:"developer",content:[{type:"input_text",text:$t}]}}'; }
amsg()  { jq -nc --arg t "$1" --arg p "${2:-}" '{type:"response_item",payload:({type:"message",role:"assistant",id:("m"+($t|length|tostring)),content:[{type:"output_text",text:$t}]} + (if $p=="" then {} else {phase:$p} end))}'; }
ev()    { jq -nc --arg t "$1" '{type:"event_msg",payload:{type:$t}}'; }
tool()  { jq -nc '{type:"response_item",payload:{type:"function_call",name:"exec",arguments:"{}"}}'; }

extract() {  # extract <rollout> → sets RC, OUT
  codex_rollout_normalize "$1" "$T/norm.jsonl" || { RC=99; OUT="normalize failed"; return; }
  OUT=$(bash "$EXTRACT" "$T/norm.jsonl" "$N" 2>&1); RC=$?
}

echo "codex rollout normalization:"

R="$T/r1.jsonl"
{ meta; ev task_started; dmsg "You are Codex"; umsg "# AGENTS.md instructions for /x"; umsg "<environment_context>cwd</environment_context>"
  umsg "[CALL_ID: $N]"$'\n'"\$hotline:hotline-ringing [MODE: quick_call]"$'\n'"say hi"
  amsg "STATUS: WORK_IN_PROGRESS call_id=$N"$'\n'"checking" commentary; tool
  amsg "STATUS: WORK_IN_PROGRESS call_id=$N"$'\n\n'"hello from codex"$'\n\n'"STATUS: DONE call_id=$N" final_answer
  ev task_complete; } > "$R"
extract "$R"
[[ $RC -eq 0 && "$(jq -r .response <<<"$OUT")" == "hello from codex" && "$(jq -r .session_id <<<"$OUT")" == "$SID" ]]
check "a completed turn → exit 0, body after the LAST WORK_IN_PROGRESS, thread id as session_id" $? "rc=$RC out=$OUT"

R="$T/r2.jsonl"
{ meta; umsg "[CALL_ID: $N] go"; amsg "STATUS: WORK_IN_PROGRESS call_id=$N"$'\n'"working" commentary; tool; } > "$R"
extract "$R"
check "submitted, no terminal STATUS yet → exit 10 (keep waiting)" $([[ $RC -eq 10 ]]; echo $?) "rc=$RC out=$OUT"

R="$T/r3.jsonl"
{ meta; umsg "something else"; } > "$R"
extract "$R"
check "nonce nowhere → exit 11; Codex's own context rows are not submit evidence" $([[ $RC -eq 11 ]]; echo $?) "rc=$RC"

R="$T/r4.jsonl"
{ meta; umsg "[CALL_ID: $N] go"; amsg "STATUS: WORK_IN_PROGRESS call_id=$N"$'\n'"Which branch?"$'\n'"STATUS: BLOCKED call_id=$N"; ev task_complete; } > "$R"
extract "$R"
# No phase on that message: end_turn must come from the task_complete that follows it.
[[ $RC -eq 14 && "$(jq -r .blocked <<<"$OUT")" == "true" && "$(jq -r .response <<<"$OUT")" == "Which branch?" ]]
check "turn ends on BLOCKED (no phase field) → exit 14, via task_complete ⇒ end_turn" $? "rc=$RC out=$OUT"

R="$T/r5.jsonl"
{ meta; umsg "[CALL_ID: $N] go"; amsg "STATUS: WORK_IN_PROGRESS call_id=$N" commentary; ev turn_aborted; umsg "actually, do the other thing"; } > "$R"
extract "$R"
[[ $RC -eq 12 && "$OUT" == *"do the other thing"* ]]
check "interrupt + a new human prompt → exit 12 (preempted)" $? "rc=$RC out=$OUT"

R="$T/r6.jsonl"
{ meta; umsg "[CALL_ID: $N] go"; amsg "STATUS: WORK_IN_PROGRESS call_id=$N"$'\n'"next turn context follows"; ev task_complete; umsg "<environment_context>x</environment_context>"; } > "$R"
extract "$R"
check "a later injected environment_context row is NOT read as a reassignment → exit 10" $([[ $RC -eq 10 ]]; echo $?) "rc=$RC out=$OUT"

R="$T/r6b.jsonl"
{ meta; umsg "[CALL_ID: $N]"$'\n'"\$hotline:hotline-ringing go"; umsg $'<skill>\n<name>hotline:hotline-ringing</name>\n...</skill>'; tool; } > "$R"
extract "$R"
check "the <skill> body Codex injects after our prompt is NOT a reassignment → exit 10" $([[ $RC -eq 10 ]]; echo $?) "rc=$RC out=$OUT"

R="$T/r7.jsonl"
{ meta; umsg "[CALL_ID: $N] go"; jq -nc '{type:"event_msg",payload:{type:"error",message:"stream disconnected"}}'; } > "$R"
codex_rollout_normalize "$R" "$T/norm.jsonl"
check "an error event becomes an isApiErrorMessage row (feeds the STALLED verdict)" \
  $(jq -se 'map(select(.isApiErrorMessage == true)) | length == 1' "$T/norm.jsonl" >/dev/null; echo $?)

echo "finding the rollout:"
export CODEX_HOME="$T/codex"
mkdir -p "$CODEX_HOME/sessions/2026/11/03"
OTHER="$CODEX_HOME/sessions/2026/11/03/rollout-2026-11-03T12-00-00-11111111-1111-7111-8111-111111111111.jsonl"
MINE="$CODEX_HOME/sessions/2026/11/03/rollout-2026-11-03T12-56-13-$SID.jsonl"
umsg "[CALL_ID: ffffffffffffffff] not ours" > "$OTHER"
umsg "[CALL_ID: $N] ours" > "$MINE"
got=$(codex_find_rollout "$N")
check "the rollout carrying the nonce is found, not a neighbour" $([[ "$got" == "$MINE" ]]; echo $?) "got=$got"
check "its thread id comes off the filename" $([[ "$(codex_thread_id_of "$got")" == "$SID" ]]; echo $?)
codex_find_rollout 0000000000000000 >/dev/null
check "no rollout carries an unknown nonce → exit 1" $([[ $? -eq 1 ]]; echo $?)

echo "startup dialogs:"
check "folder trust" $([[ "$(codex_startup_dialog "  Folder access  Trust this folder? Codex can read")" == folder-trust ]]; echo $?)
check "hooks review (herdr reports this one idle + interactive_ready)" \
  $([[ "$(codex_startup_dialog $'Hooks need review\n5 hooks are new')" == hooks-review ]]; echo $?)
check "update prompt" $([[ "$(codex_startup_dialog "Update available · 0.165 → 0.166 › 1. Update now")" == update-prompt ]]; echo $?)
codex_startup_dialog "› Ask Codex to do anything" >/dev/null
check "the ready composer is not a dialog" $([[ $? -eq 1 ]]; echo $?)

check "the composer footer is the ready signal" $(codex_composer_ready $'› Ask Codex to do anything\n ? for shortcuts'; echo $?)
codex_composer_ready "  Hooks need review" 
check "a dialog screen is not ready" $([[ $? -eq 1 ]]; echo $?)

echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
