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
if [[ "\$1 \${2:-}" == "tab create" ]]; then
  for arg in "\$@"; do
    [[ "\$arg" == CODEX_HOME=* ]] && printf '%s' "\${arg#CODEX_HOME=}" > "\$HERDR_STATE/process_home"
  done
fi
if [[ "\$1 \${2:-}" == "agent prompt" && "\${HERDR_STUB_CODEX_NO_ROLLOUT:-}" != 1 ]]; then
  PROCESS_HOME=\$(cat "\$HERDR_STATE/process_home" 2>/dev/null || printf '%s' "\${CODEX_HOME:-\$HOME/.codex}")
  R="\$PROCESS_HOME/sessions/2026/11/03/rollout-2026-11-03T12-56-13-$THREAD.jsonl"
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
refuses "--transport cmux --mode conference" "does not support --mode conference" --transport cmux --mode conference
refuses "--resume <id> --headless" "herdr only"     --resume 11111111-2222-3333-4444-555555555555 --headless
refuses "--resume <id>"           "cannot continue"   --resume 11111111-2222-3333-4444-555555555555
refuses "--tools"                 "--allowedTools"    --tools "Read"
t=$(new_env); codex_env "$t"
out=$(dial "$t" "${CENV[@]}" HOTLINE_CALLEE_ENV="A=1 B=two" -- --target "$t/target" --mode work_order --prompt x --agent codex)
START=$(grep 'agent start' "$t/herdr.log")
[[ "$(jq -r .status <<<"$out")" == connected && "$START" == *'shell_environment_policy.set.A=\"1\"'* \
   && "$START" == *'shell_environment_policy.set.B=\"two\"'* ]]
check "HOTLINE_CALLEE_ENV → codex shell_environment_policy.set overrides on the launch argv" $? "out=$out start=$START"
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
[[ "$(jq -r .agent_kind <<<"$CACHE")" == codex && "$(jq -r .session_id <<<"$CACHE")" == "$THREAD" ]]
check "cache records the codex thread and agent kind" $? "cache=$CACHE"

wout=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" HERDR_STATE="$t/state" \
       HERDR_STUB_AGENT_ANY=1 bash "$SCRIPTS/wait-for-response.sh" "$CD" --timeout 20 2>"$t/werr.txt"); wrc=$?
[[ $wrc -eq 0 && "$(jq -r .response <<<"$wout")" == "codex did it" && -s "$CD/response.json" \
   && "$(jq -r .session_id "$CD/response.json")" == "$THREAD" ]]
check "wait-for-response.sh → exit 0, the codex body in response.json" $? "rc=$wrc out=$wout err=$(cat "$t/werr.txt")"

t=$(new_env); codex_env "$t"
out=$(dial "$t" "${CENV[@]}" HOTLINE_CODEX_ARGS="--disable hooks" HOTLINE_CODEX_MODEL=gpt-x \
      HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS=1 -- --target "$t/target" --mode quick --prompt x --agent codex)
START=$(grep 'agent start' "$t/herdr.log")
[[ "$START" == *"--disable hooks"* && "$START" == *"-m gpt-x"* && "$START" == *"--dangerously-bypass-approvals-and-sandbox"* ]]
check "HOTLINE_CODEX_ARGS / _MODEL / DANGEROUSLY_SKIP_PERMISSIONS reach the codex argv" $? "start=$START"

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

