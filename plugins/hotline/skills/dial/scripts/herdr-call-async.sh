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
#   herdr_placement.txt   — 'split' | 'tab' | 'workspace': how that pane was made.
#   herdr_tab.txt         — the tab hosting the callee, for a tab/workspace
#                           placement; ABSENT for a split, which makes no tab.
#   herdr_workspace.txt   — the workspace hosting that tab. Both are here so a
#                           caller can re-label, move or close the host later.
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
# A tab or workspace placement leaves a tab too: `herdr tab close <herdr_tab.txt>`.
#
# A REMOTE CALLEE IS THE SAME LAUNCH, ON ANOTHER BOX. `$HOTLINE_HERDR_REMOTE` makes
# every herdr verb below run over ssh (herdr-state.sh's dispatch), so the placement
# and the `agent start` are unchanged. What DOES change is the cwd: it names a directory
# on THAT filesystem, so it is resolved and existence-checked over ssh rather than
# locally — see the canonicalization note below, which is where a local check would
# do real damage rather than merely be useless.
#
# Usage:
#   herdr-call-async.sh --cwd <path> (--prompt <text> | --prompt-file <path>)
#                       [--name <session-name>] [--label <text>] [--tools <list>]
#                       [--boot-timeout <seconds>] [--detached]
#   # → {"call_dir":"…","agent":"hotline-…","pane":"w6:p2","session_id":"…"}
#   #   plus "remote":"<ssh-target>" when $HOTLINE_HERDR_REMOTE hosted it
#
# --prompt-file is preferred: it keeps the payload out of argv end to end.
# --detached is accepted and ignored, and so is a side placement: dial.sh's
# placement vocabulary only changes what it reports. `--window` never reaches here;
# dial.sh refuses it. --label names what the callee is DOING and reaches the tab a
# tab/workspace placement creates; --name carries the same subject to `claude -n`,
# which claude publishes as the pane's terminal title — that is what names a SPLIT,
# which has no tab of its own. WHERE the callee's pane actually goes is
# $HOTLINE_HERDR_PLACEMENT — a sibling split (the default), its own tab, or a tab
# in a named group workspace ($HOTLINE_HERDR_WORKSPACE). See the placement block.
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

# HOTLINE_CALLEE_ENV rides the callee's argv as a settings env block — see
# scripts/callee-env.sh. dial.sh refuses a malformed value at its args stage; this
# repeats the check for a direct invocation rather than launching without it.
source "$HOTLINE_SCRIPTS/callee-env.sh"
callee_env_validate || { jq -nc --arg e "HOTLINE_CALLEE_ENV: $CALLEE_ENV_ERR" '{error: $e}'; exit 1; }
CALLEE_SETTINGS=$(callee_env_settings_json)

CWD=""
PROMPT=""
PROMPT_FILE=""
ALLOWED_TOOLS="Bash Read Edit Write Grep Glob"
# What this callee is DOING, for the tab label a tab/workspace placement creates.
# Never touches the agent name, which stays dir-slugged (claude-plugins-hukk).
LABEL=""
# The callee's `claude -n` session name — see CLAUDE_ARGS below for why it matters.
SESSION_NAME=""
BOOT_TIMEOUT=""
RESUME_ID=""
FORK_SESSION=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd)          CWD="$2";           shift 2 ;;
    --prompt)       PROMPT="$2";        shift 2 ;;
    --prompt-file)  PROMPT_FILE="$2";   shift 2 ;;
    --tools)        ALLOWED_TOOLS="$2"; shift 2 ;;
    --label)        LABEL="$2";         shift 2 ;;
    --name)         SESSION_NAME="$2";  shift 2 ;;
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

