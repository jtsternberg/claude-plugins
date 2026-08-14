#!/usr/bin/env bash
# =============================================================================
# herdr Call: launch an interactive claude session as a named herdr agent and
# hand back the same call dir every other hotline launcher produces.
#
# THE LAUNCH IS SYNCHRONOUS, THE CONTRACT IS NOT. `herdr agent start` BLOCKS until
# herdr has detected the expected agent in the pane and considers it ready for
# interactive input — so unlike cmux-call-async.sh, this launcher already knows the
# callee's REPL is up by the time it returns, and it writes session_id.txt itself
# rather than leaving the promotion to wait-for-session.sh. The `-async` name is
# kept because the CONTRACT is the async one: return a call_dir, let the caller
# drive boot-wait / deliver / wait-response as separate steps. wait-for-session.sh
# still runs (it is what registers the call); for herdr it confirms and returns an
# answer that is already on disk.
#
# Call-dir interface — the same backend-agnostic contract as
# cmux-call-async.sh / headless-call-async.sh, plus one herdr-specific handle:
#   transport.txt         — 'herdr'. Read FIRST by the wait-for-* scripts.
#   herdr_agent.txt       — the agent NAME. This is the host handle: `agent prompt`,
#                           `agent wait` and `agent get` all address it, and it
#                           survives the detach/lid/SSH-drop events that kill a
#                           cmux surface. dial.sh reports it as the call's host ref.
#   herdr_pane.txt        — the pane the agent runs in. Diagnostic, and what the
#                           failure paths here close so a failed dial leaks nothing.
#   cwd.txt               — the callee's working directory; the transcript path is
#                           derived from it.
#   session_id_preset.txt — the UUID passed to `claude --session-id`.
#   session_id.txt        — written HERE (see above), not by the boot wait.
#   call_id.txt           — the per-call nonce, minted via repl-state.sh.
#   pending_paste.md      — the nonce-injected prompt, 0600, awaiting delivery by
#                           herdr-prompt.sh. Its presence is the signal to the
#                           caller that a delivery step is still owed.
#   keep_workspace.txt    — always 'true' for herdr; see WHY NOTHING IS CLOSED.
#   mode/caller_cwd/caller_session.txt — via persist-call-meta.sh, so
#                           register-call.sh can record the call.
#   error.txt + done       — written on any early failure, with the call_dir still
#                           returned, exactly as the other async launchers do.
#
# THE PROMPT IS NOT LAUNCHED WITH CLAUDE, for the same reason it isn't under cmux:
# a work order on claude's argv is readable by any local user through `ps`
# (claude-plugins-86ka). The REPL comes up empty and herdr-prompt.sh delivers.
#
# WHY NOTHING IS CLOSED AFTER THE CALL. A cmux detached workspace is closed once
# the response is captured, because a cmux surface is cheap and dies with its
# window anyway. A herdr agent is the opposite: surviving disconnects is the reason
# to choose this transport at all, and Phase 2's follow-up path re-targets this
# very agent by name. So keep_workspace.txt is 'true' and the agent is left live.
# The cost is honest and worth stating: a herdr call leaves a pane behind, and the
# caller (or the user) closes it — `herdr pane close <herdr_pane.txt>`.
#
# Usage:
#   herdr-call-async.sh --cwd <path> (--prompt <text> | --prompt-file <path>)
#                       [--name <session-name>] [--tools <list>]
#                       [--boot-timeout <seconds>] [--detached]
#   # → {"call_dir":"…","agent":"hotline-…","pane":"w6:p2","session_id":"…"}
#
# --prompt-file is preferred: it keeps the payload out of argv end to end.
# --detached is accepted and ignored: it is the only placement herdr Phase 1
# supports, and dial.sh rejects the others before it ever reaches this script.
# =============================================================================
set -uo pipefail

