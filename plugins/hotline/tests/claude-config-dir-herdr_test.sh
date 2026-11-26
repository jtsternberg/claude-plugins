#!/usr/bin/env bash
# A claude callee runs on its caller's Claude account: HOTLINE_CLAUDE_CONFIG_DIR,
# defaulting to the dialer's CLAUDE_CONFIG_DIR, crosses the herdr boundary as pane
# --env on every placement, is pinned for follow-ups, and is never set when neither
# is. Dropping the --env, the pin or the refusal fails this suite.
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/herdr-transport-harness.sh"

echo "HOTLINE_CLAUDE_CONFIG_DIR over herdr:"

# The callee's transcript lands under the account it runs on; the stub has no pane
# env, so the test names that account for it.
wrap_transcript_in() {  # <scratch> <config-dir> <fallback-session-id>
  local t="$1" dir="$2" fallback="$3"
  mkdir -p "$t/binsrc"; make_herdr_stub "$t/binsrc"; mv "$t/binsrc/herdr" "$t/bin/herdr-real"
  cat > "$t/bin/herdr" <<STUBW
#!/usr/bin/env bash
if [[ "\$1 \${2:-}" == "agent prompt" ]]; then
  SID=\$(cat "\$HERDR_STATE/session_id" 2>/dev/null || echo "$fallback")
  export HERDR_STUB_TRANSCRIPT="$dir/projects/$(encode_cwd "$(cd "$t/target" && pwd -P)")/\$SID.jsonl"
fi
exec bash "$t/bin/herdr-real" "\$@"
STUBW
  chmod +x "$t/bin/herdr"
}
launch() {  # <scratch> <env...>
  local t="$1"; shift
  env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" HERDR_STATE="$t/state" \
    HOTLINE_HERDR_PANE=w1:p1 "$@" bash "$HERDR_ASYNC" --cwd "$t/target" --prompt x
}
env_flag() { printf -- '--env %q' "CLAUDE_CONFIG_DIR=$1"; }

# --- launcher: every placement, verbatim ------------------------------------
for placement in split tab workspace; do
  t=$(new_env); mkdir -p "$t/acct" && ln -s "$t/acct" "$t/alt-link"
  # A symlinked spelling, on purpose: claude keys its login on the raw string.
  out=$(launch "$t" HOTLINE_CLAUDE_CONFIG_DIR="$t/alt-link" HOTLINE_HERDR_PLACEMENT="$placement" HOTLINE_HERDR_WORKSPACE=workers)
  cd_call=$(jq -r '.call_dir // empty' <<<"$out")
  verb=$([[ $placement == split ]] && echo "pane split" || echo "$placement create")
  grep "$verb" "$t/herdr.log" | grep -Fq -- "$(env_flag "$t/alt-link")"
  check "$placement: pane gets --env CLAUDE_CONFIG_DIR, spelled exactly as given" $? "out=$out log=$(cat "$t/herdr.log")"
  [[ -n "$cd_call" && "$(cat "$cd_call/claude_config_dir.txt" 2>/dev/null)" == "$t/alt-link" ]]
  check "$placement: claude_config_dir.txt records it for the waiters" $?
done

t=$(new_env)
out=$(launch "$t")
! grep -q 'CLAUDE_CONFIG_DIR' "$t/herdr.log" && [[ ! -e "$(jq -r .call_dir <<<"$out")/claude_config_dir.txt" ]]
check 'unset: no --env and no record (launch unchanged)' $? "log=$(cat "$t/herdr.log")"

for bad in relative "$t/missing"; do
  : > "$t/herdr.log"
  out=$(launch "$t" HOTLINE_CLAUDE_CONFIG_DIR="$bad")
  [[ "$(jq -r '.error // empty' <<<"$out")" == *HOTLINE_CLAUDE_CONFIG_DIR* ]] && ! grep -q 'agent start' "$t/herdr.log"
  check "invalid dir refused before launch: '$bad'" $? "out=$out"
done
mkdir -p "$t/acct"; : > "$t/herdr.log"
out=$(launch "$t" HOTLINE_CLAUDE_CONFIG_DIR="$t/acct" HOTLINE_HERDR_REMOTE=box)
[[ "$(jq -r '.error // empty' <<<"$out")" == *HOTLINE_CLAUDE_CONFIG_DIR* ]] && ! grep -q 'agent start' "$t/herdr.log"
check 'remote launcher refuses an explicit dir' $? "out=$out"

# --- dial: the default is the caller's own account ---------------------------
t=$(new_env); mkdir -p "$t/alt"
wrap_transcript_in "$t" "$t/alt" unused
out=$(dial "$t" HERDR_PANE_ID=w1:p1 CLAUDE_CONFIG_DIR="$t/alt" -- \
  --target "$t/target" --mode work_order --prompt hi --transport herdr --boot-timeout 5)
first=$(jq -r '.call_dir // empty' <<<"$out")
[[ "$(jq -r .status <<<"$out")" == connected ]] && grep 'pane split' "$t/herdr.log" | grep -Fq -- "$(env_flag "$t/alt")"
check "dial: a caller's CLAUDE_CONFIG_DIR becomes the callee's" $? "out=$out err=$(cat "$t/err.txt")"
cache_get() { env HOME="$t/home" bash "$SCRIPTS/session-cache.sh" get "$t/target" --caller-session caller-dial-1; }
if [[ -d "$first" ]]; then
  env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 \
    bash "$WAIT_SESSION" "$first" --timeout 3 >/dev/null 2>&1