# ====================================================================
# ===========================================================================
echo "5. --headless --agent codex runs codex exec, same call-dir contract:"
# ===========================================================================
# A `codex exec` stand-in: the real CLI's event shapes (thread.started, item.completed,
# turn.completed) on stdout, the final message in the -o file, the prompt on stdin.
headless_codex() {  # headless_codex <scratch> [reply]
  local t="$1"
  cat > "$t/bin/codex" <<STUB
#!/usr/bin/env bash
printf '%q ' "\$@" >> "$t/codex.log"; printf '\n' >> "$t/codex.log"
OUT=""; prev=""
for a in "\$@"; do [[ "\$prev" == "-o" ]] && OUT="\$a"; prev="\$a"; done
cat > "$t/codex.stdin"
echo '{"type":"thread.started","thread_id":"$THREAD"}'
echo '{"type":"turn.started"}'
printf '%s\n' "${2:-STATUS: WORK_IN_PROGRESS

headless codex answer

STATUS: DONE}" > "\$OUT"
echo '{"type":"item.completed","item":{"type":"agent_message","text":"x"}}'
echo '{"type":"turn.completed","usage":{}}'
STUB
  chmod +x "$t/bin/codex"
}
# The worker is a real background process; the waiter's clock is the harness's, so
# give the worker real time to finish before asking.
await_done() { local i=0; while [[ ! -e "$1/done" && $i -lt 100 ]]; do sleep 0.1; i=$((i + 1)); done; }
t=$(new_env); headless_codex "$t"
out=$(dial "$t" HOTLINE_CALL_HOME="$t" HOTLINE_CALLEE_ENV="A=1" -- --target "$t/target" --mode quick --prompt "what is up" --agent codex --headless)
CD=$(jq -r '.call_dir // empty' <<<"$out")
[[ "$(jq -r .status <<<"$out")" == connected && "$(jq -r .transport <<<"$out")" == headless && "$(jq -r .agent <<<"$out")" == codex ]]
check "dial → connected, transport headless, agent codex" $? "out=$out err=$(cat "$t/err.txt")"
await_done "$CD"
wout=$(env PATH="$t/bin:$PATH" HOME="$t/home" bash "$SCRIPTS/wait-for-response.sh" "$CD" --timeout 20 2>"$t/werr.txt"); wrc=$?
[[ $wrc -eq 0 && "$(jq -r .session_id <<<"$wout")" == "$THREAD" && "$(jq -r .response <<<"$wout")" == *"headless codex answer"* ]]
check "wait-for-response.sh → exit 0, thread id + codex's last message" $? "rc=$wrc out=$wout err=$(cat "$t/werr.txt")"
CL=$(cat "$t/codex.log")
[[ "$CL" == "exec --json -o "* && "$CL" == *'shell_environment_policy.set.A=\"1\"'* && "$CL" == *" - " \
   && "$CL" != *"what is up"* && "$(cat "$t/codex.stdin")" == *"what is up"* && "$(cat "$t/codex.stdin")" == *'$hotline:hotline-ringing'* ]]
check "argv: exec --json -o, callee env as -c overrides, prompt on STDIN (never argv)" $? "argv=$CL"
[[ "$(cat "$t/codex.stdin")" != *"call_id=<"* ]]
check "the headless STATUS reminder is bare — a headless call carries no nonce" $? "stdin=$(cat "$t/codex.stdin")"
CACHE=$(env HOME="$t/home" HOTLINE_PENDING_DIR="$t/pending" bash "$SCRIPTS/session-cache.sh" get "$(cd "$t/target" && pwd -P)" --caller-session caller-dial-1 2>/dev/null)
[[ -z "$CACHE" ]]
check "a headless codex call is NOT cached — the headless follow-up is \`claude -p --resume\`" $? "cache=$CACHE"