if [[ "${1:-}" == "--help" ]]; then
  sed -n '2,/^# =\{10,\}$/p' "$0" | sed 's/^# \{0,1\}//' | grep -v '^=\{10,\}$'
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOTLINE_SCRIPTS="$(cd "$SCRIPT_DIR/../../.." && pwd)/scripts"
# shellcheck source=../../../scripts/repl-state.sh
source "$HOTLINE_SCRIPTS/repl-state.sh"
# shellcheck source=../../../scripts/herdr-state.sh
source "$HOTLINE_SCRIPTS/herdr-state.sh"

CWD=""
PROMPT=""
PROMPT_FILE=""
SESSION_NAME=""
ALLOWED_TOOLS="Bash Read Edit Write Grep Glob"
BOOT_TIMEOUT=""
RESUME_ID=""
FORK_SESSION=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd)          CWD="$2";           shift 2 ;;
    --prompt)       PROMPT="$2";        shift 2 ;;
    --prompt-file)  PROMPT_FILE="$2";   shift 2 ;;
    --name)         SESSION_NAME="$2";  shift 2 ;;
    --tools)        ALLOWED_TOOLS="$2"; shift 2 ;;
    --boot-timeout) BOOT_TIMEOUT="$2";  shift 2 ;;
    --resume)       RESUME_ID="$2";     shift 2 ;;
    --fork-session) FORK_SESSION=true;  shift   ;;
    # The only placement herdr Phase 1 supports; accepted for symmetry with the
    # other launchers so dial.sh can pass its placement args unconditionally.
    --detached|--new-workspace) shift ;;
    *) shift ;;
  esac
done

die() { jq -nc --arg err "$1" '{error: $err}'; exit 1; }

# `pane split --cwd` needs a real directory: unlike cmux's launch script, there is
# no `cd` step to fail later and no ambient cwd to inherit from the caller.
[[ -z "$CWD" ]] && die "No --cwd provided; herdr splits its pane with an explicit --cwd"
[[ -d "$CWD" ]] || die "--cwd does not exist or is not a directory: $CWD"

if [[ -n "$PROMPT_FILE" ]]; then
  [[ -f "$PROMPT_FILE" ]] || die "--prompt-file does not exist: $PROMPT_FILE"
  PROMPT=$(cat "$PROMPT_FILE")
fi
[[ -z "$PROMPT" ]] && die "No --prompt or --prompt-file provided"

# Phase 1 is FIRST CONTACT ONLY. A resume/fork would need the callee's existing
# session to be re-hosted in a new herdr agent, which is the Phase 2 follow-up
# verb — and a plain resume must NOT pass --session-id (claude rejects the
# combination), so the preset below would be wrong for it. Refuse rather than
# launch something whose transcript path we would then derive incorrectly.
if [[ -n "$RESUME_ID" ]] || $FORK_SESSION; then
  die "herdr Phase 1 is first-contact only: --resume/--fork-session are the Phase 2 follow-up path. Dial with --transport cmux to continue an existing session."
fi

if [[ -n "$BOOT_TIMEOUT" && ! "$BOOT_TIMEOUT" =~ ^[0-9]+$ ]]; then
  die "--boot-timeout must be a whole number of seconds, got '$BOOT_TIMEOUT'"
fi

# Resolve the pane to split BEFORE creating any state: nothing to clean up if
# there is no host to be had. check-herdr.sh has normally already proved this, but
# this script is also a direct entry point.
herdr_resolve_split_pane \
  || die "no herdr pane could be resolved to host the callee: ${HERDR_CLI_ERR:-no diagnostic}"
SPLIT_FROM="$HERDR_PANE"

