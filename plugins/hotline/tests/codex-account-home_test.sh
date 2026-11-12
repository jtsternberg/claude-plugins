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
  grep "$placement create" "$t/herdr.log" | grep -Fq -- "--env $quoted_home"
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
for extra in 'split' 'remote'; do
  : > "$t/herdr.log"
  case "$extra" in
    split) out=$(launch HOTLINE_CODEX_HOME="$t/work") ;;
    remote) out=$(launch HOTLINE_CODEX_HOME="$t/work" HOTLINE_HERDR_PLACEMENT=tab HOTLINE_HERDR_REMOTE=remote) ;;
  esac
  [[ "$(jq -r '.error // empty' <<<"$out")" == *HOTLINE_CODEX_HOME* ]] && ! grep -q 'agent start' "$t/herdr.log"
  check "$extra refused before launch" $? "out=$out"
done
for flags in '--agent claude --fresh' '--agent codex' '--agent codex --fresh --headless'; do
  out=$(dial "$t" HOTLINE_CODEX_HOME="$t/work" HOTLINE_HERDR_PLACEMENT=tab -- --target "$t/target" --mode quick --prompt x $flags)
  expected_stage=args
  [[ "$flags" != '--agent codex' ]] || expected_stage=transport
  [[ "$(jq -r .stage <<<"$out")" == "$expected_stage" && "$(jq -r .detail <<<"$out")" == *HOTLINE_CODEX_HOME* ]]
  check "dial rejects unsupported selection: $flags" $? "out=$out"
done

for entry in headless-call-async.sh herdr-reuse-agent.sh; do
  out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HOTLINE_CODEX_HOME="$t/work" \
    bash "$SCRIPTS/$entry" --cwd "$t/target" --prompt x --agent codex 2>/dev/null)
  [[ "$(jq -r '.error // empty' <<<"$out")" == *HOTLINE_CODEX_HOME* ]]
  check "direct $entry refuses unsupported account selection" $? "out=$out"
done

# Resume guards operate on the exact rollout and fail before transport creation.
t=$(new_env)
thread=11111111-2222-3333-4444-555555555555
printf '#!/bin/sh\nexit 0\n' > "$t/bin/codex"; chmod +x "$t/bin/codex"
mkdir -p "$t/home/.codex-work/sessions" "$t/home/.codex-other/sessions"
rollout="$t/home/.codex-work/sessions/rollout-x-$thread.jsonl"
jq -nc --arg id "$thread" --arg cwd "$t/target" '{type:"session_meta",payload:{id:$id,cwd:$cwd}}' > "$rollout"
cat > "$t/bin/lsof" <<'STUB'
#!/usr/bin/env bash
case "${RESUME_OWNER:-none}" in
  none) exit 1 ;;
  codex) printf 'p12345\nccodex\n' ;;
  other) printf 'p12345\nctail\n' ;;
  broken) exit 127 ;;
esac
STUB
chmod +x "$t/bin/lsof"
source "$HOTLINE_DIR/scripts/codex-home.sh"
source "$HOTLINE_DIR/scripts/codex-rollout.sh"
HOME_SAVE="$HOME"; HOME="$t/home"
codex_home_autodetect "$thread"
[[ "$HOTLINE_CODEX_HOME" == "$(cd "$t/home/.codex-work" && pwd -P)" && "$HOTLINE_HERDR_PLACEMENT" == tab ]]
check 'single non-default home selected with safe herdr placement' $?
unset HOTLINE_CODEX_HOME HOTLINE_HERDR_PLACEMENT
cp "$rollout" "$t/home/.codex-other/sessions/rollout-x-$thread.jsonl"
! codex_home_autodetect "$thread" && [[ "$CODEX_HOME_ERR" == *ambiguous* && "$CODEX_HOME_ERR" == *'.codex-work'* && "$CODEX_HOME_ERR" == *'.codex-other'* ]]
check 'ambiguous homes refused with both candidates' $?
rm "$t/home/.codex-other/sessions/rollout-x-$thread.jsonl"
HOME="$HOME_SAVE"
for owner in none other codex broken; do
  ( export PATH="$t/bin:$PATH" RESUME_OWNER="$owner"
    codex_home_resume_validate "$rollout" "$thread"
  ); rc=$?
  case "$owner" in none|other) [[ $rc == 0 ]] ;; *) [[ $rc != 0 ]] ;; esac
  check "resume ownership guard: $owner" $?
done
for transport in herdr cmux; do
  out=$(dial "$t" RESUME_OWNER=codex -- --agent codex --transport "$transport" --target "$thread" --mode quick --prompt x)
  [[ "$(jq -r .stage <<<"$out")" == transport && "$(jq -r .detail <<<"$out")" == *12345* && "$(jq -r .detail <<<"$out")" == *'nothing was delivered'* ]]
  check "$transport refuses live duplicate before launch" $? "out=$out"
done
# Herdr launch must receive both the selected account and explicit resume argv.
: > "$t/herdr.log"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" HERDR_STATE="$t/state" \
  HOTLINE_HERDR_PANE=w1:p1 HOTLINE_CODEX_HOME="$t/home/.codex-work" HOTLINE_HERDR_PLACEMENT=tab \
  bash "$HERDR_ASYNC" --cwd "$t/target" --prompt x --agent codex --resume "$thread")
grep 'agent start' "$t/herdr.log" | grep -Fq "resume $thread"
check 'selected-home herdr launch carries resume id' $? "out=$out"
printf -v expected_env '%q' "CODEX_HOME=$(cd "$t/home/.codex-work" && pwd -P)"
grep 'tab create' "$t/herdr.log" | grep -Fq -- "--env $expected_env"
check 'selected-home resume passes account before startup' $?
unset HOTLINE_CODEX_HOME HOTLINE_HERDR_PLACEMENT

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
