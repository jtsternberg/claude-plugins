#!/usr/bin/env bash
# =============================================================================
# notify-caller.sh — the callee-side check that decides whether to push a
# resolved call's notice into the caller's live Claude Code session, and to whom.
#
# The send itself is the callee model's SendMessage call; this script is the seam
# in front of it, so every decision is pinned here with `claude` stubbed on PATH:
# once per nonce, a caller that is not live (or not uniquely named) gets nothing,
# a caller whose waiter is still running gets nothing (the waiter delivers), and
# no failure is ever louder than {"send":false,...}.
# =============================================================================
set -u
TMP_ROOT="${TMPDIR:-/tmp}"; TMP_ROOT=${TMP_ROOT%/}
HOTLINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTIFY="$HOTLINE_DIR/skills/ringing/scripts/notify-caller.sh"
WAIT="$HOTLINE_DIR/skills/dial/scripts/wait-for-response.sh"
PASS=0; FAIL=0; FAILED_CASES=()
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "    $2"; return 0; }
check() { if [[ "$2" -eq 0 ]]; then pass "$1"; else fail "$1" "${3:-}"; fi; }

ROOT=$(mktemp -d "$TMP_ROOT"/hotline-notify-test-XXXXXX)
BG_PIDS=()
trap 'for p in ${BG_PIDS[@]+"${BG_PIDS[@]}"}; do kill "$p" 2>/dev/null; done; rm -rf "$ROOT"' EXIT

CALLER="caller-aaaa-1111"
NONCE="feedc0ffee000001"

new_env() {  # → scratch root with bin/ (a `claude` stub reading agents.json) and home/
  local t; t=$(mktemp -d "$ROOT/env-XXXXXX")
  mkdir -p "$t/bin" "$t/home"
  cat > "$t/bin/claude" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$t/claude.log"
[[ "\$1 \${2:-}" == "agents --json" ]] || exit 64
cat "$t/agents.json" 2>/dev/null || exit 1
EOF
  chmod +x "$t/bin/claude"
  echo "$t"
}
agents() {  # <scratch> <json array>
  printf '%s\n' "$2" > "$1/agents.json"
}
notify() {  # <scratch> [extra args] → stdout JSON; rc in $NRC
  local t="$1"; shift
  NOUT=$(PATH="$t/bin:$PATH" HOME="$t/home" bash "$NOTIFY" --caller-session "$CALLER" "$@" 2>"$t/err.txt")
  NRC=$?
}
field() { jq -r "if $1 == null then \"\" else $1 end" <<<"$NOUT" 2>/dev/null; }
LIVE='[{"pid":1,"kind":"interactive","sessionId":"'"$CALLER"'","name":"wp pipeline speed audit","status":"busy"},
       {"pid":2,"kind":"interactive","sessionId":"other","name":"something else","status":"idle"}]'

echo "notify-caller.sh:"

# 1. Live caller, nothing else known → send, addressed by its ListAgents name.
t=$(new_env); agents "$t" "$LIVE"
notify "$t" --call-id "$NONCE" --status WORK_COMPLETE
[[ $NRC -eq 0 && "$(field .send)" == "true" && "$(field .to)" == "wp pipeline speed audit" ]]
check "a live caller gets a notice addressed by its session name" $? "rc=$NRC out=$NOUT err=$(cat "$t/err.txt")"
msg=$(field .message)
[[ "$msg" == *"call_id=$NONCE"* && "$msg" == *"WORK_COMPLETE"* ]]
check "the notice names the nonce and the status" $? "message=$msg"

# 2. Same nonce again → once per nonce.
notify "$t" --call-id "$NONCE" --status WORK_COMPLETE
[[ $NRC -eq 0 && "$(field .send)" == "false" && "$(field .reason)" == "already-notified" ]]
check "a second notice for the same nonce is refused" $? "out=$NOUT"
# …and a different nonce in the same session is its own notice.
notify "$t" --call-id "feedc0ffee000002" --status AWAITING_REVIEW
[[ "$(field .send)" == "true" ]]
check "a new nonce is notified independently" $? "out=$NOUT"

# 3. Caller not among the live sessions (exited, or a Codex/remote caller).
t=$(new_env); agents "$t" '[{"pid":2,"kind":"interactive","sessionId":"other","name":"x","status":"idle"}]'
notify "$t" --call-id "$NONCE" --status DONE
[[ $NRC -eq 0 && "$(field .send)" == "false" && "$(field .reason)" == "caller-not-live" ]]
check "a caller that is not live gets nothing, quietly" $? "rc=$NRC out=$NOUT"

