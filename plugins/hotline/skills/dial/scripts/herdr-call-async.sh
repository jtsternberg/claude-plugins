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
#   remote_target.txt     — the ssh target hosting this callee, for a --remote dial;
#                           ABSENT for a local one. Written with the dir because
#                           wait-for-response.sh is a separate process that receives
#                           nothing but the call dir, and asking the LOCAL herdr
#                           about a remote agent gets "no such agent" — i.e. the
#                           callee reported dead while it works.
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
# to choose this transport at all, and the follow-up path (herdr-reuse-agent.sh)
# re-targets this very agent by name. So keep_workspace.txt is 'true' and the agent is left live.
# The cost is honest and worth stating: a herdr call leaves a pane behind, and the
# caller (or the user) closes it — `herdr pane close <herdr_pane.txt>`, or
# `ssh <remote_target.txt> herdr pane close <herdr_pane.txt>` for a remote call.
#
# A REMOTE CALLEE IS THE SAME LAUNCH, ON ANOTHER BOX. `$HOTLINE_HERDR_REMOTE` makes
# every herdr verb below run over ssh (herdr-state.sh's dispatch), so the split and
# the `agent start` are unchanged. What DOES change is the cwd: it names a directory
# on THAT filesystem, so it is resolved and existence-checked over ssh rather than
# locally — see the canonicalization note below, which is where a local check would
# do real damage rather than merely be useless.
#
# Usage:
#   herdr-call-async.sh --cwd <path> (--prompt <text> | --prompt-file <path>)
#                       [--tools <list>] [--boot-timeout <seconds>] [--detached]
#   # → {"call_dir":"…","agent":"hotline-…","pane":"w6:p2","session_id":"…"}
#   #   plus "remote":"<ssh-target>" when $HOTLINE_HERDR_REMOTE hosted it
#
# --prompt-file is preferred: it keeps the payload out of argv end to end.
# --detached is accepted and ignored, and so is a side placement: a herdr callee is
# a pane split off the caller's, which is both — the placement word only changes
# what dial.sh reports. `--window` never reaches here; dial.sh refuses it.
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
ALLOWED_TOOLS="Bash Read Edit Write Grep Glob"
BOOT_TIMEOUT=""
RESUME_ID=""
FORK_SESSION=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd)          CWD="$2";           shift 2 ;;
    --prompt)       PROMPT="$2";        shift 2 ;;
    --prompt-file)  PROMPT_FILE="$2";   shift 2 ;;
    --tools)        ALLOWED_TOOLS="$2"; shift 2 ;;
    --boot-timeout) BOOT_TIMEOUT="$2";  shift 2 ;;
    --resume)       RESUME_ID="$2";     shift 2 ;;
    --fork-session) FORK_SESSION=true;  shift   ;;
    # Placement is not this launcher's decision — one split serves side and
    # detached alike. Accepted for symmetry with the other launchers, so dial.sh can
    # pass its placement args unconditionally.
    --detached|--new-workspace) shift ;;
    *) shift ;;
  esac
done

die() { jq -nc --arg err "$1" '{error: $err}'; exit 1; }

# `pane split --cwd` needs a real directory: unlike cmux's launch script, there is
# no `cd` step to fail later and no ambient cwd to inherit from the caller.
[[ -z "$CWD" ]] && die "No --cwd provided; herdr splits its pane with an explicit --cwd"

# CANONICALIZED ONCE, HERE, and used for both the split and cwd.txt. Claude Code
# derives its project directory from the cwd it actually RESOLVED, so a callee
# launched under a symlinked path writes its transcript under the REALPATH encoding:
# a callee in /tmp/x on macOS lands in ~/.claude/projects/-private-tmp-x, not
# -tmp-x. Every downstream consumer derives the transcript path from cwd.txt, so
# recording the path as handed to us hands them an encoding the callee never used.
#
# Live-caught: a herdr dial into /tmp/herdr-live-smoke delivered fine (delivery
# tries both spellings) and then the response wait reported "the prompt never
# reached the agent" while STATUS: WORK_COMPLETE sat in the real transcript.
# Normalizing here is the half of the fix that makes the two agree by construction;
# the wait also tries both spellings, so a hand-staged call dir still works.
#
# FOR A REMOTE DIAL BOTH HALVES ARE THE REMOTE BOX'S TO ANSWER. `-d` and `pwd -P`
# here would test a path on the CALLER's filesystem — which either does not exist
# (so a perfectly good dial is refused) or exists and resolves differently (so
# cwd.txt records an encoding the remote callee never used, and every later
# transcript read misses silently). Asked over ssh instead, in one hop, which also
# proves the directory is there before a pane is split into it.
if hotline_remote_active; then
  hotline_remote_realpath_dir "$CWD" \
    || die "--cwd does not exist as a directory on $(hotline_remote_target), or could not be resolved there: $CWD (${HOTLINE_REMOTE_ERR:-no diagnostic})"
  CWD="$HOTLINE_REMOTE_REALCWD"