t=$(new_env); headless_codex "$t" $'STATUS: WORK_IN_PROGRESS\nwhich branch?\nSTATUS: BLOCKED'
out=$(dial "$t" HOTLINE_CALL_HOME="$t" -- --target "$t/target" --mode work_order --prompt x --agent codex --headless)
CD=$(jq -r '.call_dir // empty' <<<"$out")
await_done "$CD"
env PATH="$t/bin:$PATH" HOME="$t/home" bash "$SCRIPTS/wait-for-response.sh" "$CD" --timeout 20 >/dev/null 2>&1; wrc=$?
[[ $wrc -eq 7 && "$(jq -r .blocked "$CD/response.json")" == true ]]
check "a codex exec reply ending on BLOCKED → exit 7, the shared headless marker" $? "rc=$wrc resp=$(cat "$CD/response.json" 2>/dev/null)"
# ===========================================================================
echo "6. Follow-ups, agent isolation, and thread adoption:"
t=$(new_env); codex_env "$t"
out=$(dial "$t" "${CENV[@]}" -- --target "$t/target" --mode quick --prompt first --agent codex)
agent=$(cat "$(jq -r .call_dir <<<"$out")/herdr_agent.txt")
oldnonce=$(cat "$(jq -r .call_dir <<<"$out")/call_id.txt")
out=$(dial "$t" "${CENV[@]}" -- --target "$t/target" --mode quick --prompt second --agent codex)
CD=$(jq -r '.call_dir // empty' <<<"$out")
[[ "$(jq -r .status <<<"$out")" == connected && "$(jq -r .confirmed <<<"$out")" == rollout \
   && "$(cat "$CD/herdr_agent.txt")" == "$agent" && "$(cat "$CD/agent_kind.txt")" == codex \
   && $(grep -c 'agent start' "$t/herdr.log") -eq 1 && "$(cat "$CD/call_id.txt")" != "$oldnonce" ]]
check "second dial reuses the codex agent, with a fresh nonce and rollout confirmation" $? "out=$out"
line=$(grep 'agent prompt' "$t/herdr.log" | tail -1)
[[ "$line" == *'$hotline:hotline-ringing [FOLLOW_UP]'* ]] && ! grep -q 'pane send-text' "$t/herdr.log"
check "codex follow-up is an atomic dollar mention, never a slash split" $? "line=$line"
wout=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" HERDR_STATE="$t/state" \
       bash "$WAIT_RESPONSE" "$CD" --timeout 5 2>"$t/werr"); rc=$?
[[ $rc -eq 0 && "$(jq -r .response <<<"$wout")" == 'codex did it' ]]
check "follow-up waiter extracts only the new nonce's response" $? "rc=$rc out=$wout"

out=$(dial "$t" "${CENV[@]}" HERDR_STUB_GONE_NAMES="$agent" -- --target "$t/target" --mode quick --prompt third --agent codex)
[[ "$(jq -r .status <<<"$out")" == connected && $(grep -c 'agent start' "$t/herdr.log") -eq 2 \
   && "$(grep 'agent start' "$t/herdr.log" | tail -1)" == *"resume $THREAD"* \
   && "$(jq -r '.fallbacks | join(" ")' <<<"$out")" == *'herdr-agent-reuse→resumed'* ]]
check "dead cached codex agent → a new agent RESUMES the cached thread (codex can be re-hosted)" $? "out=$out"
[[ "$(grep 'agent prompt' "$t/herdr.log" | tail -1)" != *'[FOLLOW_UP]'* ]]
check "dead-agent fallback reshapes the payload as first contact" $?

wrap_herdr_transcript "$t" claude-new
out=$(dial "$t" "${CENV[@]}" -- --target "$t/target" --mode quick --prompt claude-next --transport herdr)
[[ "$(jq -r .status <<<"$out")" == connected \
   && "$(jq -r '.fallbacks | join(" ")' <<<"$out")" == *'agent-kind codex→claude'* \
   && $(grep -c 'agent start' "$t/herdr.log") -eq 3 ]]
check "claude never re-targets a cached codex agent" $? "out=$out"
codex_env "$t"
out=$(dial "$t" "${CENV[@]}" -- --target "$t/target" --mode quick --prompt codex-next --agent codex)
[[ "$(jq -r .status <<<"$out")" == connected \
   && "$(jq -r '.fallbacks | join(" ")' <<<"$out")" == *'agent-kind claude→codex'* \
   && $(grep -c 'agent start' "$t/herdr.log") -eq 4 ]]
