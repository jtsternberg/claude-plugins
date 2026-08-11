#!/usr/bin/env bash
# =============================================================================
# Dial: one invocation for the whole outbound-call flow.
#
# Composes the existing dial scripts — identity (session-init.sh),
# resolve-workspace.sh, check-cmux.sh, session-cache.sh, the cmux/headless
# launchers, wait-for-session.sh — into a single call that emits ONE JSON
# object. Nothing below modifies those scripts; this is orchestration only.
#
# RE-ENTRANT BY DESIGN. Discovering our own session ID needs two tool calls in
# the worst case: the fingerprint only lands in the transcript after a tool call
# RETURNS, so no single invocation can plant it and then grep for it. Instead of
# making that the model's problem, this script persists the pending fingerprint
# keyed by the claude PID and asks to be run again, verbatim:
#
#   cache hit  → the whole flow runs in one call (the steady state)
#   cache miss → plant, persist, emit {"status":"replay", ...}, exit 2
#   re-run     → discover from the pending fingerprint, continue as above
#
# Usage:
#   dial.sh --target <reference> --mode quick|work_order|conference
#           (--prompt-file <path> | --prompt <text>)
#           [--placement side|detached|window] [--window <name|ref>]
#           [--headless] [--tools <list>]
#           [--resume <session-id> [--no-fork]]
#           [--caller-session <id>] [--refresh-identity]
#           [--boot-timeout <seconds>]
#
# --prompt-file is preferred: it keeps the message out of argv, so quoting,
# newlines and shell metacharacters are never in play.
#
# Statuses / exit codes (stdout is ALWAYS a single JSON object):
#   connected            0   call is live; wait for the response separately
#   replay               2   re-run this exact command to finish identity
#   needs_disambiguation 3   ask the user to pick from .candidates, re-run
#   error                1   .stage / .detail / .recovery say what and why
#
# DELIBERATELY NOT HERE: wait-for-response.sh. It is long-running (a work order
# can outlast a tool-call timeout) and the model must report the connection to
# the user BETWEEN boot and response. Run it as its own step, unchanged.
# =============================================================================
set -uo pipefail

if [[ "${1:-}" == "--help" ]]; then
  sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOTLINE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PLUGIN_SCRIPTS="$HOTLINE_ROOT/scripts"
DIAL_SCRIPTS="$SCRIPT_DIR"
PICKUP_SCRIPTS="$HOTLINE_ROOT/skills/pickup/scripts"

# Where the pending-fingerprint file lives. Overridable so the test suite never
# writes into a real /tmp slot that a live session might be using.
PENDING_DIR="${HOTLINE_PENDING_DIR:-/tmp}"
MAX_IDENTITY_ATTEMPTS=3

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
TARGET_REF=""
MODE_IN=""
PROMPT_FILE=""
PROMPT_INLINE=""
HAVE_PROMPT=false
PLACEMENT="side"
WINDOW_REF=""
FORCE_HEADLESS=false
TOOLS=""
RESUME_ARG=""
NO_FORK=false
CALLER_SESSION_ARG=""
REFRESH_IDENTITY=false
BOOT_TIMEOUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)          TARGET_REF="${2:-}";        shift 2 ;;
    --mode)            MODE_IN="${2:-}";           shift 2 ;;
    --prompt-file)     PROMPT_FILE="${2:-}";       HAVE_PROMPT=true; shift 2 ;;
    --prompt)          PROMPT_INLINE="${2:-}";     HAVE_PROMPT=true; shift 2 ;;
    --placement)       PLACEMENT="${2:-}";         shift 2 ;;
    --window)          PLACEMENT="window"; WINDOW_REF="${2:-}"; shift 2 ;;
    --detached|--new-workspace) PLACEMENT="detached"; shift ;;
    --headless)        FORCE_HEADLESS=true;        shift ;;
    --tools)           TOOLS="${2:-}";             shift 2 ;;
    --resume)          RESUME_ARG="${2:-}";        shift 2 ;;
    --no-fork)         NO_FORK=true;               shift ;;
    --caller-session)  CALLER_SESSION_ARG="${2:-}"; shift 2 ;;
    --refresh-identity) REFRESH_IDENTITY=true;     shift ;;
    --boot-timeout)    BOOT_TIMEOUT="${2:-}";      shift 2 ;;
    *) shift ;;
  esac
