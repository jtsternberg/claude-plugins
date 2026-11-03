#!/usr/bin/env bash
# =============================================================================
# herdr transport, CODEX callee (--agent codex): the args refusals, the launch argv,
# delivery proven by the nonce in the Codex rollout, registration after delivery,
# and the answer read back through the unchanged wait-for-response.sh contract.
#
# The rollout the stubbed `agent prompt` writes copies the row shapes of a real
# codex-cli 0.165.0 rollout (see codex-rollout_test.sh for the adapter itself).
# =============================================================================
set -u
# shellcheck source=lib/herdr-transport-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/herdr-transport-harness.sh"

THREAD=01a1a28d-f07a-76a3-bbc7-21b555a6a8dc

# A codex on PATH (never run — herdr is stubbed — but dial.sh preflights for it),
# and an `agent prompt` that writes the callee's rollout the way codex would:
# the typed prompt as a user message, then, unless told otherwise, a final answer
# bracketed for the nonce it finds in that prompt.
codex_env() {  # codex_env <scratch> [reply: done|none]
  local t="$1" reply="${2:-done}"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$t/bin/codex"; chmod +x "$t/bin/codex"
  mkdir -p "$t/binsrc"; make_herdr_stub "$t/binsrc"; mv "$t/binsrc/herdr" "$t/bin/herdr-real"
  cat > "$t/bin/herdr" <<STUBW
#!/usr/bin/env bash
if [[ "\$1 \${2:-}" == "agent prompt" ]]; then
  R="$t/home/.codex/sessions/2026/11/03/rollout-2026-11-03T12-56-13-$THREAD.jsonl"
  mkdir -p "\$(dirname "\$R")"
  N=\$(grep -oE 'CALL_ID: [0-9a-f]+' <<<"\$4" | head -1 | cut -d' ' -f2)
  jq -nc --arg s "$THREAD" '{type:"session_meta",payload:{id:\$s}}' >> "\$R"
  jq -nc --arg t "\$4" '{type:"response_item",payload:{type:"message",role:"user",content:[{type:"input_text",text:\$t}]}}' >> "\$R"
  if [[ "$reply" == done ]]; then
    jq -nc --arg t "STATUS: WORK_IN_PROGRESS call_id=\$N"\$'\n\n'"codex did it"\$'\n\n'"STATUS: WORK_COMPLETE call_id=\$N" \
      '{type:"response_item",payload:{type:"message",role:"assistant",phase:"final_answer",content:[{type:"output_text",text:\$t}]}}' >> "\$R"
    jq -nc '{type:"event_msg",payload:{type:"task_complete"}}' >> "\$R"
  fi
fi
exec bash "$t/bin/herdr-real" "\$@"
STUBW
  chmod +x "$t/bin/herdr"
}

# Every codex dial in this file: the herdr preflight's pane, and a confirmation budget
# measured in ticks rather than seconds.
CODEX_READY_SCREEN="$ROOT/codex-ready-screen"
printf '› Ask Codex to do anything\n  ? for shortcuts\n' > "$CODEX_READY_SCREEN"
CENV=(HOTLINE_HERDR_PANE=w1:p1 HOTLINE_HERDR_FIRST_SETTLE=0 HOTLINE_HERDR_PANE_SETTLE=0
      HOTLINE_PASTE_CONFIRM_SLEEP=0.05 HOTLINE_CODEX_COMPOSER_TRIES=5
      HERDR_STUB_SCREEN="$CODEX_READY_SCREEN")