# HOTLINE_CALL_HOME overrides the base dir (default /tmp) so test suites can own
# and wipe every call dir instead of littering /tmp (claude-plugins-cjgn).
CALL_DIR=$(mktemp -d "${HOTLINE_CALL_HOME:-/tmp}/hotline-call-XXXXX")
# Which backend owns this call dir. Written with the dir, before a host exists, so
# it is there for every later reader even if this launcher dies mid-placement.
echo herdr > "$CALL_DIR/transport.txt"
# See WHY NOTHING IS CLOSED in the header.
echo true > "$CALL_DIR/keep_workspace.txt"
echo "$CWD" > "$CALL_DIR/cwd.txt"
# [MODE:]/[CALLER:]/[SESSION:] tags out of the ringing prompt, so register-call.sh
# can record this call without the dialing agent remembering to. Via the file when
# we have one, so the payload takes no argv detour.
if [[ -n "$PROMPT_FILE" ]]; then
  bash "$SCRIPT_DIR/persist-call-meta.sh" "$CALL_DIR" "$CWD" --prompt-file "$PROMPT_FILE"
else
  bash "$SCRIPT_DIR/persist-call-meta.sh" "$CALL_DIR" "$CWD" "$PROMPT"
fi

# The callee's session id, chosen HERE and passed to `claude --session-id`. It has
# to be presettable: the entire response channel is
# ~/.claude/projects/<encoded-cwd>/<session>.jsonl, so the id must be known before
# the callee boots. (Verified live on herdr 0.8.0: `agent start … -- --session-id
# <uuid>` reaches claude verbatim.) herdr ALSO reports the session id it observed,
# and that observation wins over this preset if the two ever disagree — see below.
SESSION_ID_PRESET=$(hotline_mint_session_uuid)
[[ -z "$SESSION_ID_PRESET" ]] && die "could not mint a session UUID (no uuidgen, /proc uuid, or /dev/urandom)"
echo "$SESSION_ID_PRESET" > "$CALL_DIR/session_id_preset.txt"

# Per-call nonce. Same protocol as every other transport — the receiver echoes it
# back as `STATUS: <signal> call_id=<nonce>`, delivery confirmation proves itself
# with it, and it is what stops a replayed STATUS from a resumed transcript being
# read as completion of THIS call. Minted and injected through repl-state.sh
# because the placement rule is shared, not local.
CALL_ID=$(hotline_mint_call_id)
echo "$CALL_ID" > "$CALL_DIR/call_id.txt"
PROMPT=$(hotline_inject_call_id "$CALL_ID" "$PROMPT")

# The prompt waits here for delivery and never reaches claude's argv. 0600 in a
# 0700 mktemp dir: a work order is exactly the payload other local users must not
# be able to read.
PENDING_PASTE="$CALL_DIR/pending_paste.md"
( umask 077; printf '%s' "$PROMPT" > "$PENDING_PASTE" )
chmod 600 "$PENDING_PASTE" 2>/dev/null || true

# Early-failure exit, matching the other async launchers: write error.txt + done,
# close any pane we opened, and still return a usable call_dir — the wait-for-*
# scripts are what surface the error, and check_early_fail needs it on disk.
fail_async() {  # fail_async <reason>
  jq -n --arg err "$1" '{error: $err}' > "$CALL_DIR/error.txt"
  touch "$CALL_DIR/done"
  # Close the pane WE created, and only that one. A failed dial that leaves a
  # split behind is how a herdr session accumulates dead panes. Keep it on request
  # for post-mortem — the pane's scrollback is the only evidence of a launch that
  # died before the agent was detected.
  if [[ -n "${NEW_PANE:-}" && -z "${HOTLINE_HERDR_KEEP_FAILED_PANE:-}" ]]; then
    herdr_cli pane close "$NEW_PANE" >/dev/null 2>&1 || true
  fi
  jq -n --arg dir "$CALL_DIR" '{call_dir: $dir}'
  exit 0
}

# ---- Open the host: a sibling pane, in the callee's cwd. --------------------
# --no-focus deliberately: a work order is background work, and stealing the
# user's focus to a pane they did not ask for is the opposite of detached.
SPLIT_DIRECTION="${HOTLINE_HERDR_SPLIT_DIRECTION:-right}"
NEW_PANE=""
herdr_cli pane split --pane "$SPLIT_FROM" \
    --direction "$SPLIT_DIRECTION" --cwd "$CWD" --no-focus \
  || fail_async "herdr pane split from $SPLIT_FROM failed: ${HERDR_CLI_ERR:-no diagnostic}"
