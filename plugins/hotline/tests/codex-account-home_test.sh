#!/usr/bin/env bash
# Process account selection must cross the herdr boundary before agent start.
# Removing --env must fail this suite even if the caller's CODEX_HOME is correct.
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/herdr-transport-harness.sh"
unset HOTLINE_CODEX_HOME CODEX_HOME
launch() {
  env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" HERDR_STATE="$t/state" \
    HOTLINE_HERDR_PANE=w1:p1 "$@" bash "$HERDR_ASYNC" --cwd "$t/target" --prompt x --agent codex
}
for placement in tab workspace; do
  t=$(new_env); printf '#!/bin/sh\nexit 0\n' > "$t/bin/codex"; chmod +x "$t/bin/codex"
  mkdir -p "$t/work home"
  selected=$(cd "$t/work home" && pwd -P)
  out=$(launch HOTLINE_CODEX_HOME="$selected" HOTLINE_HERDR_PLACEMENT="$placement" HOTLINE_HERDR_WORKSPACE=workers)
  cd_call=$(jq -r '.call_dir // empty' <<<"$out")
  printf -v quoted_home '%q' "CODEX_HOME=$selected"
  grep 'tab create' "$t/herdr.log" | grep -Fq -- "--env $quoted_home"
  check "$placement passes selected home to pane environment" $? "out=$out"
  [[ -n "$cd_call" && "$(cat "$cd_call/codex_home.txt" 2>/dev/null)" == "$selected" ]]
  check "$placement persists account home for independent waiters" $?
done

t=$(new_env); printf '#!/bin/sh\nexit 0\n' > "$t/bin/codex"; chmod +x "$t/bin/codex"
out=$(launch HOTLINE_HERDR_PLACEMENT=tab)
! grep -q -- '--env' "$t/herdr.log" && [[ ! -e "$(jq -r .call_dir <<<"$out")/codex_home.txt" ]]
check 'unset preserves launch argv and metadata' $?
for bad in relative "$t/missing" ''; do
  : > "$t/herdr.log"
  out=$(launch HOTLINE_CODEX_HOME="$bad" HOTLINE_HERDR_PLACEMENT=tab)
  [[ "$(jq -r '.error // empty' <<<"$out")" == *HOTLINE_CODEX_HOME* ]] && ! grep -q 'agent start' "$t/herdr.log"
  check "invalid home refused: '$bad'" $? "out=$out"
done
stub_headless_claude "$t"
mkdir -p "$t/work"
for extra in 'split' 'remote' 'resume'; do
  : > "$t/herdr.log"
  case "$extra" in
    split) out=$(launch HOTLINE_CODEX_HOME="$t/work") ;;
    remote) out=$(launch HOTLINE_CODEX_HOME="$t/work" HOTLINE_HERDR_PLACEMENT=tab HOTLINE_HERDR_REMOTE=remote) ;;
    resume) out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HOTLINE_CODEX_HOME="$t/work" HOTLINE_HERDR_PLACEMENT=tab bash "$HERDR_ASYNC" --cwd "$t/target" --prompt x --agent codex --resume 11111111-2222-3333-4444-555555555555) ;;
  esac
  [[ "$(jq -r '.error // empty' <<<"$out")" == *HOTLINE_CODEX_HOME* ]] && ! grep -q 'agent start' "$t/herdr.log"
  check "$extra refused before launch" $? "out=$out"
done
for flags in '--agent claude --fresh' '--agent codex' '--agent codex --fresh --headless' '--agent codex --fresh --transport cmux'; do
  out=$(dial "$t" HOTLINE_CODEX_HOME="$t/work" HOTLINE_HERDR_PLACEMENT=tab -- --target "$t/target" --mode quick --prompt x $flags)
  [[ "$(jq -r .stage <<<"$out")" == args && "$(jq -r .detail <<<"$out")" == *HOTLINE_CODEX_HOME* ]]
  check "dial rejects unsupported selection: $flags" $? "out=$out"
done

for entry in headless-call-async.sh cmux-call-async.sh herdr-reuse-agent.sh; do
  out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HOTLINE_CODEX_HOME="$t/work" \
    bash "$SCRIPTS/$entry" --cwd "$t/target" --prompt x --agent codex 2>/dev/null)
  [[ "$(jq -r '.error // empty' <<<"$out")" == *HOTLINE_CODEX_HOME* ]]
  check "direct $entry refuses unsupported account selection" $? "out=$out"
done

# A waiter outside the caller environment must rediscover in the persisted home.
# Its ambient home contains a decoy with the SAME nonce; metadata must win.
t=$(new_env); mkdir -p "$t/work/sessions" "$t/personal/sessions" "$t/call"
nonce=abc123; thread=11111111-2222-3333-4444-555555555555
for account in work personal; do
  file="$t/$account/sessions/rollout-x-$thread.jsonl"
  jq -nc --arg t "CALL_ID: $nonce" '{type:"response_item",payload:{type:"message",role:"user",content:[{text:$t}]}}' > "$file"
done
printf '%s\n' "$t/work" > "$t/call/codex_home.txt"
hit=$(env CODEX_HOME="$t/personal" HOTLINE_CODEX_HOME="$t/personal" bash -c 'CALL_DIR="$1"; source "$2"; codex_find_rollout "$3"' _ "$t/call" "$HOTLINE_DIR/scripts/codex-rollout.sh" "$nonce")
[[ "$hit" == "$t/work/"* ]]
check 'call metadata beats ambient personal home during rediscovery' $? "hit=$hit"
herdr_suite_finish