done

# ---------------------------------------------------------------------------
# Output helpers. Every exit path goes through one of these, so stdout is always
# exactly one JSON object.
# ---------------------------------------------------------------------------
FALLBACKS=()
CALL_DIR=""

fb_json() {
  if [[ ${#FALLBACKS[@]} -eq 0 ]]; then
    echo '[]'
  else
    printf '%s\n' "${FALLBACKS[@]}" | jq -Rsc 'split("\n")[:-1]'
  fi
}

emit_error() {  # emit_error <stage> <detail> <recovery>
  jq -n --arg stage "$1" --arg detail "$2" --arg recovery "$3" \
        --arg call_dir "$CALL_DIR" --argjson fallbacks "$(fb_json)" \
    '{status:"error", stage:$stage, detail:$detail, recovery:$recovery,
      fallbacks:$fallbacks}
     + (if $call_dir == "" then {} else {call_dir:$call_dir} end)'
  exit 1
}

# ---------------------------------------------------------------------------
# Validate arguments before doing anything with side effects.
# ---------------------------------------------------------------------------
case "$MODE_IN" in
  quick|quick_call)             MODE_TAG="quick_call" ;;
  work_order)                   MODE_TAG="work_order" ;;
  conference|conference_call)   MODE_TAG="conference_call" ;;
  "") emit_error args "No --mode provided" \
        "Pass --mode quick|work_order|conference (the model's judgment call, see SKILL.md)." ;;
  *)  emit_error args "Unknown --mode '$MODE_IN'" \
        "Valid modes: quick, work_order, conference." ;;
esac

case "$PLACEMENT" in
  side|detached) ;;
  window)
    [[ -z "$WINDOW_REF" ]] && emit_error args "--placement window needs --window <name|ref>" \
      "Pass --window <name|ref>, or drop to the default side-by-side placement." ;;
  *) emit_error args "Unknown --placement '$PLACEMENT'" \
       "Valid placements: side (default), detached, window." ;;
esac

if [[ -z "$TARGET_REF" && -n "$RESUME_ARG" ]]; then
  # Dialing a session ID the user handed us: the session ID is itself a
  # resolvable reference (resolve-workspace.sh reverse-looks-up its workspace).
  TARGET_REF="$RESUME_ARG"
fi
[[ -z "$TARGET_REF" ]] && emit_error args "No --target provided" \
  "Pass the user's exact words for the target as --target; do NOT pre-resolve it yourself."

if ! $HAVE_PROMPT; then
  emit_error args "No --prompt-file or --prompt provided" \
    "Write the message to a file and pass --prompt-file <path>."
fi
if [[ -n "$PROMPT_FILE" ]]; then
  [[ -f "$PROMPT_FILE" ]] || emit_error args "--prompt-file does not exist: $PROMPT_FILE" \
    "Write the message to that path first, then re-run."
  MESSAGE=$(cat "$PROMPT_FILE")
else
  MESSAGE="$PROMPT_INLINE"
fi
[[ -z "$MESSAGE" ]] && emit_error args "The message is empty" \
  "Put the task/question in --prompt-file (or --prompt) before dialing."

# ---------------------------------------------------------------------------
# Step 1 — Identity (re-entrant; see the header)
# ---------------------------------------------------------------------------
find_claude_pid() {
  local pid=$$ comm
  while [[ "$pid" != "1" && -n "$pid" ]]; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | xargs)
    # macOS `ps -o comm=` prints the full executable path, Linux the bare name.
    if [[ "${comm##*/}" == "claude" ]]; then printf '%s' "$pid"; return 0; fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
  return 1
}

MY_SESSION_ID=""
CALLER_KIND=""
IDENTITY_ATTEMPT=1

if [[ -n "$CALLER_SESSION_ARG" ]]; then
  MY_SESSION_ID="$CALLER_SESSION_ARG"
  CALLER_KIND="supplied"