# ===========================================================================
echo "1. --agent codex refuses what it cannot do yet — args errors, nothing launched:"
# ===========================================================================
refuses() {  # refuses <label> <detail-substring> <dial args...>
  local label="$1" want="$2"; shift 2
  local t; t=$(new_env); codex_env "$t"
  local out; out=$(dial "$t" "${CENV[@]}" -- --target "$t/target" --mode work_order \
                     --prompt "x" --agent codex "$@")
  [[ "$(jq -r .stage <<<"$out")" == args && "$(jq -r .detail <<<"$out")" == *"$want"* ]] \
    && ! grep -q 'agent start' "$t/herdr.log" 2>/dev/null
  check "$label" $? "out=$out"
}
refuses "--transport cmux"        "herdr-only"        --transport cmux
refuses "--transport headless"    "herdr-only"        --transport headless
refuses "--headless"              "herdr-only"        --headless
refuses "--remote"                "local-only"        --remote jt@box
refuses "--resume <id>"           "cannot continue"   --resume 11111111-2222-3333-4444-555555555555
refuses "--tools"                 "--allowedTools"    --tools "Read"
t=$(new_env); codex_env "$t"
out=$(dial "$t" "${CENV[@]}" HOTLINE_CALLEE_ENV="A=1" -- --target "$t/target" --mode work_order --prompt x --agent codex)
[[ "$(jq -r .stage <<<"$out")" == args && "$(jq -r .detail <<<"$out")" == *"HOTLINE_CALLEE_ENV"* ]]
check "HOTLINE_CALLEE_ENV set → args error (it rides claude's --settings)" $? "out=$out"
t=$(new_env)
out=$(dial "$t" "${CENV[@]}" -- --target "$t/target" --mode quick --prompt x --agent gemini)
[[ "$(jq -r .stage <<<"$out")" == args ]]
check "an unknown --agent → args error" $? "out=$out"
t=$(new_env)   # no codex on PATH: jq alone from its own dir, which may also hold a real codex
mkdir -p "$t/jqonly"; ln -s "$(command -v jq)" "$t/jqonly/jq"
out=$(env PATH="$t/bin:$t/jqonly:/usr/bin:/bin" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HOTLINE_CALLER_SESSION_ID=caller-dial-1 HOTLINE_PENDING_DIR="$t/pending" \
      HOTLINE_HERDR_PANE=w1:p1 bash "$DIAL" --label l --target "$t/target" --mode quick --prompt x --agent codex 2>/dev/null)
[[ "$(jq -r .stage <<<"$out")" == transport && "$(jq -r .detail <<<"$out")" == *"codex is not on PATH"* ]]
check "codex not on PATH → transport error before any pane is split" $? "out=$out"

# ===========================================================================
echo "2. A codex work order, end to end through the stubs:"
# ===========================================================================
t=$(new_env); codex_env "$t"
out=$(dial "$t" "${CENV[@]}" -- --target "$t/target" --mode work_order --prompt "fix the thing" --agent codex)
CD=$(jq -r '.call_dir // empty' <<<"$out")
[[ "$(jq -r .status <<<"$out")" == connected && "$(jq -r .agent <<<"$out")" == codex \
   && "$(jq -r .transport <<<"$out")" == herdr && "$(jq -r .confirmed <<<"$out")" == rollout ]]
check "dial → connected, agent:codex, transport herdr, confirmed by the rollout" $? "out=$out err=$(cat "$t/err.txt")"

START=$(grep 'agent start' "$t/herdr.log")
[[ "$START" == *"--kind codex"* && "$START" == *"check_for_update_on_startup=false"* \
   && "$START" != *"--session-id"* && "$START" != *"--allowedTools"* ]]
check "launch: --kind codex with the update check off, and no claude-only flags" $? "start=$START"

PROMPT_LINE=$(grep 'agent prompt' "$t/herdr.log")
! grep -q 'pane send-text' "$t/herdr.log" && [[ "$PROMPT_LINE" == *'$hotline:hotline-ringing'* && "$PROMPT_LINE" != *'/hotline:hotline-ringing'* ]]
check "delivery: ONE atomic prompt carrying the \$hotline:hotline-ringing mention, no split" $? "prompt=$PROMPT_LINE"

