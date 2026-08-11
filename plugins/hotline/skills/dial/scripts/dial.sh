#!/usr/bin/env bash
# =============================================================================
# Dial: one invocation for the whole outbound-call flow.
#
# Composes the existing dial scripts — identity (session-init.sh),
# resolve-workspace.sh, check-cmux.sh, session-cache.sh, the cmux/headless
# launchers, wait-for-session.sh — into a single call that emits ONE JSON
# object. Nothing below modifies those scripts; this is orchestration only.
#
# NORMALLY ONE CALL. On current Claude Code (>= 2.1.132) session-init.sh reads
# the native $CLAUDE_CODE_SESSION_ID and identity resolves inline; Codex callers
# resolve via $CODEX_THREAD_ID the same way. The whole flow completes in a
# single invocation.
#
# RE-ENTRANT FOR LEGACY CALLERS. On a pre-2.1.132 Claude (or a stripped
# environment) identity falls back to fingerprint discovery, which needs two
# tool calls: the fingerprint only lands in the transcript after a tool call
# RETURNS, so no single invocation can plant it and then grep for it. Instead of
# making that the model's problem, this script persists the pending fingerprint
# keyed by the claude PID and asks to be run again, verbatim:
#
#   native/override/codex/cache hit → the whole flow runs in one call
#   legacy cache miss → plant, persist, emit {"status":"replay", ...}, exit 2
#   re-run            → discover from the pending fingerprint, continue as above
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
#   replay               2   legacy fallback only: re-run this exact command to finish identity
#   needs_disambiguation 3   ask the user to pick from .candidates, re-run
#   error                1   .stage / .detail / .recovery say what and why
#
# DELIBERATELY NOT HERE: wait-for-response.sh. It is long-running (a work order
# can outlast a tool-call timeout) and the model must report the connection to
# the user BETWEEN boot and response. Run it as its own step, unchanged.
# =============================================================================
set -uo pipefail

if [[ "${1:-}" == "--help" ]]; then
  # Range ends at the header's own closing rule, so editing the header can't
  # start leaking source lines into --help.
  sed -n '2,/^# =\{10,\}$/p' "$0" | sed 's/^# \{0,1\}//' | grep -v '^=\{10,\}$'
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOTLINE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PLUGIN_SCRIPTS="$HOTLINE_ROOT/scripts"
DIAL_SCRIPTS="$SCRIPT_DIR"
PICKUP_SCRIPTS="$HOTLINE_ROOT/skills/pickup/scripts"

# Pending-fingerprint state. NOT in /tmp: the file is keyed by the claude PID, so
# a reused PID would inherit a dead session's fingerprint, and /tmp is
# world-writable with no GC. ~/.agents-hotline/ is where every other piece of
# hotline state already lives. Overridable so the test suite stays out of it.
PENDING_DIR="${HOTLINE_PENDING_DIR:-$HOME/.agents-hotline/pending}"
MAX_IDENTITY_ATTEMPTS=3
# A replay round-trip is seconds. Anything older is a leftover from a previous
# session (or a recycled PID), so it is discarded and the retry budget restarts
# rather than being inherited.
PENDING_TTL="${HOTLINE_PENDING_TTL:-600}"

# ---------------------------------------------------------------------------
# Output helpers. Every exit path goes through one of these, so stdout is always
# exactly one JSON object — including the argument-parsing errors below, which is
# why these are defined first.
# ---------------------------------------------------------------------------
FALLBACKS=()
CALL_DIR=""

# fb_json serializes one entry per line, so an entry must never contain a
# newline. cmux-reuse-surface.sh's refusal reasons can be multi-line, which
# silently split one fallback into several bogus array entries.
add_fallback() { FALLBACKS+=("$(printf '%s' "$1" | tr '\n\r\t' '   ')"); }

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

# Every flag that consumes a value. A trailing one of these used to hang the
# script forever: `shift 2` with a single arg left FAILS without shifting, and
# with no `set -e` the loop just spun on the same $1 at full CPU, emitting no
# JSON at all. Reachable from a plain `--prompt-file "$VAR"` with an empty VAR.
VALUE_FLAGS=" --target --mode --prompt-file --prompt --placement --window --tools --resume --caller-session --boot-timeout "
# --window is applied AFTER parsing (below) so it wins over --placement
# regardless of the order the two were given in.
WINDOW_REQUESTED=false

while [[ $# -gt 0 ]]; do
  if [[ "$VALUE_FLAGS" == *" $1 "* && $# -lt 2 ]]; then
    emit_error args "$1 needs a value, but nothing followed it" \
      "Pass a value after $1 — an empty shell variable is the usual cause — or drop the flag."
  fi
  case "$1" in
    --target)          TARGET_REF="$2";            shift 2 ;;
    --mode)            MODE_IN="$2";               shift 2 ;;
    --prompt-file)     PROMPT_FILE="$2";           HAVE_PROMPT=true; shift 2 ;;
    --prompt)          PROMPT_INLINE="$2";         HAVE_PROMPT=true; shift 2 ;;
    --placement)       PLACEMENT="$2";             shift 2 ;;
    --window)          WINDOW_REQUESTED=true; WINDOW_REF="$2"; shift 2 ;;
    --detached|--new-workspace) PLACEMENT="detached"; shift ;;
    --headless)        FORCE_HEADLESS=true;        shift ;;
    --tools)           TOOLS="$2";                 shift 2 ;;
    --resume)          RESUME_ARG="$2";            shift 2 ;;
    --no-fork)         NO_FORK=true;               shift ;;
    --caller-session)  CALLER_SESSION_ARG="$2";    shift 2 ;;
    --refresh-identity) REFRESH_IDENTITY=true;     shift ;;
    --boot-timeout)    BOOT_TIMEOUT="$2";          shift 2 ;;
    # Silently ignoring an unrecognized flag turns a typo into a wrong call:
    # `--prompt-fil /tmp/x` would dial with no message at all.
    *) emit_error args "Unrecognized argument: $1" \
         "dial.sh takes flags only, no positionals. Run dial.sh --help for the list." ;;
  esac