check "codex never re-targets a cached claude agent" $? "out=$out"

seed_thread() {
  local dir="$1" cwd="$2"
  mkdir -p "$dir/sessions/old"
  jq -nc --arg s "$THREAD" --arg cwd "$cwd" '{type:"session_meta",payload:{id:$s,cwd:$cwd}}' \
    > "$dir/sessions/old/rollout-old-$THREAD.jsonl"
  touch -t 202001010000 "$dir/sessions/old/rollout-old-$THREAD.jsonl"
}
for shape in resume target; do
  t=$(new_env); codex_env "$t"; seed_thread "$t/custom-codex" "$t/target"
  args=(--target "$t/target" --resume "$THREAD")
  [[ "$shape" == target ]] && args=(--target "$THREAD")
  out=$(dial "$t" "${CENV[@]}" CODEX_HOME="$t/custom-codex" -- "${args[@]}" --mode quick --prompt adopt --agent codex)
  [[ "$(jq -r .status <<<"$out")" == connected && "$(grep 'agent start' "$t/herdr.log")" == *"resume $THREAD"* ]]
  check "$shape adopts an old Codex thread from CODEX_HOME via codex resume" $? "out=$out err=$(cat "$t/err.txt")"
done

echo "7. Remote Codex: remote HOME, remote confirmation, and a refreshed local mirror:"
t=$(new_env); codex_env "$t"; mkdir -p "$t/remote-home"
RENV=("${CENV[@]}" SSH_STUB_HOME="$t/remote-home" SSH_STUB_NO_CLAUDE=1)
out=$(dial "$t" "${RENV[@]}" -- --target "$t/target" --remote tester@no-such-box.invalid --agent codex --mode quick --prompt remote-first)
CD=$(jq -r '.call_dir // empty' <<<"$out")
[[ "$(jq -r .status <<<"$out")" == connected && "$(jq -r .confirmed <<<"$out")" == rollout \
   && "$(cat "$CD/codex_rollout.txt")" == "$t/remote-home/"* && ! -d "$t/home/.codex/sessions" ]]
check "remote dial confirms from remote HOME without requiring remote claude" $? "out=$out err=$(cat "$t/err.txt")"
[[ $(grep -c 'CALL_ID:.*grep\|grep.*CALL_ID:' "$t/ssh.log") -eq 1 ]]
check "remote nonce confirmation polls in one SSH hop" $? "log=$(cat "$t/ssh.log")"
wout=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" HERDR_STATE="$t/state" \
       SSH_LOG="$t/ssh.log" SSH_STUB_HOME="$t/remote-home" HOTLINE_HERDR_REMOTE= \
       bash "$WAIT_RESPONSE" "$CD" --timeout 5 2>"$t/werr"); rc=$?
[[ $rc -eq 0 && "$(jq -r .response <<<"$wout")" == 'codex did it' \
   && -s "$CD/codex_rollout_mirror.jsonl" && -s "$CD/codex_transcript.jsonl" ]]
check "remote waiter learns the hop from metadata and normalizes a fetched local mirror" $? "rc=$rc out=$wout err=$(cat "$t/werr")"
out=$(dial "$t" "${RENV[@]}" -- --target "$t/target" --remote tester@no-such-box.invalid --agent codex --mode quick --prompt remote-followup)
[[ "$(jq -r .status <<<"$out")" == connected && $(grep -c 'agent start' "$t/herdr.log") -eq 1 \
   && "$(grep 'agent prompt' "$t/herdr.log" | tail -1)" == *'[FOLLOW_UP]'* ]]
check "remote follow-up reuses the cached codex agent through the existing SSH helpers" $? "out=$out"

t=$(new_env); codex_env "$t"
out=$(dial "$t" "${CENV[@]}" SSH_STUB_NO_CODEX=1 -- --target "$t/target" --remote tester@no-such-box.invalid --agent codex --mode quick --prompt x)
[[ "$(jq -r .stage <<<"$out")" == transport && "$(jq -r .detail <<<"$out")" == *'codex is not on the PATH'* ]] \
  && ! grep -q 'agent start' "$t/herdr.log"