[[ "$(cat "$CD/agent_kind.txt")" == codex && "$(cat "$CD/session_id.txt")" == "$THREAD" \
   && "$(cat "$CD/codex_rollout.txt")" == *"$THREAD.jsonl" && ! -e "$CD/session_id_preset.txt" ]]
check "call dir: agent_kind codex, session_id = the codex thread id, rollout recorded, no claude preset" $?

CACHE=$(env HOME="$t/home" HOTLINE_PENDING_DIR="$t/pending" bash "$SCRIPTS/session-cache.sh" get "$(cd "$t/target" && pwd -P)" --caller-session caller-dial-1 2>/dev/null)
[[ -z "$CACHE" ]]
check "no follow-up cache entry — a later dial cannot re-target a codex agent with claude's protocol" $? "cache=$CACHE"

wout=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" HERDR_STATE="$t/state" \
       HERDR_STUB_AGENT_ANY=1 bash "$SCRIPTS/wait-for-response.sh" "$CD" --timeout 20 2>"$t/werr.txt"); wrc=$?
[[ $wrc -eq 0 && "$(jq -r .response <<<"$wout")" == "codex did it" && -s "$CD/response.json" \
   && "$(jq -r .session_id "$CD/response.json")" == "$THREAD" ]]
check "wait-for-response.sh → exit 0, the codex body in response.json" $? "rc=$wrc out=$wout err=$(cat "$t/werr.txt")"

# ===========================================================================
echo "3. Startup dialogs are refused before anything is typed:"
# ===========================================================================
t=$(new_env); codex_env "$t"
printf '  Hooks need review\n  5 hooks are new or changed.\n› 1. Review hooks\n' > "$t/screen"
out=$(dial "$t" "${CENV[@]}" HERDR_STUB_SCREEN="$t/screen" -- --target "$t/target" --mode quick --prompt x --agent codex)
[[ "$(jq -r .stage <<<"$out")" == deliver && "$(jq -r .sent <<<"$out")" == false \
   && "$(jq -r .detail <<<"$out")" == *"HOOKS-REVIEW"* ]] && ! grep -q 'agent prompt' "$t/herdr.log"
check "hooks-review dialog (herdr says idle+ready) → deliver error, sent:false, no prompt" $? "out=$out"

# herdr calls codex ready BEFORE the hooks dialog draws, so a screen with neither the
# dialog nor the composer yet must not be read as "clear to type".
t=$(new_env); codex_env "$t"
printf '  booting\n' > "$t/screen"
out=$(dial "$t" "${CENV[@]}" HERDR_STUB_SCREEN="$t/screen" -- --target "$t/target" --mode quick --prompt x --agent codex)
[[ "$(jq -r .stage <<<"$out")" == deliver && "$(jq -r .sent <<<"$out")" == false \
   && "$(jq -r .detail <<<"$out")" == *"never drew its input composer"* ]] && ! grep -q 'agent prompt' "$t/herdr.log"
check "no composer yet (and no dialog yet) → refused, sent:false, no prompt" $? "out=$out"

# ===========================================================================
echo "4. A turn that ends with no STATUS for the nonce is not waited out:"
# ===========================================================================
t=$(new_env); codex_env "$t" none
out=$(dial "$t" "${CENV[@]}" -- --target "$t/target" --mode quick --prompt x --agent codex)
CD=$(jq -r '.call_dir // empty' <<<"$out")
wout=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" HERDR_STATE="$t/state" \
       HERDR_STUB_AGENT_ANY=1 HERDR_STUB_STATUS=idle HOTLINE_STALL_SECONDS=1 HOTLINE_HERDR_WAIT_SLICE_MS=10 \
       bash "$SCRIPTS/wait-for-response.sh" "$CD" --timeout 30 2>"$t/werr.txt"); wrc=$?
[[ $wrc -eq 6 ]]
check "submitted, idle, no STATUS → exit 6 STALLED (the protocol-not-followed case)" $? "rc=$wrc err=$(head -c 400 "$t/werr.txt")"

herdr_suite_finish
