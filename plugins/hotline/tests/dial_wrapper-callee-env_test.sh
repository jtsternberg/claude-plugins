#!/usr/bin/env bash
# =============================================================================
# dial.sh wrapper regression tests — HOTLINE_CALLEE_ENV: the args-stage refusal of
# a malformed value, delivery as `claude --settings '{"env":{...}}'` on the cmux,
# conference and headless launches, the payload's `.callee_env`, the live-reuse
# follow-up that cannot re-deliver, and the unset knob leaving argv and payload
# untouched. The herdr launcher's half lives in herdr-transport-launch_test.sh.
#
# One shard of the dial_wrapper suite. The stubs, sockets and scratch-env
# helpers live in lib/dial-wrapper-harness.sh.
# =============================================================================
set -u
FAKE_CLAUDE_PID=990005
# shellcheck source=lib/dial-wrapper-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/dial-wrapper-harness.sh"
unset HOTLINE_CALLEE_ENV

echo "dial.sh HOTLINE_CALLEE_ENV:"

# One argv element per line, so a test can read the value that follows --settings
# exactly as claude would receive it, quoting and all.
argv_claude() {   # argv_claude <bin-dir> <log>
  mkdir -p "$1"
  cat > "$1/claude" <<EOF
#!/usr/bin/env bash
{ printf '%s\n' "\$@"; printf -- '--END--\n'; } >> "$2"
SID="\${FAKE_CLAUDE_SESSION_ID:-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee}"
printf '{"type":"system","session_id":"%s"}\n' "\$SID"
printf '{"type":"result","session_id":"%s","result":"ok","num_turns":1}\n' "\$SID"
EOF
  chmod +x "$1/claude"
}
settings_of() { grep -A1 -x -- '--settings' "$1" 2>/dev/null | sed -n 2p; }

# ===========================================================================
# The validator and builder, directly.
# ===========================================================================
# shellcheck source=../scripts/callee-env.sh
source "$HOTLINE_DIR/scripts/callee-env.sh"

json=$(HOTLINE_CALLEE_ENV="AGENTIC_DEV_ROLE=builder  AGENTIC_DEV_RUN=42" callee_env_settings_json)
[[ "$json" == '{"env":{"AGENTIC_DEV_ROLE":"builder","AGENTIC_DEV_RUN":"42"}}' ]]
check "two pairs, doubled space between them → one env block with both" $? "json=$json"

# `*` must not glob against the cwd, and only the FIRST `=` splits key from value.
json=$(cd "$TMP_ROOT" && HOTLINE_CALLEE_ENV="A=* B=x=y" callee_env_settings_json)
[[ "$json" == '{"env":{"A":"*","B":"x=y"}}' ]]
check "a '*' value stays literal and a value may itself contain '='" $? "json=$json"

for blank in "" "   "; do
  HOTLINE_CALLEE_ENV="$blank" callee_env_validate \
    && [[ -z "$(HOTLINE_CALLEE_ENV="$blank" callee_env_settings_json)" ]]
  check "blank value '$blank' is valid and builds nothing (same as unset)" $? ""
done

for bad in "NOEQUALS" "1BAD=x" "BAD-KEY=x" "=x" "EMPTY=" "K=a K=b"; do
  HOTLINE_CALLEE_ENV="$bad" callee_env_validate
  rc=$?
  [[ $rc -ne 0 && -n "$CALLEE_ENV_ERR" ]]
  check "'$bad' is refused, with a reason" $? "rc=$rc err=$CALLEE_ENV_ERR"
done

# ---------------------------------------------------------------------------
# HOTLINE_CALLEE_ENV_FORWARD: copied by name from the dialer's own environment, so
# a value may be empty or hold spaces — the grammar above cannot carry either.
# ---------------------------------------------------------------------------
unset HOTLINE_CALLEE_ENV_FORWARD HOTLINE_CALLEE_GIT_CONFIG
json=$(FWD_A="has spaces" FWD_B="" HOTLINE_CALLEE_ENV_FORWARD="FWD_A FWD_B FWD_ABSENT" \
  callee_env_settings_json)
[[ "$json" == '{"env":{"FWD_A":"has spaces","FWD_B":""}}' ]]
check "forward: set names are copied verbatim (spaces, empty), unset names skipped" $? "json=$json"

json=$(FWD_A=fwd HOTLINE_CALLEE_ENV_FORWARD="FWD_A" HOTLINE_CALLEE_ENV="FWD_A=explicit" \
  callee_env_settings_json)