# 4. `claude agents --json` fails, or is not JSON → nothing, exit 0.
t=$(new_env)   # no agents.json → stub exits 1
notify "$t" --call-id "$NONCE" --status DONE
[[ $NRC -eq 0 && "$(field .send)" == "false" ]]
check "an unreadable session list sends nothing and does not fail" $? "rc=$NRC out=$NOUT"
t=$(new_env); agents "$t" 'not json'
notify "$t" --call-id "$NONCE" --status DONE
[[ $NRC -eq 0 && "$(field .send)" == "false" ]]
check "a malformed session list sends nothing" $? "rc=$NRC out=$NOUT"

# 5. Two live sessions share the caller's name → a send by name is ambiguous.
t=$(new_env); agents "$t" '[{"pid":1,"kind":"interactive","sessionId":"'"$CALLER"'","name":"dup","status":"busy"},
                           {"pid":3,"kind":"interactive","sessionId":"zzz","name":"dup","status":"idle"}]'
notify "$t" --call-id "$NONCE" --status DONE
[[ "$(field .send)" == "false" && "$(field .reason)" == "caller-name-ambiguous" ]]
check "an ambiguous caller name sends nothing rather than guess" $? "out=$NOUT"

# 6. The caller's call dir is known (its session cache) and no waiter is running
#    → the notice carries the call dir.
t=$(new_env); agents "$t" "$LIVE"
cd6="$t/call6"; mkdir -p "$cd6"; echo "$NONCE" > "$cd6/call_id.txt"
mkdir -p "$t/home/.agents-hotline/sessions"
jq -n --arg d "$cd6" --arg n "$NONCE" \
  '{connections:{"/some/target":{session_id:"s",last_call_id:$n,last_call_dir:$d}}}' \
  > "$t/home/.agents-hotline/sessions/$CALLER.json"
notify "$t" --call-id "$NONCE" --status BLOCKED
[[ "$(field .send)" == "true" && "$(field .call_dir)" == "$cd6" && "$(field .message)" == *"$cd6"* ]]
check "a known call dir is named in the notice" $? "out=$NOUT"

# 7. …but a LIVE waiter on that call dir delivers the answer itself → no notice.
t=$(new_env); agents "$t" "$LIVE"
cd7="$t/call7"; mkdir -p "$cd7"
mkdir -p "$t/home/.agents-hotline/sessions"
jq -n --arg d "$cd7" --arg n "$NONCE" \
  '{connections:{"/some/target":{session_id:"s",last_call_id:$n,last_call_dir:$d}}}' \
  > "$t/home/.agents-hotline/sessions/$CALLER.json"
mkdir -p "$t/fake"; printf '#!/usr/bin/env bash\nsleep 30\n' > "$t/fake/wait-for-response.sh"
bash "$t/fake/wait-for-response.sh" & wp=$!; BG_PIDS+=("$wp")
echo "$wp" > "$cd7/waiter.pid"
notify "$t" --call-id "$NONCE" --status WORK_COMPLETE
[[ "$(field .send)" == "false" && "$(field .reason)" == "waiter-live" ]]
check "a caller with a live waiter on the call gets no duplicate notice" $? "out=$NOUT"
kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null
# A stale pid (waiter gone) no longer counts — and the nonce was not burned above.
notify "$t" --call-id "$NONCE" --status WORK_COMPLETE
[[ "$(field .send)" == "true" ]]
check "once the waiter is gone, the notice goes out" $? "out=$NOUT"

# 8. Usage: an unknown status or a missing nonce is refused, not guessed at.
t=$(new_env); agents "$t" "$LIVE"
notify "$t" --call-id "$NONCE" --status WORK_IN_PROGRESS
[[ $NRC -eq 2 ]]
check "WORK_IN_PROGRESS is not a resolution (usage error)" $? "rc=$NRC out=$NOUT"
notify "$t" --status DONE
[[ $NRC -eq 2 ]]
check "a missing --call-id is a usage error" $? "rc=$NRC"

# 9. The waiter records its pid in the call dir, which is what case 7 reads.
t=$(new_env)
cd9="$t/call9"; mkdir -p "$cd9"
printf '{"session_id":"s","response":"ok"}' > "$cd9/response.json"; touch "$cd9/done"
echo headless > "$cd9/transport.txt"
HOTLINE_POLL_SLEEP=0 bash "$WAIT" "$cd9" --timeout 4 >/dev/null 2>"$t/werr.txt"; wrc=$?
[[ $wrc -eq 0 && -s "$cd9/waiter.pid" ]]
check "wait-for-response.sh writes waiter.pid into the call dir" $? "rc=$wrc err=$(cat "$t/werr.txt")"

echo ""
echo "Result: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  echo ""; echo "Failed cases:"; for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