else
  CLAUDE_PID="$(find_claude_pid || true)"
  PENDING_FILE=""
  [[ -n "$CLAUDE_PID" ]] && PENDING_FILE="${PENDING_DIR}/hotline-pending-${CLAUDE_PID}"

  # A pending fingerprint means this is the re-run: the previous invocation's
  # output (which carried the fingerprint) is now in the transcript, so
  # discovery can find it.
  if [[ -n "$PENDING_FILE" && -s "$PENDING_FILE" ]]; then
    PENDING_FP=$(sed -n '1p' "$PENDING_FILE")
    PENDING_ATTEMPT=$(sed -n '2p' "$PENDING_FILE")
    [[ "$PENDING_ATTEMPT" =~ ^[0-9]+$ ]] || PENDING_ATTEMPT=1
    DISC=$(bash "$PLUGIN_SCRIPTS/session-init.sh" discover "$PENDING_FP" 2>/dev/null)
    if [[ "$(jq -r '.status // empty' <<<"$DISC" 2>/dev/null)" == "discovered" ]]; then
      MY_SESSION_ID=$(jq -r '.session_id' <<<"$DISC")
      CALLER_KIND="discovered"
      rm -f "$PENDING_FILE"
    else
      # Not in the transcript yet (or never will be). Drop the stale pending and
      # fall through to plant a fresh one — bounded, so we can't ping-pong.
      rm -f "$PENDING_FILE"
      IDENTITY_ATTEMPT=$((PENDING_ATTEMPT + 1))
      if [[ $IDENTITY_ATTEMPT -gt $MAX_IDENTITY_ATTEMPTS ]]; then
        emit_error identity \
          "Planted a session fingerprint ${PENDING_ATTEMPT}× and never found it in the transcript: $(jq -r '.message // "discovery failed"' <<<"$DISC" 2>/dev/null)" \
          "Set HOTLINE_CALLER_SESSION_ID=<id> in the environment, or pass --caller-session <id>. Under Codex, confirm \$CODEX_THREAD_ID is set (see references/codex-caller.md)."
      fi
    fi
  fi

  if [[ -z "$MY_SESSION_ID" ]]; then
    INIT=$(bash "$PLUGIN_SCRIPTS/session-init.sh" 2>/dev/null)
    case "$(jq -r '.status // empty' <<<"$INIT" 2>/dev/null)" in
      cached)
        MY_SESSION_ID=$(jq -r '.session_id' <<<"$INIT")
        CALLER_KIND=$(jq -r '.caller_kind // "cached"' <<<"$INIT")
        ;;
      planted)
        FP=$(jq -r '.fingerprint' <<<"$INIT")
        if [[ -n "$PENDING_FILE" ]]; then
          printf '%s\n%s\n' "$FP" "$IDENTITY_ATTEMPT" > "$PENDING_FILE"
        fi
        # The fingerprint MUST appear in THIS invocation's output — that is how
        # it reaches the transcript for the re-run's grep to find.
        jq -n --arg fp "$FP" --argjson attempt "$IDENTITY_ATTEMPT" \
          '{status:"replay", fingerprint:$fp, attempt:$attempt,
            hint:"Run this exact dial.sh command again. The fingerprint above is now in the transcript; the re-run discovers the caller session ID from it and completes the call."}'
        exit 2
        ;;
      *)
        emit_error identity \
          "$(jq -r '.message // "session-init.sh produced no usable identity"' <<<"$INIT" 2>/dev/null)" \
          "Set HOTLINE_CALLER_SESSION_ID=<id> or pass --caller-session <id>. Under Codex, \$CODEX_THREAD_ID supplies identity automatically — confirm it is set."
        ;;
    esac
  fi
fi

MY_CWD=$(realpath "$(pwd)" 2>/dev/null || pwd)

# ---------------------------------------------------------------------------
# Step 2 — Resolve the target workspace
# ---------------------------------------------------------------------------
ERR_FILE=$(mktemp)
trap 'rm -f "$ERR_FILE"' EXIT

resolve_once() {
  bash "$DIAL_SCRIPTS/resolve-workspace.sh" "$TARGET_REF" \
    --caller-session "$MY_SESSION_ID" 2>"$ERR_FILE"
}

