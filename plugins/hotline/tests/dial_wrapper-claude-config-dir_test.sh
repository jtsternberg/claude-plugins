#!/usr/bin/env bash
# =============================================================================
# dial.sh wrapper regression tests — the claude callee's account on cmux, cmux
# conference and headless: CLAUDE_CONFIG_DIR reaches the claude PROCESS (a launch
# script export, the `claude -p` env), verbatim, from HOTLINE_CLAUDE_CONFIG_DIR or
# the dialer's own CLAUDE_CONFIG_DIR; and a dialer with neither sets nothing. The
# herdr half lives in claude-config-dir-herdr_test.sh.
#
# One shard of the dial_wrapper suite. The stubs, sockets and scratch-env
# helpers live in lib/dial-wrapper-harness.sh.
# =============================================================================
set -u
FAKE_CLAUDE_PID=990007
# shellcheck source=lib/dial-wrapper-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/dial-wrapper-harness.sh"

echo "dial.sh claude callee account (CLAUDE_CONFIG_DIR):"

# The claude the launch actually runs, recording the account it got.
env_claude() {   # env_claude <bin-dir> <log>
  mkdir -p "$1"
  cat > "$1/claude" <<EOF
#!/usr/bin/env bash
printf 'CLAUDE_CONFIG_DIR=%s\n' "\${CLAUDE_CONFIG_DIR-<unset>}" >> "$2"
{ printf '%s\n' "\$@"; printf -- '--END--\n'; } >> "$2"
SID="\${FAKE_CLAUDE_SESSION_ID:-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee}"
printf '{"type":"system","session_id":"%s"}\n' "\$SID"
printf '{"type":"result","session_id":"%s","result":"ok","num_turns":1}\n' "\$SID"
EOF
  chmod +x "$1/claude"
}
cmux_dial() {  # cmux_dial <scratch> <env...> -- <dial args...>
  local t="$1"; shift; local envs=()
  while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done; shift
  env PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
    HOTLINE_CALLER_SESSION_ID="caller-ccd-$RANDOM" HOTLINE_PENDING_DIR="$t/pending" \
    ${envs[@]+"${envs[@]}"} bash "$DIAL" --target "$t/target" --label "probe label" "$@" 2>"$t/err.txt"
}

# --- cmux first contact: the launch script exports it, spelled as given ------
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; mkdir -p "$t/acct"; ln -s "$t/acct" "$t/alt-link"
printf 'some earlier output\n\xe2\x9d\xaf\xc2\xa0\nClaude Code v2.1.221\n' > "$t/screen.txt"
out=$(cmux_dial "$t" CLAUDE_CONFIG_DIR="$t/alt-link" -- --mode work_order --placement detached \
  --prompt "first contact" --boot-timeout 8)
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null); [[ -n "$call_dir" ]] && note_leak "$call_dir"
launch_script_of "$call_dir" > "$t/launch.sh"
env_claude "$t/runbin" "$t/run.log"
env -u CLAUDE_CONFIG_DIR PATH="$t/runbin:$PATH" bash "$t/launch.sh" >/dev/null 2>&1
grep -qxF "CLAUDE_CONFIG_DIR=$t/alt-link" "$t/run.log"
check "cmux: the caller's CLAUDE_CONFIG_DIR reaches claude verbatim from the launch script" $? \
  "out=$out launch=$(cat "$t/launch.sh") run=$(cat "$t/run.log" 2>/dev/null)"
[[ "$(cat "$call_dir/claude_config_dir.txt" 2>/dev/null)" == "$t/alt-link" ]]
check "cmux: claude_config_dir.txt records it" $?

t=$(new_env); note_leak "$t"
make_cmux "$t/bin"
printf 'some earlier output\n\xe2\x9d\xaf\xc2\xa0\nClaude Code v2.1.221\n' > "$t/screen.txt"
out=$(cmux_dial "$t" -- --mode work_order --placement detached --prompt "first contact" --boot-timeout 8)
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null); [[ -n "$call_dir" ]] && note_leak "$call_dir"
launch=$(launch_script_of "$call_dir")
[[ "$(jq -r .status <<<"$out")" == connected && -n "$launch" && "$launch" != *CLAUDE_CONFIG_DIR* \
   && ! -e "$call_dir/claude_config_dir.txt" ]]