# WHERE THE CALLEE'S PANE LIVES. `split` is the default and stays byte-identical to
# what shipped: existing callers expect a sibling pane, and the cached-surface
# proofs re-target a pane split off the anchor. The other two exist because a split
# does not scale — an orchestrator dialling 15 callees off one pane produced one tab
# of 17 slivers, with the leftmost panes unreachable.
#   tab       — one tab per callee, in the workspace that owns the anchor pane.
#   workspace — one tab per callee inside a NAMED workspace, so a run's callees are
#               grouped and the orchestrator picks the label per group.
# Validated here, with the other usage errors: a typo must not cost a split pane.
HERDR_PLACEMENT="${HOTLINE_HERDR_PLACEMENT:-split}"
case "$HERDR_PLACEMENT" in
  split|tab|workspace) ;;
  *) die "HOTLINE_HERDR_PLACEMENT must be one of split|tab|workspace, got '$HERDR_PLACEMENT'" ;;
esac
if [[ "$HERDR_PLACEMENT" == "workspace" && -z "${HOTLINE_HERDR_WORKSPACE:-}" ]]; then
  die "HOTLINE_HERDR_PLACEMENT=workspace needs the group's label in HOTLINE_HERDR_WORKSPACE"
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
  if [[ -z "${HOTLINE_HERDR_KEEP_FAILED_PANE:-}" ]]; then
    # THE TAB, when we made one: closing only its root pane would leave an empty
    # tab in the sidebar, which is the clutter the tab placement exists to fix.
    # NEVER the workspace — a group workspace is shared, and this callee's siblings
    # are living in it.
    if [[ -n "${HOST_TAB:-}" ]]; then
      herdr_cli tab close "$HOST_TAB" >/dev/null 2>&1 || true
    elif [[ -n "${NEW_PANE:-}" ]]; then
      herdr_cli pane close "$NEW_PANE" >/dev/null 2>&1 || true
    fi
  fi
  jq -n --arg dir "$CALL_DIR" '{call_dir: $dir}'
  exit 0
}

# ---- Open the host: a pane in the callee's cwd, placed per $HERDR_PLACEMENT. ---
# --no-focus deliberately, for EVERY call including a conference: a callee whose
# REPL is still booting must not hold the user's cursor, or their next keystrokes
# land in it. A conference is focused later, by dial.sh, once the payload is
# confirmed in the callee's transcript.
NEW_PANE=""
HOST_TAB=""
HOST_WORKSPACE=""

if [[ "$HERDR_PLACEMENT" == "split" ]]; then
  SPLIT_DIRECTION="${HOTLINE_HERDR_SPLIT_DIRECTION:-right}"
  herdr_cli pane split --pane "$SPLIT_FROM" \
      --direction "$SPLIT_DIRECTION" --cwd "$CWD" --no-focus \
    || fail_async "herdr pane split from $SPLIT_FROM failed: ${HERDR_CLI_ERR:-no diagnostic}"
  NEW_PANE=$(jq -r '.result.pane.pane_id // empty' <<<"$HERDR_CLI_OUT" 2>/dev/null)
  [[ -z "$NEW_PANE" ]] && fail_async "herdr pane split returned no pane id: $(printf '%s' "$HERDR_CLI_OUT" | tr -d '\n' | cut -c1-200)"
