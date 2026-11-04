#!/usr/bin/env bash
# Follow-up identity must survive caller-home changes, metadata rollover and death.
# Removing pin checks must allow a mismatched account/session or a personal restart.
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/codex-transport-harness.sh"
FENV=("${CENV[@]}" HERDR_STUB_AGENT_KIND=codex HERDR_STUB_OBSERVED_SID="$THREAD" HERDR_STUB_AGENT_PANE=w1:p7)
t=$(new_env); codex_env "$t"; mkdir -p "$t/work" "$t/personal"
# All new continuation cases use snapshots and stubbed naps, never real sleeps.
printf '#!/bin/sh\nexit 0\n' > "$t/bin/sleep"; chmod +x "$t/bin/sleep"
selected=$(cd "$t/work" && pwd -P)
out=$(dial "$t" "${FENV[@]}" HOTLINE_CODEX_HOME="$selected" HOTLINE_HERDR_PLACEMENT=tab -- \
  --target "$t/target" --mode work_order --prompt first --agent codex --fresh)
first=$(jq -r '.call_dir // empty' <<<"$out")
[[ "$(jq -r .status <<<"$out")" == connected ]]
check 'fixture launches selected-home call through real dial path' $? "out=$out"
[[ -d "$first" ]] || herdr_suite_finish
agent=$(cat "$first/herdr_agent.txt"); rollout=$(cat "$first/codex_rollout.txt")
cache_get() { env HOME="$t/home" bash "$SCRIPTS/session-cache.sh" get "$t/target" --caller-session caller-dial-1; }
[[ "$(cache_get | jq -r .codex_home)" == "$selected" ]]
check 'cache records selected home independently of expiring call directory' $?
follow() { dial "$t" "${FENV[@]}" "$@" -- --target "$t/target" --mode work_order --prompt second --agent codex; }
no_input() { [[ $(grep -c 'agent prompt' "$t/herdr.log") == "$prompts" && $(grep -c 'agent start' "$t/herdr.log") == 1 ]]; }

# The first landed contract wrote call metadata without a cache marker. Upgrade
# that existing call on continuation, without requiring a second disposable callee.
cache_file="$t/home/.agents-hotline/sessions/caller-dial-1.json"
jq '(.connections[]) |= del(.codex_home)' "$cache_file" > "$cache_file.tmp"; mv "$cache_file.tmp" "$cache_file"
out=$(follow HOTLINE_CODEX_HOME="$selected")
second=$(jq -r '.call_dir // empty' <<<"$out")
[[ "$(jq -r .status <<<"$out")" == connected && "$(jq -r .first_contact <<<"$out")" == false && "$second" != "$first" ]]
check 'explicit same-home NONFRESH dial continues the cached agent' $? "out=$out"
[[ "$(cache_get | jq -r .codex_home)" == "$selected" ]]
check 'existing selected-call cache gains a durable pin on continuation' $?
if [[ -d "$second" ]]; then
  [[ "$(cat "$second/codex_home.txt")" == "$selected" && "$(cat "$second/codex_rollout.txt")" == "$rollout" \
     && "$(cat "$second/herdr_pane.txt")" == "$(cat "$first/herdr_pane.txt")" && $(grep -c 'agent start' "$t/herdr.log") == 1 ]]
  check 'followup copies home, rollout and process-host metadata without launching' $?
else fail 'followup metadata requires successful reuse'; fi

out=$(follow CODEX_HOME="$t/personal")
third=$(jq -r '.call_dir // empty' <<<"$out")
[[ "$(jq -r .status <<<"$out")" == connected && "$(cat "$third/codex_home.txt" 2>/dev/null)" == "$selected" \
   && "$(cat "$third/codex_rollout.txt" 2>/dev/null)" == "$rollout" ]]
check 'omitted override inherits cached account across multiple followups despite personal ambient home' $? "out=$out"
if [[ -d "$third" ]]; then
  wout=$(env -u HOTLINE_CODEX_HOME PATH="$t/bin:$PATH" HOME="$t/home" CODEX_HOME="$t/personal" \
    HERDR_LOG="$t/herdr.log" HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 \
    bash "$WAIT_RESPONSE" "$third" --timeout 2 2>"$t/werr"); rc=$?
  [[ $rc == 0 && "$(jq -r .response <<<"$wout")" == 'codex did it' ]]
  check 'independent waiter uses continued-call metadata under another ambient account' $? "out=$wout"
else fail 'independent waiter requires continued-call metadata'; fi

prompts=$(grep -c 'agent prompt' "$t/herdr.log"); cached=$(cache_get | jq -r .last_call_dir)
out=$(follow HOTLINE_CODEX_HOME="$t/personal")
[[ "$(jq -r .status <<<"$out")" == error && "$(jq -r .detail <<<"$out")" == *'home'* ]] && no_input \
  && [[ "$(cache_get | jq -r .last_call_dir)" == "$cached" ]]