check "cmux: a caller with no CLAUDE_CONFIG_DIR gets a launch script that sets none" $? "out=$out launch=$launch"

# --- conference: cmux-call.sh's own launch script -------------------------------
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"; mkdir -p "$t/acct"
out=$(cmux_dial "$t" HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_CLAUDE_CONFIG_DIR="$t/acct" -- \
  --mode conference --prompt "let's talk")
conf_launch=$(grep -oE '/tmp/hotline-cmux-launch-[A-Za-z0-9]+' "$t/send_calls" 2>/dev/null | head -1)
[[ -n "$conf_launch" ]] && note_leak "$conf_launch"
printf -v want 'export CLAUDE_CONFIG_DIR=%q' "$t/acct"
grep -qxF "$want" "$conf_launch" 2>/dev/null
check "conference: its launch script exports the selected dir" $? "out=$out launch=$(cat "$conf_launch" 2>/dev/null || echo NONE)"

# --- headless: the explicit knob beats the inherited account ---------------------
t=$(new_env); note_leak "$t"
env_claude "$t/bin" "$t/argv.log"; make_ps "$t/bin"; mkdir -p "$t/acct" "$t/caller-acct"
out=$(cmux_dial "$t" CLAUDE_CONFIG_DIR="$t/caller-acct" HOTLINE_CLAUDE_CONFIG_DIR="$t/acct" -- \
  --mode quick --headless --prompt hi --boot-timeout 8)
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null); [[ -n "$call_dir" ]] && note_leak "$call_dir"
grep -qxF "CLAUDE_CONFIG_DIR=$t/acct" "$t/argv.log" && [[ "$(cat "$call_dir/claude_config_dir.txt" 2>/dev/null)" == "$t/acct" ]]
check "headless: HOTLINE_CLAUDE_CONFIG_DIR is claude -p's process env, over the caller's own" $? \
  "out=$out argv=$(cat "$t/argv.log" 2>/dev/null)"

# --- the knob is dial's, never the callee's ---------------------------------------
# A headless callee inherits dial's environment. Carrying HOTLINE_CLAUDE_CONFIG_DIR
# would make every dial IT makes an explicit account choice (and refuse --remote);
# its own CLAUDE_CONFIG_DIR already says which account it is.
knob_claude() {   # knob_claude <bin-dir> <log>
  mkdir -p "$1"
  cat > "$1/claude" <<STUB
#!/usr/bin/env bash
printf 'KNOB=%s\nCLAUDE_CONFIG_DIR=%s\n' "\${HOTLINE_CLAUDE_CONFIG_DIR-<unset>}" "\${CLAUDE_CONFIG_DIR-<unset>}" >> "$2"
{ printf '%s\n' "\$@"; printf -- '--END--\n'; } >> "$2"
SID="\${FAKE_CLAUDE_SESSION_ID:-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee}"
printf '{"type":"system","session_id":"%s"}\n' "\$SID"
printf '{"type":"result","session_id":"%s","result":"ok","num_turns":1}\n' "\$SID"
STUB
  chmod +x "$1/claude"
}
for how in default explicit; do
  t=$(new_env); note_leak "$t"
  knob_claude "$t/bin" "$t/argv.log"; make_ps "$t/bin"; mkdir -p "$t/acct"
  case $how in
    default)  extra=(CLAUDE_CONFIG_DIR="$t/acct") ;;
    explicit) extra=(HOTLINE_CLAUDE_CONFIG_DIR="$t/acct") ;;
  esac
  out=$(cmux_dial "$t" "${extra[@]}" -- --mode quick --headless --prompt hi --boot-timeout 8)
  call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null); [[ -n "$call_dir" ]] && note_leak "$call_dir"
  grep -qx 'KNOB=<unset>' "$t/argv.log" && grep -qxF "CLAUDE_CONFIG_DIR=$t/acct" "$t/argv.log"
  check "headless ($how): the callee gets its account, not the HOTLINE_CLAUDE_CONFIG_DIR knob" $? \
    "out=$out argv=$(cat "$t/argv.log" 2>/dev/null)"