[[ "$json" == '{"env":{"FWD_A":"explicit"}}' ]]
check "forward: an explicit HOTLINE_CALLEE_ENV pair wins over a forwarded value" $? "json=$json"

[[ -z "$(HOTLINE_CALLEE_ENV_FORWARD="NOT_SET_ANYWHERE" callee_env_settings_json)" ]]
check "forward: only absent names → no env block at all" $? ""

HOTLINE_CALLEE_ENV_FORWARD="OK BAD-NAME" callee_env_validate
rc=$?
[[ $rc -ne 0 && "$CALLEE_ENV_ERR" == *"HOTLINE_CALLEE_ENV_FORWARD"*"BAD-NAME"* ]]
check "forward: a non-variable name is refused, naming the knob and the name" $? \
  "rc=$rc err=$CALLEE_ENV_ERR"

# ---------------------------------------------------------------------------
# HOTLINE_CALLEE_GIT_CONFIG: the dialer's GIT_CONFIG_* entries whose key matches a
# glob, renumbered from 0 — and ident config mirrored into GIT_AUTHOR_*/COMMITTER_*.
# The fixture is a GitHub App agent's own entries with a second tool's block after.
# ---------------------------------------------------------------------------
git_fixture() {
  env GIT_CONFIG_COUNT=6 \
    GIT_CONFIG_KEY_0=credential.https://github.com.helper GIT_CONFIG_VALUE_0= \
    GIT_CONFIG_KEY_1=credential.https://github.com.helper \
    GIT_CONFIG_VALUE_1='!/home/u/bin/gh-app-token git-credential' \
    GIT_CONFIG_KEY_2=author.name GIT_CONFIG_VALUE_2='app[bot]' \
    GIT_CONFIG_KEY_3=committer.email GIT_CONFIG_VALUE_3='1+app[bot]@users.noreply.github.com' \
    GIT_CONFIG_KEY_4=user.name GIT_CONFIG_VALUE_4='Other Tool' \
    GIT_CONFIG_KEY_5=nostr.keyfile GIT_CONFIG_VALUE_5=/tmp/x/.key \
    "$@"
}
json=$(git_fixture HOTLINE_CALLEE_GIT_CONFIG="credential.https://github.com.helper author.* committer.*" \
  bash -c "source '$HOTLINE_DIR/scripts/callee-env.sh'; callee_env_settings_json")
jq -e '.env == {
    GIT_CONFIG_COUNT:"4",
    GIT_CONFIG_KEY_0:"credential.https://github.com.helper", GIT_CONFIG_VALUE_0:"",
    GIT_CONFIG_KEY_1:"credential.https://github.com.helper",
    GIT_CONFIG_VALUE_1:"!/home/u/bin/gh-app-token git-credential",
    GIT_CONFIG_KEY_2:"author.name", GIT_CONFIG_VALUE_2:"app[bot]",
    GIT_CONFIG_KEY_3:"committer.email", GIT_CONFIG_VALUE_3:"1+app[bot]@users.noreply.github.com",
    GIT_AUTHOR_NAME:"app[bot]", GIT_COMMITTER_EMAIL:"1+app[bot]@users.noreply.github.com"
  }' <<<"$json" >/dev/null 2>&1
check "git config: matching entries kept in order and renumbered, the rest dropped, ident mirrored" $? \
  "json=$json"

json=$(git_fixture HOTLINE_CALLEE_GIT_CONFIG="core.*" \
  bash -c "source '$HOTLINE_DIR/scripts/callee-env.sh'; callee_env_settings_json")
[[ -z "$json" ]]
check "git config: no entry matches → nothing (never a GIT_CONFIG_COUNT=0 that wipes the host's)" $? \
  "json=$json"

[[ -z "$(HOTLINE_CALLEE_GIT_CONFIG="author.*" callee_env_settings_json)" ]]
check "git config: a dialer with no GIT_CONFIG_COUNT forwards nothing" $? ""

GIT_CONFIG_COUNT=two HOTLINE_CALLEE_GIT_CONFIG="author.*" callee_env_validate
rc=$?
[[ $rc -ne 0 && "$CALLEE_ENV_ERR" == *"GIT_CONFIG_COUNT"* ]]
check "git config: a non-numeric GIT_CONFIG_COUNT is refused" $? "rc=$rc err=$CALLEE_ENV_ERR"

GIT_CONFIG_COUNT=1 HOTLINE_CALLEE_GIT_CONFIG="author.*" callee_env_validate
rc=$?
[[ $rc -ne 0 && "$CALLEE_ENV_ERR" == *"GIT_CONFIG_KEY_0"* ]]
check "git config: a COUNT naming a missing GIT_CONFIG_KEY_n is refused" $? "rc=$rc err=$CALLEE_ENV_ERR"