TARGET_PATH=""
if ! TARGET_PATH=$(resolve_once); then
  ERRTXT=$(cat "$ERR_FILE")
  # resolve-workspace.sh signals ambiguity with a candidates ARRAY on stderr.
  if jq -e 'type == "array"' <<<"$ERRTXT" >/dev/null 2>&1; then
    jq -n --argjson candidates "$ERRTXT" --arg ref "$TARGET_REF" \
          --arg caller_session "$MY_SESSION_ID" --argjson fallbacks "$(fb_json)" \
      '{status:"needs_disambiguation", reference:$ref, candidates:$candidates,
        caller_session_id:$caller_session, fallbacks:$fallbacks,
        hint:"Ask the user which candidate they meant, then re-run with --target <their chosen path>. If a candidate identity looks stale or empty, add --refresh-identity."}'
    exit 3
  fi
  emit_error resolve "$ERRTXT" \
    "Do not guess a path. Ask the user for the exact path or dirmap ID (\`dirmap list\`), then re-run with --target <path>."
fi

# Identity freshness of the RESOLVED target. Reported always (one cheap
# is-stale check); refreshed only on request, because the refresh is a real
# headless claude call — tens of seconds and programmatic-usage credit.
IDENTITY_STALE=false
if bash "$PICKUP_SCRIPTS/identity-cache.sh" is-stale --cwd "$TARGET_PATH" >/dev/null 2>&1; then
  IDENTITY_STALE=true
fi

if $IDENTITY_STALE && $REFRESH_IDENTITY; then
  if bash "$DIAL_SCRIPTS/headless-call.sh" --cwd "$TARGET_PATH" \
       --prompt "/hotline:hotline-pickup --fresh" >/dev/null 2>&1; then
    FALLBACKS+=("stale-identity→refreshed")
    # Re-resolve once: a refreshed identity can change what the reference
    # matches (that is the point of the refresh).
    if RERESOLVED=$(resolve_once); then
      TARGET_PATH="$RERESOLVED"
    fi
    bash "$PICKUP_SCRIPTS/identity-cache.sh" is-stale --cwd "$TARGET_PATH" >/dev/null 2>&1 \
      && IDENTITY_STALE=true || IDENTITY_STALE=false
  else
    FALLBACKS+=("stale-identity→refresh-failed")
  fi
fi

# ---------------------------------------------------------------------------
# Step 3 — Transport
# ---------------------------------------------------------------------------
TRANSPORT="cmux"
if $FORCE_HEADLESS; then
  TRANSPORT="headless"
elif ! bash "$DIAL_SCRIPTS/check-cmux.sh" >/dev/null 2>&1; then
  TRANSPORT="headless"
  FALLBACKS+=("cmux-unavailable→headless")
fi

# ---------------------------------------------------------------------------
# Step 4 — Existing session? (our own cache only — a user-supplied --resume is
# somebody else's session, which is the fork path, not a follow-up)
# ---------------------------------------------------------------------------
FIRST_CONTACT=true
REMOTE_SESSION_ID=""
SURFACE_REF=""
if [[ -z "$RESUME_ARG" ]]; then
  if CACHED=$(bash "$DIAL_SCRIPTS/session-cache.sh" get "$TARGET_PATH" \
                --caller-session "$MY_SESSION_ID" 2>/dev/null) && [[ -n "$CACHED" ]]; then
    FIRST_CONTACT=false
    REMOTE_SESSION_ID=$(jq -r '.session_id // empty' <<<"$CACHED")
    SURFACE_REF=$(jq -r '.surface_ref // empty' <<<"$CACHED")
  fi
fi

# Resume/fork semantics for the launchers:
#   user-supplied --resume  → fork by default (don't pollute their conversation);
#                             --no-fork means "contribute to that session".
#   our cached session      → plain resume, never fork (context continuity).
EFFECTIVE_RESUME=""
DO_FORK=false
if [[ -n "$RESUME_ARG" ]]; then
  EFFECTIVE_RESUME="$RESUME_ARG"
  $NO_FORK || DO_FORK=true