else
  # WHICH WORKSPACE HOSTS THE TAB. For `tab`, the one that owns the anchor pane —
  # asked of herdr rather than parsed out of the pane id, which is opaque by
  # contract even though today's ids happen to be workspace-prefixed. For
  # `workspace`, the one carrying the caller's group label, created if no workspace
  # answers to it yet.
  if [[ "$HERDR_PLACEMENT" == "workspace" ]]; then
    herdr_cli workspace list \
      || fail_async "herdr workspace list failed, so the group '$HOTLINE_HERDR_WORKSPACE' could not be looked up: ${HERDR_CLI_ERR:-no diagnostic}"
    HOST_WORKSPACE=$(jq -r --arg l "$HOTLINE_HERDR_WORKSPACE" \
      'first(.result.workspaces[]? | select(.label == $l) | .workspace_id) // empty' \
      <<<"$HERDR_CLI_OUT" 2>/dev/null)
    if [[ -z "$HOST_WORKSPACE" ]]; then
      herdr_cli workspace create --label "$HOTLINE_HERDR_WORKSPACE" --cwd "$CWD" --no-focus \
        || fail_async "herdr workspace create --label $HOTLINE_HERDR_WORKSPACE failed: ${HERDR_CLI_ERR:-no diagnostic}"
      HOST_WORKSPACE=$(jq -r '.result.workspace.workspace_id // empty' <<<"$HERDR_CLI_OUT" 2>/dev/null)
      [[ -z "$HOST_WORKSPACE" ]] && fail_async "herdr workspace create returned no workspace id: $(printf '%s' "$HERDR_CLI_OUT" | tr -d '\n' | cut -c1-200)"
    fi
  else
    herdr_cli pane get "$SPLIT_FROM" \
      || fail_async "herdr pane get $SPLIT_FROM failed, so the workspace to host the callee's tab is unknown: ${HERDR_CLI_ERR:-no diagnostic}"
    HOST_WORKSPACE=$(jq -r '.result.pane.workspace_id // empty' <<<"$HERDR_CLI_OUT" 2>/dev/null)
    [[ -z "$HOST_WORKSPACE" ]] && fail_async "herdr pane get $SPLIT_FROM reported no workspace_id: $(printf '%s' "$HERDR_CLI_OUT" | tr -d '\n' | cut -c1-200)"
  fi

  # Shape and its reasoning live in herdr_tab_label (herdr-state.sh), which owns
  # the 20-character budget the README and SKILL.md describe in prose.
  #
  # HOTLINE_HERDR_TAB_LABEL still wins over --label. It sets the label VERBATIM,
  # nonce lead and all, which is the escape hatch for a caller who wants a shape
  # this does not offer; --label names the subject and gets the standard shape.
  TAB_LABEL="${HOTLINE_HERDR_TAB_LABEL:-}"
  if [[ -z "$TAB_LABEL" ]]; then
    TAB_LABEL=$(herdr_tab_label "${LABEL:-$(basename "$CWD")}" "$CALL_ID")
  fi

  herdr_cli tab create --workspace "$HOST_WORKSPACE" --cwd "$CWD" \
      --label "$TAB_LABEL" --no-focus \
    || fail_async "herdr tab create in workspace $HOST_WORKSPACE failed: ${HERDR_CLI_ERR:-no diagnostic}"
  # The tab's ROOT PANE is the host: `agent start` addresses a pane, and a fresh
  # tab has exactly one. (Verified on herdr 0.8.2 — `tab create` reports it at
  # .result.root_pane.pane_id and the tab at .result.tab.tab_id.)
  NEW_PANE=$(jq -r '.result.root_pane.pane_id // empty' <<<"$HERDR_CLI_OUT" 2>/dev/null)
  HOST_TAB=$(jq -r '.result.tab.tab_id // empty' <<<"$HERDR_CLI_OUT" 2>/dev/null)
  [[ -z "$NEW_PANE" ]] && fail_async "herdr tab create returned no root pane id, so there is nothing to start the callee in: $(printf '%s' "$HERDR_CLI_OUT" | tr -d '\n' | cut -c1-200)"
fi

# Recorded so a caller can label, move or close the callee's host later — the
# handles `pane move --workspace`, `tab close` and `workspace close` take. Written
# alongside herdr_pane.txt, and only when the placement actually made one, so their
# ABSENCE is what says "this callee is a split".
echo "$HERDR_PLACEMENT" > "$CALL_DIR/herdr_placement.txt"
echo "$NEW_PANE" > "$CALL_DIR/herdr_pane.txt"
[[ -n "$HOST_TAB"       ]] && echo "$HOST_TAB"       > "$CALL_DIR/herdr_tab.txt"
[[ -n "$HOST_WORKSPACE" ]] && echo "$HOST_WORKSPACE" > "$CALL_DIR/herdr_workspace.txt"