NEW_PANE=$(jq -r '.result.pane.pane_id // empty' <<<"$HERDR_CLI_OUT" 2>/dev/null)
[[ -z "$NEW_PANE" ]] && fail_async "herdr pane split returned no pane id: $(printf '%s' "$HERDR_CLI_OUT" | tr -d '\n' | cut -c1-200)"
echo "$NEW_PANE" > "$CALL_DIR/herdr_pane.txt"

# ---- Start the agent. -------------------------------------------------------
# `agent start` requires the pane to be AT ITS INTERACTIVE SHELL PROMPT, and a
# freshly split pane needs a moment to get there — starting immediately can fail
# `agent_pane_busy`. So: settle, then retry that specific failure a few times
# rather than turning a race into a dead call.
SETTLE="${HOTLINE_HERDR_PANE_SETTLE:-1}"
START_ATTEMPTS="${HOTLINE_HERDR_START_ATTEMPTS:-4}"

# The claude argv, passed through verbatim after `--` (verified live on herdr
# 0.8.0). An ARRAY, not a string: herdr hands these to claude as argv elements, so
# nothing here needs shell quoting.
#
# --allowedTools stays in its `=`-joined ONE-WORD form for the same reason the cmux
# launcher documents: some recorders treat `--allowedTools` as arity-0 and drop the
# value that follows a space-separated form, which resurrects the callee later with
# a bare `--allowedTools` and no list. claude accepts either form.
#
# No `-n <session-name>` here, unlike cmux: that flag's passthrough is unverified
# under herdr, and the herdr agent NAME already carries the call's identity in
# `herdr agent list`. $SESSION_NAME is used for the agent-name slug instead.
CLAUDE_ARGS=(--session-id "$SESSION_ID_PRESET")
[[ -n "${HOTLINE_CLAUDE_MODEL:-}" ]] && CLAUDE_ARGS+=(--model "$HOTLINE_CLAUDE_MODEL")
# Opt-in via HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS — see README. A hotline callee
# lands in an unattended pane, so without this it stalls on the first permission
# gate (which herdr at least reports honestly as `blocked`). Off by default; it is
# a real trust decision.
case "${HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS:-}" in
  1|true|TRUE|yes|YES) CLAUDE_ARGS+=(--dangerously-skip-permissions) ;;
esac
CLAUDE_ARGS+=("--allowedTools=$ALLOWED_TOOLS")

# herdr's own startup budget. It blocks until the agent is interactive-ready, so
# this IS the boot timeout — the caller's --boot-timeout governs it, in ms, capped
# at herdr's documented 300s maximum.
BOOT_SECONDS="${BOOT_TIMEOUT:-$HOTLINE_BOOT_TIMEOUT_CMUX}"
START_TIMEOUT_MS=$(( BOOT_SECONDS * 1000 ))
[[ $START_TIMEOUT_MS -gt 300000 ]] && START_TIMEOUT_MS=300000
[[ $START_TIMEOUT_MS -lt 1000   ]] && START_TIMEOUT_MS=1000

AGENT_NAME=""
START_OUT=""
START_ERR=""
attempt=0
while [[ $attempt -lt $START_ATTEMPTS ]]; do
  attempt=$((attempt + 1))
  sleep "$SETTLE"

  # A fresh name per attempt: a start that failed for a reason OTHER than a busy
  # pane may still have consumed the name, and herdr rejects a duplicate outright.
  AGENT_NAME=$(herdr_mint_agent_name "${SESSION_NAME:-$CWD}")
  herdr_agent_name_free "$AGENT_NAME" || AGENT_NAME=$(herdr_mint_agent_name "${SESSION_NAME:-$CWD}")

  if herdr_cli agent start "$AGENT_NAME" --kind claude --pane "$NEW_PANE" \
       --timeout "$START_TIMEOUT_MS" -- "${CLAUDE_ARGS[@]}"; then
    START_OUT="$HERDR_CLI_OUT"
    START_ERR=""
    break
  fi
  START_ERR="$HERDR_CLI_ERR"
  # Only the shell-not-ready race is worth retrying. Anything else — a bad claude
  # argv, a pane that vanished, a name collision we lost twice — will not fix
  # itself, and retrying it just burns the budget before reporting the real cause.
  case "$START_ERR" in
    *agent_pane_busy*|*pane_busy*|*not\ at\ *prompt*) ;;
    *) break ;;
  esac
  START_OUT=""