fi
[[ "$(cache_get | jq -r '.claude_config_dir // empty')" == "$t/alt" ]]
check 'dial: the cache pins the launch account' $? "cache=$(cache_get)"

t2=$(new_env)
wrap_transcript_in "$t2" "$t2/home/.claude" unused
out=$(t="$t2"; dial "$t2" HERDR_PANE_ID=w1:p1 -- --target "$t2/target" --mode work_order --prompt hi --transport herdr --boot-timeout 5)
[[ "$(jq -r .status <<<"$out")" == connected ]] && ! grep -q 'CLAUDE_CONFIG_DIR' "$t2/herdr.log" \
  && [[ ! -e "$(jq -r .call_dir <<<"$out")/claude_config_dir.txt" ]]
check 'dial: a caller with no CLAUDE_CONFIG_DIR sets none (default unchanged)' $? "out=$out"

t3=$(new_env)
printf '#!/usr/bin/env bash\nexit 0\n' > "$t3/bin/claude"; chmod +x "$t3/bin/claude"  # the far side's, for preflight
out=$(dial "$t3" CLAUDE_CONFIG_DIR="$t/alt" SSH_STUB_HOME="$t3/remote-home" -- \
  --target "$t3/target" --mode quick --prompt hi --remote tester@no-such-box.invalid)
# Delivery confirmation over the hop is not this suite's subject; the launch is.
grep -q 'agent start' "$t3/herdr.log" && [[ "$out" != *CLAUDE_CONFIG_DIR* ]] \
  && ! grep -q 'CLAUDE_CONFIG_DIR' "$t3/ssh.log" "$t3/herdr.log"
check 'dial --remote: the caller default is a local path, neither sent nor refused' $? "out=$out herdr=$(cat "$t3/herdr.log")"
out=$(dial "$t2" HOTLINE_CLAUDE_CONFIG_DIR="$t/alt" -- --target "$t2/target" --mode quick --prompt hi --remote tester@no-such-box.invalid)
[[ "$(jq -r .stage <<<"$out")" == args && "$(jq -r .detail <<<"$out")" == *HOTLINE_CLAUDE_CONFIG_DIR* ]]
check 'dial --remote: an explicit dir is an args error' $? "out=$out"
out=$(dial "$t2" HOTLINE_CLAUDE_CONFIG_DIR="$t2/nope" -- --target "$t2/target" --mode quick --prompt hi --transport herdr)
[[ "$(jq -r .stage <<<"$out")" == args && "$(jq -r .detail <<<"$out")" == *HOTLINE_CLAUDE_CONFIG_DIR* ]]
check 'dial: a missing explicit dir is an args error' $? "out=$out"

# --- follow-ups keep the account the callee launched with ---------------------
mkdir -p "$t/other"
follow() { dial "$t" HERDR_PANE_ID=w1:p1 HERDR_STUB_AGENT_ANY=1 "$@" -- \
  --target "$t/target" --mode work_order --prompt next --transport herdr --boot-timeout 5; }
prompts=$(grep -c 'agent prompt' "$t/herdr.log"); starts=$(grep -c 'agent start' "$t/herdr.log")
out=$(follow HOTLINE_CLAUDE_CONFIG_DIR="$t/other")
[[ "$(jq -r .status <<<"$out")" == error && "$(jq -r .detail <<<"$out")" == *"$t/alt"* ]] \
  && [[ $(grep -c 'agent prompt' "$t/herdr.log") == "$prompts" && $(grep -c 'agent start' "$t/herdr.log") == "$starts" ]]
check 'follow-up: an explicit different dir is refused before delivery or launch' $? "out=$out"

out=$(follow CLAUDE_CONFIG_DIR="$t/other")
second=$(jq -r '.call_dir // empty' <<<"$out")
[[ "$(jq -r .first_contact <<<"$out")" == false && "$(cat "$second/claude_config_dir.txt" 2>/dev/null)" == "$t/alt" ]] \
  && jq -e '.fallbacks | any(test("claude-config-dir→cached"))' <<<"$out" >/dev/null
check 'follow-up: a different caller default yields to the pin, and says so' $? "out=$out"

out=$(follow HERDR_STUB_GONE_NAMES="$(cat "$first/herdr_agent.txt" 2>/dev/null)" CLAUDE_CONFIG_DIR="$t/other")
[[ "$(jq -r .status <<<"$out")" == connected ]] && tail -n 20 "$t/herdr.log" | grep 'pane split' | grep -Fq -- "$(env_flag "$t/alt")"
check 'follow-up into a dead agent relaunches under the pinned account' $? "out=$out"

# --- waiters read the record, not their own env --------------------------------
mkdir -p "$t/w/call" "$t/w/caller-acct" "$t/w/callee-acct"
printf '%s\n' "$t/w/callee-acct" > "$t/w/call/claude_config_dir.txt"
got=$(env CLAUDE_CONFIG_DIR="$t/w/caller-acct" bash -c \
  'source "$1/claude-config-dir.sh"; claude_config_dir_adopt "$2"; bash "$1/transcript-path.sh" --cwd /x --session s1' \
  _ "$HOTLINE_DIR/scripts" "$t/w/call")
[[ "$got" == "$t/w/callee-acct/projects/-x/s1.jsonl" ]]
check 'waiter: the recorded dir decides the transcript path over the ambient account' $? "got=$got"

herdr_suite_finish