check 'explicit account mismatch refuses before delivery or cache mutation' $? "out=$out"
for fault in session pane kind dead; do
  case "$fault" in
    session) extra=(HERDR_STUB_INCLUDE_SESSION=1 HERDR_STUB_OBSERVED_SID=11111111-2222-3333-4444-555555555555) ;;
    pane) extra=(HERDR_STUB_AGENT_PANE=w1:p99) ;;
    kind) extra=(HERDR_STUB_AGENT_KIND=claude) ;;
    dead) extra=(HERDR_STUB_GONE_NAMES="$agent") ;;
  esac
  out=$(follow CODEX_HOME="$t/personal" "${extra[@]}")
  [[ "$(jq -r .status <<<"$out")" == error ]] && no_input
  check "pinned $fault mismatch/death refuses without sending or personal restart" $? "out=$out"
done
# Native herdr 0.9.5 Codex agent-get omits agent_session (captured in the
# overseer's pipeline-source-smoke/live-agent.json). Verify its process instead.
cat > "$t/bin/lsof" <<'STUB'
#!/usr/bin/env bash
[[ "$*" == '-nP -a -p 5151 -Fn' ]] || exit 1
[[ "${LSOF_STUB_FAIL:-}" != 1 ]] || exit 1
printf 'p5151\nn%s\n' "${LSOF_STUB_ROLLOUT:?}"
[[ -z "${LSOF_STUB_EXTRA:-}" ]] || printf 'n%s\n' "$LSOF_STUB_EXTRA"
STUB
chmod +x "$t/bin/lsof"
out=$(follow CODEX_HOME="$t/personal" HERDR_STUB_OMIT_SESSION=1 HERDR_STUB_CODEX_PID=5151 LSOF_STUB_ROLLOUT="$rollout")
native_dir=$(jq -r '.call_dir // empty' <<<"$out")
[[ "$(jq -r .status <<<"$out")" == connected && "$(jq -r .first_contact <<<"$out")" == false \
   && "$(cat "$native_dir/codex_rollout.txt" 2>/dev/null)" == "$rollout" ]]
check 'native no-agent_session capture continues only through pinned rollout process ownership' $? "out=$out"
prompts=$(grep -c 'agent prompt' "$t/herdr.log"); cached=$(cache_get | jq -r .last_call_dir)
out=$(follow HERDR_STUB_OMIT_SESSION=1 HERDR_STUB_CODEX_PID=5151 LSOF_STUB_ROLLOUT="$t/personal/sessions/rollout-wrong.jsonl")
[[ "$(jq -r .status <<<"$out")" == error ]] && no_input
check 'native missing-session fallback refuses a process holding another account rollout' $? "out=$out"
out=$(follow HERDR_STUB_OMIT_SESSION=1 HERDR_STUB_NO_CODEX_PROCESS=1)
[[ "$(jq -r .status <<<"$out")" == error ]] && no_input
check 'native missing-session fallback refuses missing foreground Codex process proof' $? "out=$out"

out=$(follow HERDR_STUB_OMIT_SESSION=1 HERDR_STUB_CODEX_PID=5151 LSOF_STUB_ROLLOUT="$rollout" LSOF_STUB_EXTRA="$t/personal/sessions/rollout-other.jsonl")
[[ "$(jq -r .status <<<"$out")" == error ]] && no_input
check 'native missing-session fallback refuses ambiguous multiple rollout ownership' $? "out=$out"
out=$(follow HERDR_STUB_OMIT_SESSION=1 HERDR_STUB_CODEX_PID=5151 LSOF_STUB_ROLLOUT="$rollout" LSOF_STUB_FAIL=1)
[[ "$(jq -r .status <<<"$out")" == error ]] && no_input
check 'native missing-session fallback refuses unavailable process file evidence' $? "out=$out"

out=$(follow HERDR_STUB_INCLUDE_SESSION=1 HERDR_STUB_CODEX_PID=5151 LSOF_STUB_ROLLOUT="$t/personal/sessions/rollout-other.jsonl")
[[ "$(jq -r .status <<<"$out")" == error ]] && no_input
check 'matching reported session never overrides contradictory foreground rollout ownership' $? "out=$out"

# Losing the original metadata must not erase the cache's account contract.
mv "$cached/codex_home.txt" "$cached/codex_home.saved"
out=$(follow CODEX_HOME="$t/personal")
[[ "$(jq -r .status <<<"$out")" == error ]] && no_input
check 'missing account metadata refuses instead of treating selected cache as legacy personal call' $? "out=$out"
herdr_suite_finish