check "missing remote codex fails preflight before launch" $? "out=$out"

t=$(new_env); codex_env "$t"; mkdir -p "$t/remote-home"
seed_thread "$t/remote-home/.codex" "$t/target"
out=$(dial "$t" "${CENV[@]}" SSH_STUB_HOME="$t/remote-home" -- --target "$THREAD" \
      --remote tester@no-such-box.invalid --agent codex --mode quick --prompt adopt-remote)
[[ "$(jq -r .status <<<"$out")" == connected && "$(grep 'agent start' "$t/herdr.log")" == *"resume $THREAD"* \
   && ! -d "$t/home/.codex/sessions" ]]
check "a remote thread-id target resolves its thread and workspace on the remote box" $? "out=$out"

t=$(new_env); codex_env "$t" none; mkdir -p "$t/remote-home"
out=$(dial "$t" "${CENV[@]}" SSH_STUB_HOME="$t/remote-home" -- --target "$t/target" \
      --remote tester@no-such-box.invalid --agent codex --mode quick --prompt delayed-remote)
CD=$(jq -r '.call_dir // empty' <<<"$out")
nonce=$(cat "$CD/call_id.txt")
raw=$(cat "$CD/codex_rollout.txt")
jq -nc --arg t "STATUS: WORK_IN_PROGRESS call_id=$nonce"$'\n'"arrived later"$'\n'"STATUS: DONE call_id=$nonce" \
  '{type:"response_item",payload:{type:"message",role:"assistant",phase:"final_answer",content:[{type:"output_text",text:$t}]}}' > "$t/late.jsonl"
cat > "$t/append.sh" <<HOOK
cat "$t/late.jsonl" >> "$raw"
HOOK
wout=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" HERDR_STATE="$t/state" \
       SSH_LOG="$t/ssh.log" SSH_STUB_HOME="$t/remote-home" HOTLINE_HERDR_REMOTE= \
       HERDR_STUB_WAIT_HOOK="bash '$t/append.sh'" HOTLINE_HERDR_WAIT_SLICE_MS=10 \
       bash "$WAIT_RESPONSE" "$CD" --timeout 10 2>"$t/werr"); rc=$?
[[ $rc -eq 0 && "$(jq -r .response <<<"$wout")" == 'arrived later' \
   && $(grep -c 'for p in.*rollout-2026' "$t/ssh.log") -ge 2 ]]
check "each poll fetches again, so a reply appended after the first mirror is observed" $? "rc=$rc out=$wout"

t=$(new_env); codex_env "$t"
out=$(dial "$t" "${CENV[@]}" HERDR_STUB_BLOCKED_ONCE=1 HOTLINE_HERDR_BLOCKED_SETTLE=0 \
      -- --target "$t/target" --agent codex --mode quick --prompt first)
out=$(dial "$t" "${CENV[@]}" HERDR_STUB_STATUS=blocked HOTLINE_HERDR_BLOCKED_SETTLE=0 \
      -- --target "$t/target" --agent codex --mode quick --prompt second)
[[ "$(jq -r .stage <<<"$out")" == transport && "$(jq -r .detail <<<"$out")" == *BLOCKED* \
   && $(grep -c 'agent start' "$t/herdr.log") -eq 1 && $(grep -c 'agent prompt' "$t/herdr.log") -eq 1 ]]
check "a blocked live Codex agent refuses a follow-up without starting another callee" $? "out=$out"

t=$(new_env); codex_env "$t"
out=$(dial "$t" "${CENV[@]}" -- --target "$t/target" --agent codex --mode quick --prompt first)
out=$(dial "$t" "${CENV[@]}" HERDR_STUB_CODEX_NO_ROLLOUT=1 HOTLINE_PASTE_CONFIRM_TRIES=2 \
      -- --target "$t/target" --agent codex --mode quick --prompt unconfirmed)