elif ! $FIRST_CONTACT; then
  EFFECTIVE_RESUME="$REMOTE_SESSION_ID"
fi

# First contact wraps the ringing slash command + protocol tags. Follow-ups send
# the raw message: the remote session already loaded the ringing skill, and
# re-invoking it would re-run first-contact setup.
if $FIRST_CONTACT; then
  SEND_PROMPT="/hotline:hotline-ringing [MODE: $MODE_TAG] [CALLER: $MY_CWD] [SESSION: $MY_SESSION_ID] $MESSAGE"
else
  SEND_PROMPT="$MESSAGE"
fi

SESSION_NAME="hotline: $(basename "$MY_CWD") → $(basename "$TARGET_PATH") ($MODE_TAG)"

PLACEMENT_ARGS=()
case "$PLACEMENT" in
  detached) PLACEMENT_ARGS=(--detached) ;;
  window)   PLACEMENT_ARGS=(--window "$WINDOW_REF") ;;
esac
PLACEMENT_EFFECTIVE="$PLACEMENT"

emit_connected() {  # emit_connected <awaiting_response:true|false>
  jq -n \
    --arg caller_session "$MY_SESSION_ID" \
    --arg caller_kind "$CALLER_KIND" \
    --arg workspace "$TARGET_PATH" \
    --arg mode "$MODE_TAG" \
    --arg transport "$TRANSPORT" \
    --arg placement "$PLACEMENT_EFFECTIVE" \
    --arg remote_session "$REMOTE_SESSION_ID" \
    --arg call_dir "$CALL_DIR" \
    --arg surface "$SURFACE_REF" \
    --arg call_id "$CALL_ID_OUT" \
    --argjson first_contact "$FIRST_CONTACT" \
    --argjson identity_stale "$IDENTITY_STALE" \
    --argjson awaiting "$1" \
    --argjson fallbacks "$(fb_json)" \
    '{status:"connected", caller_session_id:$caller_session, caller_kind:$caller_kind,
      workspace:$workspace, mode:$mode, transport:$transport, placement:$placement,
      first_contact:$first_contact, remote_session_id:$remote_session,
      identity_stale:$identity_stale, awaiting_response:$awaiting,
      fallbacks:$fallbacks}
     + (if $call_dir == "" then {} else {call_dir:$call_dir} end)
     + (if $surface  == "" then {} else {surface_ref:$surface} end)
     + (if $call_id  == "" then {} else {call_id:$call_id} end)'
  exit 0
}
CALL_ID_OUT=""

# ---------------------------------------------------------------------------
# Step 5a — Follow-up into the surface the session already lives in.
#
# Preferred whenever it applies: the surface holds a live REPL for that exact
# session, so we type the next message into it instead of stacking a new
# surface per turn. Multi-line messages skip this deliberately — the fresh
# path hands the prompt to a launch script as an argument, so no keystroke
# simulation is involved.
# ---------------------------------------------------------------------------
if ! $FIRST_CONTACT && [[ "$TRANSPORT" == "cmux" && -n "$SURFACE_REF" && "$MESSAGE" != *$'\n'* ]]; then
  REUSE=$(bash "$DIAL_SCRIPTS/cmux-reuse-surface.sh" \
    --surface "$SURFACE_REF" --session "$REMOTE_SESSION_ID" \
    --prompt "$SEND_PROMPT" --cwd "$TARGET_PATH" 2>/dev/null)
  REUSE_DIR=$(jq -r '.call_dir // empty' <<<"$REUSE" 2>/dev/null)
  if [[ -n "$REUSE_DIR" ]]; then
    CALL_DIR="$REUSE_DIR"
    [[ -s "$CALL_DIR/call_id.txt" ]] && CALL_ID_OUT=$(cat "$CALL_DIR/call_id.txt")
    # The reused surface is unchanged, but bump last_contact / exchange_count.
    bash "$DIAL_SCRIPTS/session-cache.sh" update "$TARGET_PATH" \
      --caller-session "$MY_SESSION_ID" --surface "$SURFACE_REF" >/dev/null 2>&1
    emit_connected true
  fi
  # {"fallback":"fresh"} — surface gone, or not accepting the message right now.
  FALLBACKS+=("surface-reuse→fresh($(jq -r '.reason // "no reason given"' <<<"$REUSE" 2>/dev/null | cut -c1-120))")
  SURFACE_REF=""