# ===========================================================================
# Args stage: refused before anything is resolved or launched.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; argv_claude "$t/bin" "$t/argv.log"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-ce-0" HOTLINE_PENDING_DIR="$t/pending" \
  HOTLINE_CALLEE_ENV="ROLE=builder has spaces" \
  bash "$DIAL" --target "$t/target" --mode work_order --label "probe label" \
    --prompt "hi" --boot-timeout 5 2>"$t/err.txt"); rc=$?
[[ $rc -ne 0 && "$(jq -r .stage <<<"$out")" == "args" \
   && "$(jq -r .detail <<<"$out")" == *"HOTLINE_CALLEE_ENV"*"'has' is not KEY=VALUE"* ]]
check "a value with spaces is an args-stage error naming the bad token" $? "rc=$rc out=$out"
[[ ! -s "$t/argv.log" && ! -s "$t/cmux_calls" ]]
check "…and nothing was launched (no claude, no cmux call)" $? \
  "argv=$(cat "$t/argv.log" 2>/dev/null) cmux=$(cat "$t/cmux_calls" 2>/dev/null)"

# ===========================================================================
# Headless: --settings on the `claude -p` argv, every launch.
# ===========================================================================
t=$(new_env); note_leak "$t"
argv_claude "$t/bin" "$t/argv.log"; make_ps "$t/bin"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" \
  HOTLINE_CALLER_SESSION_ID="caller-ce-1" HOTLINE_PENDING_DIR="$t/pending" \
  HOTLINE_CALLEE_ENV="AGENTIC_DEV_ROLE=builder AGENTIC_DEV_RUN=42" \
  bash "$DIAL" --target "$t/target" --mode quick --label "probe label" --headless \
    --prompt "hi" --boot-timeout 8 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
[[ "$(jq -r .status <<<"$out")" == "connected" && "$(jq -r .callee_env <<<"$out")" == "settings" ]]
check "headless: payload reports callee_env=settings" $? "out=$out stderr=$(cat "$t/err.txt")"
jq -e '.env == {AGENTIC_DEV_ROLE:"builder", AGENTIC_DEV_RUN:"42"}' <<<"$(settings_of "$t/argv.log")" >/dev/null 2>&1
check "headless: claude -p received --settings with exactly that env block" $? \
  "argv=$(cat "$t/argv.log" 2>/dev/null)"

# ===========================================================================
# cmux first contact: --settings baked into the launch script, and it survives
# the script's own quoting — run the script and read what claude received.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"
printf 'some earlier output\n\xe2\x9d\xaf\xc2\xa0\nClaude Code v2.1.221\n' > "$t/screen.txt"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-ce-2" HOTLINE_PENDING_DIR="$t/pending" \
  HOTLINE_CALLEE_ENV="AGENTIC_DEV_ROLE=reviewer" \
  bash "$DIAL" --target "$t/target" --mode work_order --placement detached \
    --label "probe label" --prompt "first contact" --boot-timeout 8 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
[[ "$(jq -r .status <<<"$out")" == "connected" && "$(jq -r .callee_env <<<"$out")" == "settings" ]]
check "cmux: payload reports callee_env=settings" $? "out=$out stderr=$(cat "$t/err.txt")"
launch_script_of "$call_dir" > "$t/launch.sh"
argv_claude "$t/runbin" "$t/argv.log"
PATH="$t/runbin:$PATH" bash "$t/launch.sh" >/dev/null 2>&1
jq -e '.env == {AGENTIC_DEV_ROLE:"reviewer"}' <<<"$(settings_of "$t/argv.log")" >/dev/null 2>&1
check "cmux: the launch script hands claude --settings with that env block" $? \
  "launch=$(cat "$t/launch.sh") argv=$(cat "$t/argv.log" 2>/dev/null)"

# The follow-up into that live surface types into a running REPL: nothing to deliver.
touch "$call_dir/done"
out2=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-ce-2" HOTLINE_PENDING_DIR="$t/pending" \
  HOTLINE_CALLEE_ENV="AGENTIC_DEV_ROLE=reviewer" \
  bash "$DIAL" --target "$t/target" --mode work_order --placement detached \
    --label "probe label" --prompt "and now step 2" --boot-timeout 8 2>"$t/err2.txt")
call_dir2=$(jq -r '.call_dir // empty' <<<"$out2" 2>/dev/null)
[[ -n "$call_dir2" ]] && note_leak "$call_dir2"
[[ "$(jq -r .first_contact <<<"$out2")" == "false" \
   && "$(jq -r '.fallbacks | length' <<<"$out2")" == "0" \
   && "$(jq -r .callee_env <<<"$out2")" == "not-redelivered" \
   && "$(jq -r .callee_env_note <<<"$out2")" == *"live callee"* ]]