done

# --window implies the window placement and outranks --detached, per SKILL.md.
$WINDOW_REQUESTED && PLACEMENT="window"


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

if [[ -n "$BOOT_TIMEOUT" && ! "$BOOT_TIMEOUT" =~ ^[0-9]+$ ]]; then
  emit_error args "--boot-timeout must be a whole number of seconds, got '$BOOT_TIMEOUT'" \
    "wait-for-session.sh compares it arithmetically; a non-numeric value would break its poll loop."
fi

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
  if [[ -n "$CLAUDE_PID" ]]; then
    mkdir -p "$PENDING_DIR" 2>/dev/null
    PENDING_FILE="${PENDING_DIR}/hotline-pending-${CLAUDE_PID}"
  fi

  # A pending fingerprint means this is the re-run: the previous invocation's
  # output (which carried the fingerprint) is now in the transcript, so
  # discovery can find it.
  if [[ -n "$PENDING_FILE" && -s "$PENDING_FILE" ]]; then
    PENDING_FP=$(sed -n '1p' "$PENDING_FILE")
    PENDING_ATTEMPT=$(sed -n '2p' "$PENDING_FILE")
    PENDING_STAMP=$(sed -n '3p' "$PENDING_FILE")
    [[ "$PENDING_ATTEMPT" =~ ^[0-9]+$ ]] || PENDING_ATTEMPT=1
    [[ "$PENDING_STAMP" =~ ^[0-9]+$ ]] || PENDING_STAMP=0
    # Too old to be this dial's round-trip → a leftover, or a recycled PID
    # wearing a dead session's fingerprint. Discard it and start the retry
    # budget over rather than inheriting somebody else's attempt count.
    if [[ $(( $(date +%s) - PENDING_STAMP )) -gt $PENDING_TTL ]]; then
      rm -f "$PENDING_FILE"
      PENDING_FP=""
    fi
    DISC=""
    [[ -n "$PENDING_FP" ]] && \
      DISC=$(bash "$PLUGIN_SCRIPTS/session-init.sh" discover "$PENDING_FP" 2>/dev/null)
    if [[ "$(jq -r '.status // empty' <<<"$DISC" 2>/dev/null)" == "discovered" ]]; then
      MY_SESSION_ID=$(jq -r '.session_id' <<<"$DISC")
      CALLER_KIND="discovered"
      rm -f "$PENDING_FILE"
    elif [[ -z "$PENDING_FP" ]]; then
      : # expired pending, already removed — plant fresh at attempt 1
    else
      # Not in the transcript yet (or never will be). Drop the pending and fall
      # through to plant a fresh one — bounded, so we can't ping-pong.
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
          printf '%s\n%s\n%s\n' "$FP" "$IDENTITY_ATTEMPT" "$(date +%s)" > "$PENDING_FILE"
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

# Unconditional when asked. "Fresh" only means younger than the TTL, and a
# within-TTL identity can still be wrong — which is exactly the complaint that
# makes a caller pass this flag in the first place.
if $REFRESH_IDENTITY; then
  if bash "$DIAL_SCRIPTS/headless-call.sh" --cwd "$TARGET_PATH" \
       --prompt "/hotline:hotline-pickup --fresh" >/dev/null 2>"$ERR_FILE"; then
    add_fallback "identity→refreshed"
    # Re-resolve once: a refreshed identity can change what the reference
    # matches (that is the point of the refresh).
    if RERESOLVED=$(resolve_once); then
      TARGET_PATH="$RERESOLVED"
    fi
    bash "$PICKUP_SCRIPTS/identity-cache.sh" is-stale --cwd "$TARGET_PATH" >/dev/null 2>&1 \
      && IDENTITY_STALE=true || IDENTITY_STALE=false
  else
    add_fallback "identity→refresh-failed($(head -c 160 "$ERR_FILE" 2>/dev/null))"
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
  add_fallback "cmux-unavailable→headless"
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
  add_fallback "surface-reuse→fresh($(jq -r '.reason // "no reason given"' <<<"$REUSE" 2>/dev/null | tr '\n' ' ' | cut -c1-140))"
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
    add_fallback "cmux-cli-missing→headless"
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

    # Record the surface the conference session lives in. cmux-call.sh registers
    # the call itself but has no --surface to pass along, so without this a
    # conference follow-up finds no surface_ref, skips the reuse guard above, and
    # opens a SECOND surface resuming the session whose REPL is still live in the
    # first one. Re-`set` on first contact (the entry was just created, so
    # exchange_count 1 is right); `update` on a follow-up, whose raw message
    # carries no tags for cmux-call.sh to register from at all — so without this
    # last_contact and exchange_count would never move either.
    if $FIRST_CONTACT; then
      bash "$DIAL_SCRIPTS/session-cache.sh" set "$TARGET_PATH" \
        --caller-session "$MY_SESSION_ID" --session "$REMOTE_SESSION_ID" \
        --mode "$MODE_TAG" ${SURFACE_REF:+--surface "$SURFACE_REF"} >/dev/null 2>&1
    else
      bash "$DIAL_SCRIPTS/session-cache.sh" update "$TARGET_PATH" \
        --caller-session "$MY_SESSION_ID" \
        ${SURFACE_REF:+--surface "$SURFACE_REF"} >/dev/null 2>&1
    fi
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
    add_fallback "cmux-cli-missing→headless"
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
  add_fallback "surface-context→detached"
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