fi

# ---------------------------------------------------------------------------
# Step 5b — Conference mode: a visible interactive session, handed to the user.
# cmux-call.sh is synchronous and self-registers, so we early-return after it —
# no boot wait, no response wait. (Headless conference falls through to the
# async path below; there is no visible surface to hand over.)
# ---------------------------------------------------------------------------
if [[ "$MODE_TAG" == "conference_call" && "$TRANSPORT" == "cmux" ]]; then
  CONF_ARGS=(--cwd "$TARGET_PATH")
  $FIRST_CONTACT && CONF_ARGS+=(--name "$SESSION_NAME")
  CONF_ARGS+=(${PLACEMENT_ARGS[@]+"${PLACEMENT_ARGS[@]}"})
  [[ -n "$EFFECTIVE_RESUME" ]] && CONF_ARGS+=(--resume "$EFFECTIVE_RESUME")
  $DO_FORK && CONF_ARGS+=(--fork-session)
  [[ -n "$TOOLS" ]] && CONF_ARGS+=(--tools "$TOOLS")
  CONF_ARGS+=(--prompt "$SEND_PROMPT")

  CONF=$(bash "$DIAL_SCRIPTS/cmux-call.sh" "${CONF_ARGS[@]}" 2>"$ERR_FILE")
  CONF_FALLBACK=$(jq -r '.fallback // empty' <<<"$CONF" 2>/dev/null)
  CONF_ERROR=$(jq -r '.error // empty' <<<"$CONF" 2>/dev/null)

  if [[ "$CONF_FALLBACK" == "headless" ]]; then
    # cmux is up but cmux-cli isn't installed, so side-by-side placement is
    # unavailable. Re-route through headless rather than bouncing to the model.
    FALLBACKS+=("cmux-cli-missing→headless")
    TRANSPORT="headless"
  elif [[ -n "$CONF_ERROR" ]]; then
    emit_error fire "$CONF_ERROR" \
      "See references/error-recovery.md § CMUX Failures. Retry with --placement detached, or force headless with --headless."
  elif [[ -z "$CONF" ]]; then
    emit_error fire "cmux-call.sh produced no output: $(cat "$ERR_FILE")" \
      "Retry with --placement detached, or force headless with --headless."
  else
    REMOTE_SESSION_ID=$(jq -r '.session_id // empty' <<<"$CONF")
    SURFACE_REF=$(jq -r '.surface_id // .surface_ref // empty' <<<"$CONF")
    [[ "$SURFACE_REF" == "null" ]] && SURFACE_REF=""
    PLACEMENT_EFFECTIVE=$(jq -r '.placement // empty' <<<"$CONF")
    [[ "$PLACEMENT_EFFECTIVE" == "workspace" ]] && PLACEMENT_EFFECTIVE="detached"
    [[ "$PLACEMENT_EFFECTIVE" == "surface" ]] && PLACEMENT_EFFECTIVE="$PLACEMENT"
    emit_connected false
  fi
fi

# ---------------------------------------------------------------------------
# Step 5c — Fire asynchronously (quick calls, work orders, headless conference)
# ---------------------------------------------------------------------------
fire_headless() {
  local ARGS=(--cwd "$TARGET_PATH")
  $FIRST_CONTACT && ARGS+=(--name "$SESSION_NAME")
  [[ -n "$EFFECTIVE_RESUME" ]] && ARGS+=(--resume "$EFFECTIVE_RESUME")
  $DO_FORK && ARGS+=(--fork-session)
  [[ -n "$TOOLS" ]] && ARGS+=(--tools "$TOOLS")
  ARGS+=(--prompt "$SEND_PROMPT")
  bash "$DIAL_SCRIPTS/headless-call-async.sh" "${ARGS[@]}" 2>"$ERR_FILE"
}