# ---- Start the agent. -------------------------------------------------------
# `agent start` requires the pane to be AT ITS INTERACTIVE SHELL PROMPT, and a
# freshly split pane needs a moment to get there. How long is not a constant: on a
# loaded box a shell's rc files take seconds, and four one-second attempts were not
# enough — the dial died `agent_pane_busy` with the pane still booting. So the wait
# is a POLL on herdr's own readiness signal, governed by one wall-clock budget, and
# the retries are left to cover only the residual race between reading readiness and
# acting on it.
SETTLE="${HOTLINE_HERDR_PANE_SETTLE:-1}"
START_ATTEMPTS="${HOTLINE_HERDR_START_ATTEMPTS:-4}"
START_BUDGET="${HOTLINE_HERDR_START_BUDGET:-30}"
READY_POLL="${HOTLINE_HERDR_READY_POLL:-0.5}"

# The claude argv, passed through verbatim after `--` (verified live on herdr
# 0.8.0). An ARRAY, not a string: herdr hands these to claude as argv elements, so
# nothing here needs shell quoting.
#
# --allowedTools stays in its `=`-joined ONE-WORD form for the same reason the cmux
# launcher documents: some recorders treat `--allowedTools` as arity-0 and drop the
# value that follows a space-separated form, which resurrects the callee later with
# a bare `--allowedTools` and no list. claude accepts either form.
#
# `-n <session-name>` is what puts the label on a SPLIT placement's pane. claude
# emits its session name as the terminal title, and herdr — like cmux — renders that
# live, so a pane with no tab of its own still reads `hotline: <label> (<mode>)`.
# Distinct from the herdr agent NAME, which carries the call's addressable identity
# in `herdr agent list` and stays dir-slugged (see AGENT_SLUG_TARGET below); a
# session name never reaches that field.
CLAUDE_ARGS=(--session-id "$SESSION_ID_PRESET")
[[ -n "$SESSION_NAME" ]] && CLAUDE_ARGS+=(-n "$SESSION_NAME")
[[ -n "${HOTLINE_CLAUDE_MODEL:-}" ]] && CLAUDE_ARGS+=(--model "$HOTLINE_CLAUDE_MODEL")
[[ -n "$CALLEE_SETTINGS" ]] && CLAUDE_ARGS+=(--settings "$CALLEE_SETTINGS")
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
# name ("hotline: <label> (<mode>)") is the whole string, so slugging it minted every
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
START_DEADLINE=$(( $(date +%s) + START_BUDGET ))
backoff="$SETTLE"
while [[ $attempt -lt $START_ATTEMPTS ]]; do
  attempt=$((attempt + 1))
  sleep "$backoff"

  # Wait for the shell, not for the clock. A herdr that cannot answer the question
  # (rc 2 — older build, unreadable pane) ends the poll immediately and leaves the
  # backoff below as the only guard, which is what shipped before this signal
  # existed; an unfalsifiable wait would be worse than a bounded retry. Running out
  # of budget also ends it and lets the start go ahead, because herdr's own refusal
  # is a better diagnostic than any this loop could invent.
  while :; do
    pane_ready=0; herdr_pane_shell_ready "$NEW_PANE" || pane_ready=$?
    [[ $pane_ready -ne 1 ]] && break
    [[ $(date +%s) -ge $START_DEADLINE ]] && break
    sleep "$READY_POLL"
  done

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
  [[ $(date +%s) -ge $START_DEADLINE ]] && break
  # Widening, so a pane that is slow rather than stuck gets progressively more room
  # without the attempt count having to grow. awk because SETTLE may be fractional.
  backoff=$(awk -v b="$backoff" 'BEGIN{ b *= 2; if (b > 4) b = 4; printf "%g", b }')
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