[[ "$(jq -r .stage <<<"$out")" == deliver && $(grep -c 'agent start' "$t/herdr.log") -eq 1 \
   && -s "$(jq -r .call_dir <<<"$out")/pending_paste.md" ]]
check "an accepted follow-up with no nonce proof preserves the payload and never starts a duplicate" $? "out=$out"

t=$(new_env); codex_env "$t"; mkdir -p "$t/remote-home"
out=$(dial "$t" "${CENV[@]}" SSH_STUB_HOME="$t/remote-home" HERDR_STUB_CODEX_NO_ROLLOUT=1 \
      HOTLINE_HERDR_FIRST_CONFIRM_TRIES=2 -- --target "$t/target" --remote tester@no-such-box.invalid \
      --agent codex --mode quick --prompt absent)
[[ "$(jq -r .stage <<<"$out")" == deliver && "$(jq -r .sent <<<"$out")" == true \
   && $(grep -c 'grep.*CALL_ID:' "$t/ssh.log") -eq 1 ]]
check "remote confirmation without a nonce refuses delivery in one bounded hop" $? "out=$out"

t=$(new_env); codex_env "$t"
out=$(dial "$t" "${CENV[@]}" -- --target "$t/target" --agent codex --mode quick --prompt first)
agent=$(cat "$(jq -r .call_dir <<<"$out")/herdr_agent.txt")
out=$(dial "$t" "${CENV[@]}" HERDR_STUB_GONE_NAMES="$agent" -- --target "$t/target" \
      --resume "$THREAD" --agent codex --mode quick --prompt explicit-followup)
[[ "$(jq -r .status <<<"$out")" == connected \
   && "$(jq -r '.fallbacks | join(" ")' <<<"$out")" == *'herdr-agent-reuse→resumed'* \
   && "$(grep 'agent start' "$t/herdr.log" | tail -1)" == *"resume $THREAD"* ]]
check "an explicit --resume of a cached thread whose agent died resumes it" $? "out=$out"

echo "Explicit process home, discovery and independent response waiter:"
t=$(new_env); codex_env "$t"; mkdir -p "$t/work"
selected=$(cd "$t/work" && pwd -P)
out=$(dial "$t" "${CENV[@]}" HOTLINE_CODEX_HOME="$t/work" HOTLINE_HERDR_PLACEMENT=tab -- \
  --target "$t/target" --mode work_order --prompt "selected-account" --agent codex --fresh)
CD=$(jq -r '.call_dir // empty' <<<"$out")
[[ "$(jq -r .status <<<"$out")" == connected && "$(jq -r .confirmed <<<"$out")" == rollout \
   && "$(cat "$t/state/process_home")" == "$(cd "$t/work" && pwd -P)" \
   && "$(cat "$CD/codex_rollout.txt")" == "$selected/"* ]]
check "selected home reaches process via pane env, then delivery discovers its rollout" $? "out=$out"
if [[ -n "$CD" && -d "$CD" ]]; then
  rm -f "$CD/codex_rollout.txt"
  wout=$(env -u HOTLINE_CODEX_HOME CODEX_HOME="$t/personal" PATH="$t/bin:$PATH" HOME="$t/home" \
    HERDR_LOG="$t/herdr.log" HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 \
    bash "$WAIT_RESPONSE" "$CD" --timeout 2 2>"$t/werr.txt"); wrc=$?
  [[ $wrc == 0 && "$(jq -r .response <<<"$wout")" == 'codex did it' \
     && "$(cat "$CD/codex_rollout.txt")" == "$selected/"* ]]
  check "waiter with another ambient home rediscovers selected rollout from call metadata" $? "out=$wout err=$(cat "$t/werr.txt")"
else
  fail "waiter needs launched call dir"
fi
herdr_suite_finish