else
  [[ -d "$CWD" ]] || die "--cwd does not exist or is not a directory: $CWD"
  CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || die "--cwd could not be resolved to a real path: $CWD"
fi

if [[ -n "$PROMPT_FILE" ]]; then
  [[ -f "$PROMPT_FILE" ]] || die "--prompt-file does not exist: $PROMPT_FILE"
  PROMPT=$(cat "$PROMPT_FILE")
fi
[[ -z "$PROMPT" ]] && die "No --prompt or --prompt-file provided"

# THIS LAUNCHER ONLY EVER STARTS A NEW SESSION. A resume/fork would re-host an
# existing claude session, and a plain resume must NOT pass --session-id (claude
# rejects the combination) — so the preset below, which is the only reason the
# transcript path is derivable at all, would be wrong for it. Refuse rather than
# launch something whose transcript path we would then derive incorrectly.
#
# This is NOT the follow-up path and never was: a follow-up re-targets the herdr
# agent that already hosts the session (herdr-reuse-agent.sh), so it launches
# nothing and needs no resume.
if [[ -n "$RESUME_ID" ]] || $FORK_SESSION; then
  die "herdr cannot re-host an existing claude session: --resume/--fork-session are incompatible with the --session-id preset the transcript path is derived from. To continue a session hotline already dialed, re-dial the target and the live herdr agent is re-targeted by name; to adopt an unrelated session id, dial with --transport cmux."
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
# WHICH BOX this call lives on, written with the dir for the same reason
# transport.txt is: every later reader needs it, and wait-for-response.sh is a
# SEPARATE PROCESS that gets no arguments but the call dir. Without this the wait
# would ask the local herdr about an agent that only exists over there, be told
# "no such agent", and report the callee as dead. Absent = local, which is what
# every call dir written before this existed means.
if hotline_remote_active; then
  hotline_remote_target > "$CALL_DIR/remote_target.txt"
fi
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
# --no-focus deliberately, for EVERY call including a conference: a callee whose
# REPL is still booting must not hold the user's cursor, or their next keystrokes
# land in it. A conference is focused later, by dial.sh, once the payload is
# confirmed in the callee's transcript.
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
# `herdr agent list` — see AGENT_SLUG_TARGET below for what that name is built from.
# That is also why this launcher takes no `--name` at all: there was nothing left
# for a session name to reach.
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

# The slug names the TARGET, never the call's session name. `basename` of a session
# name ("hotline: a → b (mode)") is the whole string, so slugging it minted every
# agent as hotline-hotline-* and `herdr agent list` could not say which directory a
# stuck callee was sitting in. The host joins the slug for a remote dial: two boxes
# hold the same directory names, and the agent name is the only handle a caller has
# for either one.
AGENT_SLUG_TARGET=$(basename "$CWD")
if hotline_remote_active; then
  # DIRECTORY FIRST, AND EACH HALF ON ITS OWN BUDGET. Joined as `<host>-<dir>` and
  # left to herdr_mint_agent_name's single 14-char cut, any host name of 13
  # characters or more consumed the whole budget and the directory — the one thing
  # this slug exists to say — was cut off entirely. A tailnet FQDN always is:
  # jt@jt-mbp14.taile1234.ts.net + lindris-frontend minted hotline-jt-mbp14-taile-*,
  # which names neither the box usefully nor the directory at all.
  #
  # Login user off the front (it identifies the account, not the box) and the domain
  # off the back (every box in one tailnet shares it), then 8 for the directory and
  # 5 for the host — 8 + 1 + 5 = the same 14 the mint would allow, so the cut there
  # is a no-op and the random tail is untouched.
  AGENT_SLUG_HOST=$(hotline_remote_target)
  AGENT_SLUG_HOST="${AGENT_SLUG_HOST##*@}"
  AGENT_SLUG_HOST="${AGENT_SLUG_HOST%%.*}"
  AGENT_SLUG_TARGET="$(printf '%s' "$AGENT_SLUG_TARGET" | cut -c1-8)-$(printf '%s' "$AGENT_SLUG_HOST" | cut -c1-5)"
fi

AGENT_NAME=""
START_OUT=""
START_ERR=""
attempt=0
while [[ $attempt -lt $START_ATTEMPTS ]]; do
  attempt=$((attempt + 1))
  sleep "$SETTLE"

  # A fresh name per attempt: a start that failed for a reason OTHER than a busy
  # pane may still have consumed the name, and herdr rejects a duplicate outright.
  AGENT_NAME=$(herdr_mint_agent_name "$AGENT_SLUG_TARGET")
  herdr_agent_name_free "$AGENT_NAME" || AGENT_NAME=$(herdr_mint_agent_name "$AGENT_SLUG_TARGET")

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
       --arg sid "$SESSION_ID" --arg remote "$(hotline_remote_target)" \
  '{call_dir: $dir, agent: $agent, pane: $pane, session_id: $sid}
   + (if $remote == "" then {} else {remote: $remote} end)'