check "live-surface follow-up: callee_env=not-redelivered, with the note saying why" $? \
  "out2=$out2 stderr=$(cat "$t/err2.txt")"

# The typed launch line %q-quotes the block; a forwarded value with a space and a
# leading `!` must come out of that quoting unchanged.
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"
printf 'some earlier output\n\xe2\x9d\xaf\xc2\xa0\nClaude Code v2.1.221\n' > "$t/screen.txt"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-ce-6" HOTLINE_PENDING_DIR="$t/pending" \
  FWD_HELPER='!/home/u/bin/gh-app-token git-credential' FWD_EMPTY="" \
  HOTLINE_CALLEE_ENV_FORWARD="FWD_HELPER FWD_EMPTY" \
  bash "$DIAL" --target "$t/target" --mode work_order --placement detached \
    --label "probe label" --prompt "first contact" --boot-timeout 8 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
launch_script_of "$call_dir" > "$t/launch.sh"
argv_claude "$t/runbin" "$t/argv.log"
PATH="$t/runbin:$PATH" bash "$t/launch.sh" >/dev/null 2>&1
jq -e '.env == {FWD_HELPER:"!/home/u/bin/gh-app-token git-credential", FWD_EMPTY:""}' \
  <<<"$(settings_of "$t/argv.log")" >/dev/null 2>&1
check "cmux: forwarded values with a space, a '!' and an empty string survive the launch script" $? \
  "out=$out launch=$(cat "$t/launch.sh") argv=$(cat "$t/argv.log" 2>/dev/null)"

# ===========================================================================
# cmux conference: cmux-call.sh's own launch script carries it too.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"; argv_claude "$t/bin" "$t/unused.log"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-ce-3" HOTLINE_PENDING_DIR="$t/pending" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_CALLEE_ENV="AGENTIC_DEV_RUN=7" \
  bash "$DIAL" --target "$t/target" --mode conference --label "probe label" \
    --prompt "let's talk" 2>"$t/err.txt")
[[ "$(jq -r .status <<<"$out")" == "connected" && "$(jq -r .callee_env <<<"$out")" == "settings" ]]
check "conference: payload reports callee_env=settings" $? "out=$out stderr=$(cat "$t/err.txt")"
conf_launch=$(grep -oE '/tmp/hotline-cmux-launch-[A-Za-z0-9]+' "$t/send_calls" 2>/dev/null | head -1)
[[ -n "$conf_launch" ]] && note_leak "$conf_launch"
grep -qF -- "--settings" "$conf_launch" 2>/dev/null \
  && grep -qF 'AGENTIC_DEV_RUN' "$conf_launch" 2>/dev/null
check "conference: its launch script passes --settings with the variable" $? \
  "launch=$(cat "$conf_launch" 2>/dev/null || echo NONE)"

# ===========================================================================
# Unset: no flag on any argv, no key in the payload.
# ===========================================================================
t=$(new_env); note_leak "$t"
argv_claude "$t/bin" "$t/argv.log"; make_ps "$t/bin"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" \
  HOTLINE_CALLER_SESSION_ID="caller-ce-4" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode quick --label "probe label" --headless \
    --prompt "hi" --boot-timeout 8 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
[[ "$(jq -r .status <<<"$out")" == "connected" ]] \
  && ! jq -e 'has("callee_env") or has("callee_env_note")' <<<"$out" >/dev/null \
  && [[ -s "$t/argv.log" ]] && ! grep -qx -- '--settings' "$t/argv.log"
check "unset: no --settings on the argv and no callee_env key in the payload" $? \
  "out=$out argv=$(cat "$t/argv.log" 2>/dev/null)"

t=$(new_env); note_leak "$t"
make_cmux "$t/bin"
printf 'some earlier output\n\xe2\x9d\xaf\xc2\xa0\nClaude Code v2.1.221\n' > "$t/screen.txt"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-ce-5" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order --placement detached \
    --label "probe label" --prompt "first contact" --boot-timeout 8 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
launch=$(launch_script_of "$call_dir")
[[ "$(jq -r .status <<<"$out")" == "connected" && -n "$launch" && "$launch" != *"--settings"* ]] \
  && ! jq -e 'has("callee_env")' <<<"$out" >/dev/null
check "unset: the cmux launch script carries no --settings" $? "out=$out launch=$launch"

dial_wrapper_finish