done

# --- a resume runs on the account that holds the session ------------------------
# Session ids are found in any configured account dir; claude --resume only finds
# one under the account that wrote it.
RSID=12121212-3434-4565-8787-909090909090
stage_session() {  # stage_session <config-dir> <cwd>
  local real f
  real=$(cd "$2" && pwd -P)
  f="$1/projects/$(printf '%s' "$real" | sed 's|[^a-zA-Z0-9]|-|g')/$RSID.jsonl"
  mkdir -p "$(dirname "$f")"
  printf '{"type":"user","sessionId":"%s","cwd":"%s","message":{"content":"earlier"}}\n' "$RSID" "$real" > "$f"
}
resume_dial() {  # resume_dial <scratch> <env...>
  local t="$1"; shift
  cmux_dial "$t" "$@" -- --mode quick --headless --resume "$RSID" --prompt hi --boot-timeout 8
}
got_ccd() { grep -m1 '^CLAUDE_CONFIG_DIR=' "$1/argv.log" 2>/dev/null; }

t=$(new_env); note_leak "$t"; knob_claude "$t/bin" "$t/argv.log"; make_ps "$t/bin"; mkdir -p "$t/alt"
stage_session "$t/home/.claude" "$t/target"
out=$(resume_dial "$t" CLAUDE_CONFIG_DIR="$t/alt" AGENT_CLAUDE_CONFIG_DIRS="$t/home/.claude")
[[ "$(got_ccd "$t")" == 'CLAUDE_CONFIG_DIR=<unset>' ]] && grep -qx -- '--resume' "$t/argv.log"
check "resume: a default-account session resumes with CLAUDE_CONFIG_DIR unset, from an alt caller" $? \
  "out=$out argv=$(cat "$t/argv.log" 2>/dev/null)"

t=$(new_env); note_leak "$t"; knob_claude "$t/bin" "$t/argv.log"; make_ps "$t/bin"; mkdir -p "$t/other"
stage_session "$t/other" "$t/target"
out=$(resume_dial "$t" AGENT_CLAUDE_CONFIG_DIRS="$t/other")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null); [[ -n "$call_dir" ]] && note_leak "$call_dir"
[[ "$(got_ccd "$t")" == "CLAUDE_CONFIG_DIR=$t/other" && "$(cat "$call_dir/claude_config_dir.txt" 2>/dev/null)" == "$t/other" ]]
check "resume: a session in another account dir resumes there, and the waiter is told so" $? \
  "out=$out argv=$(cat "$t/argv.log" 2>/dev/null)"

t=$(new_env); note_leak "$t"; knob_claude "$t/bin" "$t/argv.log"; make_ps "$t/bin"; mkdir -p "$t/alt"
stage_session "$t/home/.claude" "$t/target"; ln -s "$t/home/.claude/projects" "$t/alt/projects"
out=$(resume_dial "$t" CLAUDE_CONFIG_DIR="$t/alt" AGENT_CLAUDE_CONFIG_DIRS="$t/home/.claude")
[[ "$(got_ccd "$t")" == "CLAUDE_CONFIG_DIR=$t/alt" ]]
check "resume: when a shared projects/ puts it in both, the caller's own account wins" $? \
  "out=$out argv=$(cat "$t/argv.log" 2>/dev/null)"

t=$(new_env); note_leak "$t"; knob_claude "$t/bin" "$t/argv.log"; make_ps "$t/bin"; mkdir -p "$t/other" "$t/acct"
stage_session "$t/other" "$t/target"
out=$(resume_dial "$t" AGENT_CLAUDE_CONFIG_DIRS="$t/other" HOTLINE_CLAUDE_CONFIG_DIR="$t/acct")
[[ "$(jq -r .stage <<<"$out")" == args && "$(jq -r .detail <<<"$out")" == *"$t/other"* && ! -s "$t/argv.log" ]]
check "resume: an explicit dir that does not hold the session is refused before launch" $? "out=$out"

dial_wrapper_finish