done

[[ -n "$START_ERR" ]] && fail_async "herdr agent start failed in pane $NEW_PANE after ${attempt} attempt(s): $START_ERR"
echo "$AGENT_NAME" > "$CALL_DIR/herdr_agent.txt"

# ---- Is it really ready? ----------------------------------------------------
# `agent start` returning at all is herdr's own readiness claim, and the one
# hotline is entitled to trust here: it is the same claim cmux has to establish
# with three separate screen signals. But it is reported as a FIELD, so read the
# field rather than the exit status — a start that came back with
# interactive_ready:false means the pane holds something that is not a REPL ready
# for a prompt, and delivering into it is precisely the failure cmux went to
# lengths to prevent.
# `// empty` would be WRONG here and silently so: jq's alternative operator treats
# `false` as absent, so `interactive_ready // empty` collapses the one value this
# check exists to catch into the same "" as a missing field. Ask whether the key is
# there, then stringify it.
READY=$(jq -r '.result.agent // {} | if has("interactive_ready") then (.interactive_ready | tostring) else "" end' <<<"$START_OUT" 2>/dev/null)
AGENT_STATUS=$(jq -r '.result.agent.agent_status // empty' <<<"$START_OUT" 2>/dev/null)
if [[ "$READY" == "false" ]]; then
  fail_async "herdr started agent $AGENT_NAME in pane $NEW_PANE but reported interactive_ready:false (agent_status=${AGENT_STATUS:-unknown}); a prompt delivered now would go to whatever IS there"
fi

# ---- Which session did it actually open? ------------------------------------
# herdr reads the claude session id off claude's own state, so its observation
# beats our preset when the two disagree — a disagreement means the --session-id
# passthrough did not take, and a transcript path derived from the preset would
# then miss silently for the whole call. Recorded rather than swallowed, because it
# is also the single most useful thing to know if a herdr dial ever goes quiet.
OBSERVED=$(jq -r '.result.agent.agent_session.value // empty' <<<"$START_OUT" 2>/dev/null)
if [[ -z "$OBSERVED" ]]; then
  herdr_agent_session_id "$AGENT_NAME"
  OBSERVED="$HERDR_AGENT_SESSION_ID"
fi
SESSION_ID="$SESSION_ID_PRESET"
if [[ -n "$OBSERVED" && "$OBSERVED" != "$SESSION_ID_PRESET" ]]; then
  SESSION_ID="$OBSERVED"
  printf 'preset=%s observed=%s\nherdr observed a different claude session id than the one we preset via --session-id; the observed id is authoritative for the transcript path.\n' \
    "$SESSION_ID_PRESET" "$OBSERVED" > "$CALL_DIR/session_id_mismatch.txt"
fi
# Written HERE, not by wait-for-session.sh: `agent start` already blocked until the
# REPL was up, so the "a session id is available" signal genuinely means "claude is
# up" — which is the property the cmux promotion dance exists to establish.
echo "$SESSION_ID" > "$CALL_DIR/session_id.txt"

jq -nc --arg dir "$CALL_DIR" --arg agent "$AGENT_NAME" --arg pane "$NEW_PANE" \
       --arg sid "$SESSION_ID" \
  '{call_dir: $dir, agent: $agent, pane: $pane, session_id: $sid}'