fire_cmux() {
  local ARGS=(--cwd "$TARGET_PATH")
  $FIRST_CONTACT && ARGS+=(--name "$SESSION_NAME")
  ARGS+=(${PLACEMENT_ARGS[@]+"${PLACEMENT_ARGS[@]}"})
  [[ -n "$EFFECTIVE_RESUME" ]] && ARGS+=(--resume "$EFFECTIVE_RESUME")
  $DO_FORK && ARGS+=(--fork-session)
  [[ -n "$TOOLS" ]] && ARGS+=(--tools "$TOOLS")
  ARGS+=(--prompt "$SEND_PROMPT")
  bash "$DIAL_SCRIPTS/cmux-call-async.sh" "${ARGS[@]}" 2>"$ERR_FILE"
}

if [[ "$TRANSPORT" == "cmux" ]]; then
  CALL_RESULT=$(fire_cmux)
  if [[ "$(jq -r '.fallback // empty' <<<"$CALL_RESULT" 2>/dev/null)" == "headless" ]]; then
    FALLBACKS+=("cmux-cli-missing→headless")
    TRANSPORT="headless"
    CALL_RESULT=$(fire_headless)
  fi
else
  CALL_RESULT=$(fire_headless)
fi

CALL_DIR=$(jq -r '.call_dir // empty' <<<"$CALL_RESULT" 2>/dev/null)
if [[ -z "$CALL_DIR" ]]; then
  LAUNCH_ERR=$(jq -r '.error // empty' <<<"$CALL_RESULT" 2>/dev/null)
  [[ -z "$LAUNCH_ERR" ]] && LAUNCH_ERR="launcher returned no call_dir: ${CALL_RESULT:-<no stdout>} $(cat "$ERR_FILE")"
  emit_error fire "$LAUNCH_ERR" \
    "See references/error-recovery.md. A --fork-session/--resume mismatch, a bad --cwd, or an unavailable transport are the usual causes."
fi

# cmux-call-async.sh degrades side-by-side to a detached workspace when the
# caller's own surface context can't be resolved. It signals that structurally:
# workspace_ref.txt instead of surface_ref.txt.
if [[ "$TRANSPORT" == "cmux" && "$PLACEMENT" == "side" \
      && -f "$CALL_DIR/workspace_ref.txt" && ! -f "$CALL_DIR/surface_ref.txt" ]]; then
  FALLBACKS+=("surface-context→detached")
  PLACEMENT_EFFECTIVE="detached"
fi
[[ "$TRANSPORT" == "headless" ]] && PLACEMENT_EFFECTIVE="none"
[[ -s "$CALL_DIR/call_id.txt" ]] && CALL_ID_OUT=$(cat "$CALL_DIR/call_id.txt")

# ---------------------------------------------------------------------------
# Step 6 — Wait for the callee's REPL to boot (registration happens inside)
# ---------------------------------------------------------------------------
WAIT_ARGS=("$CALL_DIR")
[[ -n "$BOOT_TIMEOUT" ]] && WAIT_ARGS+=(--timeout "$BOOT_TIMEOUT")
if ! REMOTE_SESSION_ID=$(bash "$DIAL_SCRIPTS/wait-for-session.sh" "${WAIT_ARGS[@]}" 2>"$ERR_FILE"); then
  emit_error boot "$(cat "$ERR_FILE")" \
    "The callee's claude REPL never came up. Read \$call_dir/error.txt and surface_err.txt; see references/error-recovery.md § CMUX Failures. Do NOT silently re-dial."
fi

[[ -s "$CALL_DIR/surface_ref.txt" ]] && SURFACE_REF=$(cat "$CALL_DIR/surface_ref.txt")

# Follow-ups that had to open a NEW surface: refresh the cached surface_ref so
# the next follow-up reuses the live one instead of the dead one. (First contact
# is registered by wait-for-session.sh → register-call.sh.)
if ! $FIRST_CONTACT; then
  bash "$DIAL_SCRIPTS/session-cache.sh" update "$TARGET_PATH" \
    --caller-session "$MY_SESSION_ID" \
    ${SURFACE_REF:+--surface "$SURFACE_REF"} >/dev/null 2>&1
fi

emit_connected true
