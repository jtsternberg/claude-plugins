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
#           [--transport cmux|herdr|headless] [--headless] [--tools <list>]
#           [--resume <session-id> [--no-fork]] [--fresh]
#           [--caller-session <id>] [--refresh-identity]
#           [--boot-timeout <seconds>]
#
# --transport picks the multiplexer that HOSTS the callee. cmux is the default and
# nothing about it changes; `herdr` is opt-in and, for now, detached-and-local only
# (see the rejections in the validation block below). A requested herdr that fails
# preflight is an ERROR, never a silent fall-back to cmux: a caller who asked for
# herdr asked for a callee that survives disconnects, and quietly giving them one
# that does not is worse than saying no.
#
# --prompt-file is preferred: it keeps the message out of argv, so quoting,
# newlines and shell metacharacters are never in play.
#
# --fresh ignores this caller's cached session AND cached surface for the resolved
# target, so the dial opens a BRAND-NEW callee session instead of resuming the one
# a previous dial left behind — the flag for a phase that must not inherit the
# previous phase's context (a "reviewer" that would otherwise be the implementer
# resumed). The cache is rewritten to the new session, and the surface this dial
# supersedes goes through the same proofs and guards a follow-up's would.
# Contradicts --resume, which names a specific session to continue.
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

# Reading the cmux tree lives in exactly one place (see the header there). dial.sh
# needs it to find the surface inside a workspace-addressed call.
# shellcheck source=../../../scripts/repl-state.sh
source "$PLUGIN_SCRIPTS/repl-state.sh"

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

# A sub-script's reason string, flattened for embedding INSIDE a fallback entry's
# parentheses. The trailing trim matters because the collapse turns jq's trailing
# newline into a space, and the space would otherwise land mid-entry as
# `surface-cleanup-skipped(disabled )` where add_fallback can no longer see it.
#
# The cut is 300, not 140. A refusal reason states the problem and then what to do
# about it, in that order — so a cut tight enough to keep an entry to one terminal
# line keeps only the half the reader cannot act on. 140 severed
# `herdr agent attach <name>` off the blocked reason, which was the entire point of
# reporting the state (claude-plugins-7wze.13). A bound is still wanted: these
# strings end up inside a JSON array a caller reads, and one runaway diagnostic
# should not be the whole payload.
reason_of() {  # reason_of <json>
  jq -r '.reason // "no reason given"' <<<"${1:-}" 2>/dev/null \
    | tr '\n\r\t' '   ' | cut -c1-300 | sed 's/[[:space:]]*$//'
}

fb_json() {
  if [[ ${#FALLBACKS[@]} -eq 0 ]]; then
    echo '[]'
  else
    printf '%s\n' "${FALLBACKS[@]}" | jq -Rsc 'split("\n")[:-1]'
  fi
}

# The optional 4th argument is a JSON OBJECT merged into the payload. It exists so a
# recovery string can tell the model to read a field that is actually there: the herdr
# delivery error's advice turns on `sent`, and forwarding it beats asking the model to
# consult a result it never sees.
emit_error() {  # emit_error <stage> <detail> <recovery> [<extra-json-object>]
  jq -n --arg stage "$1" --arg detail "$2" --arg recovery "$3" \
        --arg call_dir "$CALL_DIR" --argjson fallbacks "$(fb_json)" \
        --argjson extra "${4:-{\}}" \
    '{status:"error", stage:$stage, detail:$detail, recovery:$recovery,
      fallbacks:$fallbacks}
     + (if $call_dir == "" then {} else {call_dir:$call_dir} end)
     + $extra'
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
# Which backend the caller ASKED for, "" when they did not ask. Kept separate from
# the resolved TRANSPORT so the selection block can tell "the caller demanded herdr"
# (a preflight failure is an error) from "we chose cmux ourselves" (a preflight
# failure is a degrade).
TRANSPORT_REQ=""
REMOTE_TARGET=""
TOOLS=""
RESUME_ARG=""
NO_FORK=false
FRESH=false
CALLER_SESSION_ARG=""
REFRESH_IDENTITY=false
BOOT_TIMEOUT=""

# Every flag that consumes a value. A trailing one of these used to hang the
# script forever: `shift 2` with a single arg left FAILS without shifting, and
# with no `set -e` the loop just spun on the same $1 at full CPU, emitting no
# JSON at all. Reachable from a plain `--prompt-file "$VAR"` with an empty VAR.
VALUE_FLAGS=" --target --mode --prompt-file --prompt --placement --window --transport --remote --tools --resume --caller-session --boot-timeout "
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
    --transport)       TRANSPORT_REQ="$2";         shift 2 ;;
    # Accepted so the refusal below can EXPLAIN itself. Left out of the parser it
    # would land in the unrecognized-argument catch-all, which tells a caller their
    # flag was a typo when in fact it names an unimplemented phase.
    --remote)          REMOTE_TARGET="$2";         shift 2 ;;
    --headless)        FORCE_HEADLESS=true;        shift ;;
    --tools)           TOOLS="$2";                 shift 2 ;;
    --resume)          RESUME_ARG="$2";            shift 2 ;;
    --no-fork)         NO_FORK=true;               shift ;;
    --fresh)           FRESH=true;                 shift ;;
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

# --- Transport request, validated BEFORE anything has a side effect ----------
# Every refusal here is a REFUSAL, not a downgrade. `--transport herdr` is an
# explicit ask for a specific hosting model, and the combinations below are not
# things hotline can approximate: silently giving the caller side-by-side cmux when
# they asked for a callee that outlives a disconnect would be a lie that only shows
# up hours later. Each message names the phase that will lift the restriction so the
# refusal is actionable rather than final.
case "$TRANSPORT_REQ" in
  ""|cmux)  ;;
  # The same destination as --headless, so it goes through the same variable
  # rather than becoming a second way to say it.
  headless) FORCE_HEADLESS=true ;;
  herdr)
    # Two explicit, incompatible asks. Letting either win silently discards a flag
    # the caller typed on purpose: headless would drop the persistence they wanted,
    # herdr would drop the `claude -p` output they wanted. Neither is ours to pick.
    # (An ambient HOTLINE_FORCE_HEADLESS is a different case: a per-call --transport
    # outranks an environment default, and .transport reports what actually ran.)
    if $FORCE_HEADLESS; then
      emit_error args \
        "--headless and --transport herdr ask for different backends" \
        "Pick one: --headless for \`claude -p\`'s structured output, or --transport herdr --detached for a callee that survives a disconnect. They cannot both apply to one dial."
    fi
    if $WINDOW_REQUESTED || [[ "$PLACEMENT" != "detached" ]]; then
      emit_error args \
        "--transport herdr supports --placement detached only, got '$([[ $WINDOW_REQUESTED == true ]] && echo window || echo "$PLACEMENT")'" \
        "herdr hosts a callee in its own persistent pane; it has no side-by-side-in-your-window placement (its equivalent is \`herdr session attach\`, which is Phase 3). Re-dial as: --transport herdr --detached. Or drop --transport to use the cmux default, which does support side and window placements."
    fi
    if [[ "$MODE_TAG" == "conference_call" ]]; then
      emit_error args \
        "--transport herdr does not support --mode conference" \
        "A conference call hands the user a VISIBLE session next to their own; herdr's equivalent is attach-in-place (\`herdr session attach\`), which is Phase 3. Use --mode work_order or quick with herdr, or drop --transport for a cmux conference."
    fi
    # --resume names SOMEBODY ELSE's session — the fork path, not a follow-up — and
    # herdr cannot re-host one at all: `claude --resume` and `--session-id` are
    # mutually exclusive, and without the preset there is no transcript path to read
    # the answer from. Following up into a callee THIS caller already dialed is a
    # different thing and needs no flag (the cache holds the agent name); this
    # refusal is about adopting a session hotline did not start.
    if [[ -n "$RESUME_ARG" ]]; then
      emit_error args \
        "--transport herdr cannot adopt an existing session (--resume)" \
        "herdr hosts a callee it STARTS, with a session id hotline presets so the transcript is readable; \`claude --resume\` cannot take that preset. To continue a session you dialed before, just re-dial the same target with --transport herdr --detached and no --resume — the cached herdr agent is re-targeted by name. To adopt an unrelated session id, drop --transport and resume over cmux."
    fi
    ;;
  *)
    emit_error args "Unknown --transport '$TRANSPORT_REQ'" \
      "Valid transports: cmux (default), herdr (detached, local, opt-in), headless." ;;
esac

# --remote names a box hotline cannot yet reach. herdr is the only backend that
# COULD host remotely at all (cmux and `claude -p` are local by construction), and
# even for herdr the blocker is not the launch — it is the response: the callee's
# transcript would live on the remote filesystem, out of reach of the local
# transcript reader that every answer in hotline comes from. Refusing is the honest
# move; the alternative is a call that connects and can never be read.
if [[ -n "$REMOTE_TARGET" ]]; then
  if [[ "$TRANSPORT_REQ" == "herdr" ]]; then
    emit_error args \
      "--transport herdr --remote is not implemented (Phase 3)" \
      "herdr can host a callee on a remote box, but its transcript lives THERE and hotline reads answers from the local ~/.claude/projects tree — remote transcript access is the open question Phase 3 resolves. Dial the remote workspace locally, or run hotline on that box."
  fi
  emit_error args \
    "--remote is not supported by any hotline transport" \
    "cmux surfaces and \`claude -p\` are local by construction; remote hosting is herdr-only and unimplemented (Phase 3). Drop --remote."
fi

if [[ -n "$BOOT_TIMEOUT" && ! "$BOOT_TIMEOUT" =~ ^[0-9]+$ ]]; then
  emit_error args "--boot-timeout must be a whole number of seconds, got '$BOOT_TIMEOUT'" \
    "wait-for-session.sh compares it arithmetically; a non-numeric value would break its poll loop."
fi

# Caught here, not at the launcher, because a missing system-prompt file on the
# cmux path is otherwise an opaque boot timeout (claude exits before its REPL
# ever draws), and on the headless path a launch error the model has to dig for.
# The caller owns this file; it must stay readable until the callee boots.
if [[ -n "${HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE:-}" \
      && ! -r "$HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE" ]]; then
  emit_error args \
    "HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE points to a file that is not readable: $HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE" \
    "Write the system prompt to that path first, or unset the variable to dial with the callee's default system prompt."
fi

# Two opposite instructions about which session to talk to. Resolving it either way
# silently would give the caller the one they did not ask for, and --fresh exists
# precisely because a silently-resumed session is expensive to notice.
if $FRESH && [[ -n "$RESUME_ARG" ]]; then
  emit_error args "--fresh and --resume contradict each other" \
    "--fresh means 'start a new callee session'; --resume <id> names one to continue. Pass one or the other."
fi

# The box wait, resolved ONCE here and threaded to every delivery site.
#
# Two waits, one event: wait-for-session.sh waits for the callee's REPL to exist,
# and cmux-paste.sh waits for its input box to be drawn. So --boot-timeout governs
# both — a caller who raised it for a slow machine meant both. The final default is
# the shared HOTLINE_BOOT_TIMEOUT_CMUX from repl-state.sh, which is also what
# wait-for-session.sh falls back to: the documented 60 now has ONE definition. The
# old code read ${BOOT_TIMEOUT:-20} against an unset variable, so the real default
# was 20 while the docs promised 60.
PASTE_BOX_TIMEOUT="${HOTLINE_PASTE_BOX_TIMEOUT:-${BOOT_TIMEOUT:-$HOTLINE_BOOT_TIMEOUT_CMUX}}"

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
  # The callee's system-prompt override is for the user's delegated work, not for
  # hotline's own identity plumbing — this pickup is a throwaway internal call, so
  # unset the knob for it rather than steering a mechanical /hotline-pickup.
  if HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE= \
     bash "$DIAL_SCRIPTS/headless-call.sh" --cwd "$TARGET_PATH" \
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
# Precedence, first match wins:
#   1. --headless            → headless                          (unchanged)
#   2. --transport herdr     → herdr, or ERROR
#   3. otherwise             → cmux, with the existing cmux→headless degrade chain,
#                              unchanged — and that chain is where
#                              HOTLINE_FORCE_HEADLESS acts, via check-cmux.sh.
#
# WHERE HOTLINE_FORCE_HEADLESS SITS, precisely: it is read by check-cmux.sh, which
# only step 3 calls. So it forces headless for every dial that does NOT name a
# transport, and an explicit `--transport herdr` outranks it — a per-call flag beats
# an ambient default, and `.transport` reports what actually ran. That is deliberate:
# the alternative is a second copy of that variable's semantics here, which is how a
# constant with two definitions ends up disagreeing with itself. `--headless`
# together with `--transport herdr` is refused outright in the validation block
# above, because there both asks are explicit and neither is ours to discard.
#
# HERDR IS NEVER AUTO-SELECTED. Being inside a herdr pane (HERDR_ENV=1) or having a
# herdr server up makes herdr *available*, and that is all it does: flipping the
# default away from cmux on an ambient signal would surprise every interactive local
# caller, whose whole reason for using hotline is a callee they can watch. So the
# preflight reads that environment, and only the explicit flag selects from it.
TRANSPORT="cmux"
if $FORCE_HEADLESS; then
  TRANSPORT="headless"
elif [[ "$TRANSPORT_REQ" == "herdr" ]]; then
  # An explicit ask, so a failed preflight is an ERROR with guidance — NOT a quiet
  # degrade to cmux (the caller wanted persistence) and not to headless either
  # (headless has no live host to follow up into at all). check-herdr.sh reports the
  # reason and the recovery; both are passed through verbatim rather than
  # re-summarised here, because it knows which of the three checks failed.
  HERDR_PRE=$(bash "$DIAL_SCRIPTS/check-herdr.sh" 2>/dev/null)
  if [[ "$(jq -r '.usable // false' <<<"$HERDR_PRE" 2>/dev/null)" == "true" ]]; then
    TRANSPORT="herdr"
  else
    emit_error transport \
      "$(jq -r '.reason // "check-herdr.sh produced no usable answer"' <<<"$HERDR_PRE" 2>/dev/null)" \
      "$(jq -r '.recovery // "Run check-herdr.sh directly to see what it reports."' <<<"$HERDR_PRE" 2>/dev/null)"
  fi
elif ! bash "$DIAL_SCRIPTS/check-cmux.sh" >/dev/null 2>&1; then
  TRANSPORT="headless"
  add_fallback "cmux-unavailable→headless"
else
  # Capability preflight — ONE system.capabilities call over the control socket.
  # Every cmux delivery, first contact and follow-up alike, is a terminal.paste;
  # a cmux too old to advertise it (or a socket we cannot reach) cannot carry a
  # hotline call at all, so the honest move is to say so here rather than open a
  # pane and discover it after the REPL has booted.
  #
  # Headless is the ONLY fallback here, deliberately. Every cmux path carries the
  # payload over the socket, so there is no paste-free cmux delivery left to degrade
  # to; the alternatives would be launching claude with the payload on its argv,
  # which publishes the work order to any local `ps` (claude-plugins-86ka), or
  # opening a pane nothing can speak to. Losing the visible pane is the cheaper
  # loss, and .fallbacks says so.
  #
  # The capability list to read is result.methods. result.capabilities is a
  # different list (*.v1 feature tokens) and never contains terminal.paste —
  # checking the wrong one would degrade every call on a cmux that supports it.
  #
  # FOUR DISTINCT REASONS, not one. The first version of this check swallowed
  # everything through `2>/dev/null || true` and reported it all as
  # terminal-paste-unavailable, which sends a reader to upgrade cmux when the real
  # problem is a missing python3 or a socket nobody is listening on. Each of these
  # needs a different action, so each gets its own fallback string and the RPC's
  # own stderr rides along.
  if ! command -v python3 >/dev/null 2>&1; then
    TRANSPORT="headless"
    add_fallback "python3-missing→headless"
  else
    CAP_ERR=$(mktemp)
    CAPS=$(python3 "$PLUGIN_SCRIPTS/cmux-rpc.py" --method system.capabilities 2>"$CAP_ERR")
    CAP_RC=$?
    CAP_DIAG=$(tr '\n\r\t' '   ' < "$CAP_ERR" | cut -c1-140 | sed 's/[[:space:]]*$//')
    rm -f "$CAP_ERR"
    case "$CAP_RC" in
      0)
        if ! jq -e '.result.methods // [] | index("terminal.paste")' <<<"$CAPS" >/dev/null 2>&1; then
          TRANSPORT="headless"
          add_fallback "terminal-paste-unavailable→headless(cmux answered but does not list terminal.paste in result.methods)"
        fi
        ;;
      3)
        # No socket, refused connection, timeout, or a reply that was not JSON.
        TRANSPORT="headless"
        add_fallback "cmux-socket-unreachable→headless($CAP_DIAG)"
        ;;
      *)
        # ok:false, or a usage error in the helper itself.
        TRANSPORT="headless"
        add_fallback "cmux-rpc-error→headless(rc=$CAP_RC $CAP_DIAG)"
        ;;
    esac
  fi
fi

# ---------------------------------------------------------------------------
# Step 4 — Existing session? (our own cache only — a user-supplied --resume is
# somebody else's session, which is the fork path, not a follow-up)
#
# --fresh still READS the entry, and declines to use it. The PREV_* refs have to
# come from somewhere for step 7 to close the surface this dial supersedes, while
# FIRST_CONTACT staying true is what keeps the abandoned session out of
# EFFECTIVE_RESUME and out of the reuse guard — and what routes the cache write
# through register-call.sh's `set`, which replaces the entry with the new session
# rather than bumping the old one's exchange count.
# ---------------------------------------------------------------------------
FIRST_CONTACT=true
REMOTE_SESSION_ID=""
SURFACE_REF=""
# The surface (and nonce) this session was living in BEFORE this dial. Kept
# separately because SURFACE_REF is reassigned as soon as a new surface opens, and
# superseded-surface cleanup needs to know what it replaced.
PREV_SURFACE_REF=""
PREV_CALL_ID=""
# The callee session this target was cached with. Kept because a follow-up can end
# up on a DIFFERENT session than the cached one — a herdr follow-up whose agent has
# died falls back to a fresh launch, and herdr cannot re-host an existing session,
# so the new callee has a new id. Step 6 compares the two and heals the cache when
# they differ; a cmux follow-up resumes the same id, so nothing there changes.
PREV_SESSION_ID=""
if [[ -z "$RESUME_ARG" ]]; then
  if CACHED=$(bash "$DIAL_SCRIPTS/session-cache.sh" get "$TARGET_PATH" \
                --caller-session "$MY_SESSION_ID" 2>/dev/null) && [[ -n "$CACHED" ]]; then
    # The PREV_* group is what this dial SUPERSEDES, so it is read whether or not
    # --fresh goes on to decline the entry: step 7 closes the old surface either
    # way, and step 6's cache healing compares against the id that was cached.
    PREV_SURFACE_REF=$(jq -r '.surface_ref // empty' <<<"$CACHED")
    PREV_CALL_ID=$(jq -r '.last_call_id // empty' <<<"$CACHED")
    PREV_SESSION_ID=$(jq -r '.session_id // empty' <<<"$CACHED")
    if $FRESH; then
      add_fallback "session-cache→fresh(${PREV_SESSION_ID:-unknown})"
    else
      FIRST_CONTACT=false
      REMOTE_SESSION_ID="$PREV_SESSION_ID"
      SURFACE_REF="$PREV_SURFACE_REF"
    fi
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
#
# The slash command + tags go on their OWN line, with the work-order message on
# the line(s) below. This is what lets EITHER transport deliver first contact as two
# writes — cmux-paste.sh as two pastes, herdr-prompt.sh as a `pane send-text` plus an
# `agent prompt` (claude-plugins-fvhx) — because the invocation line sent alone
# renders verbatim (a ❯-line starting with `/`), so the slash command parses; the
# message rides the second write, which CC may collapse to a `[Pasted text +N lines]`
# placeholder and expands back inside the command args on submit (claude-plugins-pmgb).
# Keeping the message ON this line would let a long first message push the
# invocation line past CC's ~800-char collapse threshold and take the `/` down
# with it — the whole regression.
if $FIRST_CONTACT; then
  SEND_PROMPT=$(printf '/hotline:hotline-ringing [MODE: %s] [CALLER: %s] [SESSION: %s]\n%s' \
    "$MODE_TAG" "$MY_CWD" "$MY_SESSION_ID" "$MESSAGE")
else
  SEND_PROMPT="$MESSAGE"
fi

# On disk, always, 0600 — even when the caller passed --prompt. Every launcher and
# the reuse path then take --prompt-file, so the payload never rides an argv where
# `ps` would publish it to any local user (claude-plugins-86ka). A --prompt-file
# caller's own file is not reused directly: first contact wraps the message in the
# ringing invocation, so the bytes to deliver are not the bytes it handed us.
SEND_PROMPT_FILE=$(mktemp /tmp/hotline-prompt-XXXXX)
chmod 600 "$SEND_PROMPT_FILE"
printf '%s' "$SEND_PROMPT" > "$SEND_PROMPT_FILE"
trap 'rm -f "$ERR_FILE" "$SEND_PROMPT_FILE"' EXIT

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
    --arg confirmed "$DELIVERY_CONFIRMED" \
    --arg retried "$DELIVERY_RETRIED" \
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
     + (if $call_id  == "" then {} else {call_id:$call_id} end)
     + (if $confirmed == "" then {} else {confirmed:$confirmed} end)
     + (if $retried   == "" then {} else {retried_enter:($retried == "true")} end)'
  exit 0
}
CALL_ID_OUT=""
# How much the delivery had to work to land. Present only where cmux-paste.sh actually
# reported them — the surface-reuse path — and OMITTED elsewhere, like every other
# optional field above: a headless call has no screen to confirm against, so a `false`
# there would be an assertion rather than a reading. `confirmed` names the tier that
# proved it (transcript is definitive, screen is inference); `retried_enter` says the
# submit needed a corrective Enter, which is the fkgv/y4rl race showing itself and is
# worth seeing before it becomes a bug report.
DELIVERY_CONFIRMED=""
DELIVERY_RETRIED=""

# ---------------------------------------------------------------------------
# Step 5a — Follow-up into the surface the session already lives in.
#
# Preferred whenever it applies: the surface holds a live REPL for that exact
# session, so we send the next message into it instead of stacking a new surface
# per turn. Multi-line messages used to skip this outright, which meant the reuse
# path never ran for the follow-ups it existed to serve — work-order follow-ups
# are almost always multi-line, so every substantive one opened a second pane and
# orphaned the first. cmux-reuse-surface.sh now decides delivery itself: short
# single-line messages are typed in, anything larger goes to the call dir with a
# one-line pointer (claude-plugins-i8fb).
#
# EVERY bail records a fallback. The add_fallback for a refusal used to sit
# INSIDE this block, so a bail-before-attempt emitted `fallbacks:[]` — a
# follow-up that silently opened a second pane looked identical to a clean
# first-contact dial, which is how the surface sprawl went unnoticed for so
# long (claude-plugins-6nbr).
# ---------------------------------------------------------------------------
if ! $FIRST_CONTACT && [[ "$TRANSPORT" == "cmux" ]]; then
  if [[ -z "$SURFACE_REF" ]]; then
    # Headless/detached first contact leaves no surface to reuse, and a prior
    # follow-up may have cleared a stale one.
    add_fallback "surface-reuse-skipped(no-cached-surface)"
  else
    # Always the file, never --prompt: a work order handed over on argv is
    # readable by any local user through `ps`, and the reuse path used to take
    # that route whenever the caller had used --prompt (claude-plugins-86ka).
    REUSE=$(bash "$DIAL_SCRIPTS/cmux-reuse-surface.sh" \
      --surface "$SURFACE_REF" --session "$REMOTE_SESSION_ID" \
      --prompt-file "$SEND_PROMPT_FILE" --cwd "$TARGET_PATH" 2>/dev/null)

    # UNDELIVERED IS CHECKED FIRST, before the call_dir success test below. The
    # undelivered outcome carries a call_dir too (it holds the only copy of the
    # prompt), so testing for call_dir first read a failed delivery as a successful
    # one — reported "connected" and left the caller polling a surface that may
    # never answer.
    #
    # The paste went out and could not be confirmed: NOT a fallback. The fresh path
    # would re-deliver the same prompt into a --resume of the same session, so a
    # payload that actually landed would run twice.
    if [[ "$(jq -r '.undelivered // false' <<<"$REUSE" 2>/dev/null)" == "true" ]]; then
      CALL_DIR=$(jq -r '.call_dir // empty' <<<"$REUSE" 2>/dev/null)
      emit_error deliver "the follow-up was pasted into surface $SURFACE_REF but could not be confirmed: $(reason_of "$REUSE")" \
        "The REPL is live and may ALREADY have the message; $(jq -r '.prompt_file // "the prompt file"' <<<"$REUSE" 2>/dev/null) still holds it. Read the callee's transcript for the call_id before doing anything. See references/error-recovery.md § Delivery. Do NOT re-dial — that would deliver it twice."
    fi

    REUSE_DIR=$(jq -r '.call_dir // empty' <<<"$REUSE" 2>/dev/null)
    if [[ -n "$REUSE_DIR" ]]; then
      CALL_DIR="$REUSE_DIR"
      # cmux-paste.sh's confidence, forwarded rather than dropped.
      DELIVERY_CONFIRMED=$(jq -r '.confirmed // empty' <<<"$REUSE" 2>/dev/null)
      DELIVERY_RETRIED=$(jq -r 'if has("retried_enter") then (.retried_enter|tostring) else "" end' <<<"$REUSE" 2>/dev/null)
      [[ -s "$CALL_DIR/call_id.txt" ]] && CALL_ID_OUT=$(cat "$CALL_DIR/call_id.txt")
      # The reused surface is unchanged, but bump last_contact / exchange_count.
      bash "$DIAL_SCRIPTS/session-cache.sh" update "$TARGET_PATH" \
        --caller-session "$MY_SESSION_ID" --surface "$SURFACE_REF" \
        ${CALL_ID_OUT:+--call-id "$CALL_ID_OUT"} >/dev/null 2>&1
      emit_connected true
    fi
    # {"fallback":"fresh"} — refused BEFORE anything was sent, so a fresh surface is
    # safe: the callee received nothing.
    add_fallback "surface-reuse→fresh($(reason_of "$REUSE"))"
    SURFACE_REF=""
  fi
fi

# ---------------------------------------------------------------------------
# Step 5a (herdr) — the same step, into a named agent instead of a surface.
#
# The named agent IS the session: `herdr agent prompt <name>` re-targets it, and a
# follow-up continues the same conversation in the same transcript. So this is the
# cmux step above with the surface machinery removed — no host to resolve, no input
# box to read, no interrupt to risk, and (step 7) nothing superseded to close,
# because the same agent is reused rather than replaced.
#
# The two things that DO carry over are the two that matter: a fresh nonce per turn
# (the transcript keeps every prior exchange's STATUS lines, so a reused nonce would
# read the previous turn's completion as this one's), and the rule that EVERY bail
# records a fallback — a follow-up that quietly started a second callee must never
# look identical to a clean first-contact dial (claude-plugins-6nbr).
#
# A REFUSED REUSE FALLS BACK TO A FRESH LAUNCH, and that costs the prior context:
# herdr cannot re-host an existing claude session (`claude --resume` and
# `--session-id` are mutually exclusive, and the launcher refuses the combination
# rather than derive a transcript path it would then read wrongly). The cmux
# fallback re-opens the SAME session in a new surface; this one cannot, so the
# fallback entry says so outright instead of leaving a caller to discover that its
# callee has amnesia.
#
# WITH ONE EXCEPTION: A BLOCKED AGENT IS NOT FALLEN BACK FROM, it fails the dial.
# The fallback is only honest when the thing being worked around is GONE. A blocked
# callee is live, and it holds the only copy of this conversation — so starting a
# fresh one and re-keying the cache to it leaves that agent running, waiting on a
# human, and no longer reachable through hotline. Meanwhile the response wait calls
# the identical state "a human must look" and stops (exit 5, resumable). Two
# verdicts for one state, and this end of the call picked the one that strands a
# callee (claude-plugins-7wze.13). So it is an ERROR here, with the same advice.
# ---------------------------------------------------------------------------
if ! $FIRST_CONTACT && [[ "$TRANSPORT" == "herdr" ]]; then
  if [[ -z "$SURFACE_REF" ]]; then
    # A prior exchange over headless (no host at all), or a cmux follow-up that
    # cleared a stale surface ref, leaves nothing to re-target.
    add_fallback "herdr-agent-reuse-skipped(no-cached-host-handle; the fresh callee starts without the prior context)"
  else
    # The file, never --prompt: same reason as the cmux path (claude-plugins-86ka).
    REUSE=$(bash "$DIAL_SCRIPTS/herdr-reuse-agent.sh" \
      --agent "$SURFACE_REF" --session "$REMOTE_SESSION_ID" \
      --prompt-file "$SEND_PROMPT_FILE" --cwd "$TARGET_PATH" 2>/dev/null)

    # BLOCKED FIRST — before anything that could start a second callee. The agent
    # is live and confirmed waiting on input; nothing was submitted to it.
    if [[ "$(jq -r '.blocked // false' <<<"$REUSE" 2>/dev/null)" == "true" ]]; then
      emit_error transport "herdr agent $SURFACE_REF is BLOCKED and cannot take a follow-up: $(reason_of "$REUSE")" \
        "A human has to clear it — \`herdr agent attach $SURFACE_REF\` shows what it is asking, and the state was confirmed by a second read, so this is not a blink. Nothing was submitted and nothing was started: once it is unblocked, re-dial exactly as you just did and the same agent is re-targeted with its context intact. hotline will NOT start a second callee for you, because that one would strand this agent and lose the conversation. (Unattended callees avoid the permission case by dialing with HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS=1 — a real trust decision, see the plugin README.) See references/error-recovery.md § herdr Failures."
    fi

    # UNDELIVERED NEXT, before the call_dir success test — the undelivered outcome
    # carries a call_dir too (it holds the only copy of the prompt), so testing for
    # call_dir first would read a failed delivery as a successful one.
    if [[ "$(jq -r '.undelivered // false' <<<"$REUSE" 2>/dev/null)" == "true" ]]; then
      CALL_DIR=$(jq -r '.call_dir // empty' <<<"$REUSE" 2>/dev/null)
      emit_error deliver "the follow-up was submitted to herdr agent $SURFACE_REF but could not be confirmed: $(reason_of "$REUSE")" \
        "The agent is live and may ALREADY have the message; $(jq -r '.prompt_file // "the prompt file"' <<<"$REUSE" 2>/dev/null) still holds it. Read the callee's transcript for the call_id, or \`herdr agent attach $SURFACE_REF\`, before doing anything. See references/error-recovery.md § herdr Failures. Do NOT re-dial — that would deliver it twice."
    fi

    REUSE_DIR=$(jq -r '.call_dir // empty' <<<"$REUSE" 2>/dev/null)
    if [[ -n "$REUSE_DIR" ]]; then
      CALL_DIR="$REUSE_DIR"
      [[ -s "$CALL_DIR/call_id.txt" ]] && CALL_ID_OUT=$(cat "$CALL_DIR/call_id.txt")
      # The agent is unchanged (that is the point), but bump last_contact /
      # exchange_count and record this turn's nonce.
      bash "$DIAL_SCRIPTS/session-cache.sh" update "$TARGET_PATH" \
        --caller-session "$MY_SESSION_ID" --surface "$SURFACE_REF" \
        ${CALL_ID_OUT:+--call-id "$CALL_ID_OUT"} >/dev/null 2>&1
      emit_connected true
    fi
    # {"fallback":"fresh"} — refused BEFORE anything was submitted (the agent is
    # gone, or blocked on input), so a fresh callee is safe. It just will not
    # remember anything.
    add_fallback "herdr-agent-reuse→fresh($(reason_of "$REUSE"); the fresh callee starts WITHOUT the prior context — herdr cannot re-host an existing claude session)"
    SURFACE_REF=""
  fi
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
  CONF_ARGS+=(--box-timeout "$PASTE_BOX_TIMEOUT")
  # The file, never argv: conference was the last hotline path handing a whole
  # payload to `claude` on a command line (claude-plugins-92s5).
  CONF_ARGS+=(--prompt-file "$SEND_PROMPT_FILE")

  CONF=$(bash "$DIAL_SCRIPTS/cmux-call.sh" "${CONF_ARGS[@]}" 2>"$ERR_FILE")
  CONF_FALLBACK=$(jq -r '.fallback // empty' <<<"$CONF" 2>/dev/null)
  CONF_ERROR=$(jq -r '.error // empty' <<<"$CONF" 2>/dev/null)
  CONF_UNDELIVERED=$(jq -r '.undelivered // false' <<<"$CONF" 2>/dev/null)

  if [[ "$CONF_FALLBACK" == "headless" ]]; then
    # cmux is up but cmux-cli isn't installed, so side-by-side placement is
    # unavailable. Re-route through headless rather than bouncing to the model.
    add_fallback "cmux-cli-missing→headless"
    TRANSPORT="headless"
  elif [[ "$CONF_UNDELIVERED" == "true" ]]; then
    # The surface is open and its REPL is live, but it was never told anything —
    # the same situation as a failed first-contact paste, so the same stage.
    emit_error deliver "$CONF_ERROR" \
      "The conference pane is live and empty; $(jq -r '.prompt_file // "the prompt file"' <<<"$CONF" 2>/dev/null) still holds the prompt (call dir $(jq -r '.call_dir // "n/a"' <<<"$CONF" 2>/dev/null)). See references/error-recovery.md § Delivery — NOT § CMUX Failures. Do NOT silently re-dial — the callee may have received it after the confirmation window."
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
    # cmux-call.sh mints a nonce now (it needs one to confirm its own paste
    # landed). Recording it gives conference calls what every other path already
    # had: a call_id the receiver echoes back, and the identity proof
    # superseded-surface cleanup requires before it will close anything.
    CALL_ID_OUT=$(jq -r '.call_id // empty' <<<"$CONF" 2>/dev/null)
    [[ "$CALL_ID_OUT" == "null" ]] && CALL_ID_OUT=""
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
        --mode "$MODE_TAG" ${SURFACE_REF:+--surface "$SURFACE_REF"} \
        ${CALL_ID_OUT:+--call-id "$CALL_ID_OUT"} >/dev/null 2>&1
    else
      # Same clear-vs-leave-untouched distinction as step 6 below: a conference
      # follow-up that produced no surface must not keep pointing at the old one.
      CONF_CACHE=(--caller-session "$MY_SESSION_ID")
      if [[ -n "$SURFACE_REF" ]]; then
        CONF_CACHE+=(--surface "$SURFACE_REF")
      else
        CONF_CACHE+=(--clear-surface)
      fi
      [[ -n "$CALL_ID_OUT" ]] && CONF_CACHE+=(--call-id "$CALL_ID_OUT")
      bash "$DIAL_SCRIPTS/session-cache.sh" update "$TARGET_PATH" \
        "${CONF_CACHE[@]}" >/dev/null 2>&1
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
  ARGS+=(--prompt-file "$SEND_PROMPT_FILE")
  bash "$DIAL_SCRIPTS/headless-call-async.sh" "${ARGS[@]}" 2>"$ERR_FILE"
}

fire_cmux() {
  local ARGS=(--cwd "$TARGET_PATH")
  $FIRST_CONTACT && ARGS+=(--name "$SESSION_NAME")
  ARGS+=(${PLACEMENT_ARGS[@]+"${PLACEMENT_ARGS[@]}"})
  [[ -n "$EFFECTIVE_RESUME" ]] && ARGS+=(--resume "$EFFECTIVE_RESUME")
  $DO_FORK && ARGS+=(--fork-session)
  [[ -n "$TOOLS" ]] && ARGS+=(--tools "$TOOLS")
  ARGS+=(--prompt-file "$SEND_PROMPT_FILE")
  bash "$DIAL_SCRIPTS/cmux-call-async.sh" "${ARGS[@]}" 2>"$ERR_FILE"
}

# herdr's launcher BLOCKS until the callee's REPL is interactive-ready (that is what
# `herdr agent start` does), so --boot-timeout has to reach it here — for cmux the
# same budget is spent later, inside wait-for-session.sh. No placement args: herdr
# is detached-only and the validation above has already refused everything else, so
# there is nothing left to say about placement.
#
# $EFFECTIVE_RESUME IS DELIBERATELY NOT PASSED. Reaching this function on a
# follow-up means the reuse step above refused (dead or blocked agent), and herdr
# cannot re-host an existing session at all: `claude --resume` and `--session-id`
# are mutually exclusive, and without the preset there is no transcript path to read
# the answer from. So the fresh callee is genuinely fresh, and the reuse→fresh
# fallback entry says so rather than letting a caller infer continuity.
fire_herdr() {
  local ARGS=(--cwd "$TARGET_PATH")
  $FIRST_CONTACT && ARGS+=(--name "$SESSION_NAME")
  [[ -n "$TOOLS" ]] && ARGS+=(--tools "$TOOLS")
  [[ -n "$BOOT_TIMEOUT" ]] && ARGS+=(--boot-timeout "$BOOT_TIMEOUT")
  ARGS+=(--prompt-file "$SEND_PROMPT_FILE")
  bash "$DIAL_SCRIPTS/herdr-call-async.sh" "${ARGS[@]}" 2>"$ERR_FILE"
}

if [[ "$TRANSPORT" == "cmux" ]]; then
  CALL_RESULT=$(fire_cmux)
  if [[ "$(jq -r '.fallback // empty' <<<"$CALL_RESULT" 2>/dev/null)" == "headless" ]]; then
    add_fallback "cmux-cli-missing→headless"
    TRANSPORT="headless"
    CALL_RESULT=$(fire_headless)
  fi
elif [[ "$TRANSPORT" == "herdr" ]]; then
  # No fallback branch on purpose: herdr was asked for explicitly and its preflight
  # passed, so a launch failure here is a failure to report, not a transport to swap.
  CALL_RESULT=$(fire_herdr)
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
# herdr hosts the callee in its own persistent pane. That IS the detached placement
# as far as the caller is concerned (nothing lands in their window), and it is the
# only one herdr Phase 1 accepts, so it is reported as such rather than inventing a
# fourth placement word for the emitted contract.
[[ "$TRANSPORT" == "herdr" ]] && PLACEMENT_EFFECTIVE="detached"
# The launcher records a preset-vs-observed session-id disagreement in the call dir.
# It belongs in the emitted JSON too: it is the single most diagnostic signal when a
# herdr dial later goes quiet, and a fact that only exists in a temp dir is a fact
# nobody reads. The call still succeeded — the launcher adopted herdr's observed id,
# which is the right one — so this is a fallback note, not an error.
if [[ -s "$CALL_DIR/session_id_mismatch.txt" ]]; then
  add_fallback "herdr-session-id-mismatch($(sed -n '1p' "$CALL_DIR/session_id_mismatch.txt"))"
fi
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
# The call's HOST REF, one field for both transports — the emitted `.surface_ref` has
# always been documented as an opaque handle, and register-call.sh records it the
# same way. For herdr it is the agent NAME, which is what `agent prompt` /
# `agent wait` / `agent get` address, and what step 5a's follow-up re-targets.
[[ -s "$CALL_DIR/herdr_agent.txt" ]] && SURFACE_REF=$(cat "$CALL_DIR/herdr_agent.txt")

# Follow-ups that had to open a NEW surface: refresh the cached surface_ref so
# the next follow-up reuses the live one instead of the dead one. (First contact
# is registered by wait-for-session.sh → register-call.sh.)
#
# When this follow-up ended up with NO surface — the cmux→headless fallback
# above, or side placement degrading to detached — the ref must be CLEARED, not
# left alone. An omitted --surface means "leave untouched", which would keep
# pointing the next follow-up at a surface this session has since left, and
# reuse would type the message into a REPL nobody is reading
# (claude-plugins-2caw).
if ! $FIRST_CONTACT; then
  CACHE_ARGS=(--caller-session "$MY_SESSION_ID")
  if [[ -n "$SURFACE_REF" ]]; then
    CACHE_ARGS+=(--surface "$SURFACE_REF")
  else
    CACHE_ARGS+=(--clear-surface)
  fi
  [[ -n "$CALL_ID_OUT" ]] && CACHE_ARGS+=(--call-id "$CALL_ID_OUT")
  # A follow-up that landed on a DIFFERENT callee session must re-key the cache, or
  # the next follow-up resumes a session id nothing is listening on and every answer
  # is read from a transcript that stops growing. Only a herdr reuse→fresh fallback
  # gets here with a changed id (herdr cannot re-host a session, so its fresh callee
  # is a new one); a cmux follow-up resumes the cached id, so the values match and
  # this is a no-op — which is why the condition is the CHANGE, not the transport.
  if [[ -n "$REMOTE_SESSION_ID" && "$REMOTE_SESSION_ID" != "$PREV_SESSION_ID" ]]; then
    CACHE_ARGS+=(--session "$REMOTE_SESSION_ID")
    add_fallback "callee-session-changed(${PREV_SESSION_ID:-none}→$REMOTE_SESSION_ID; the cache now points at the new session)"
  fi
  bash "$DIAL_SCRIPTS/session-cache.sh" update "$TARGET_PATH" \
    "${CACHE_ARGS[@]}" >/dev/null 2>&1
fi

# ---------------------------------------------------------------------------
# Step 6b — Deliver the prompt into the freshly booted REPL.
#
# cmux-call-async.sh launches a BARE claude and leaves the prompt in
# pending_paste.md, so the payload never reaches an argv (claude-plugins-86ka) and
# first contact uses the SAME verified delivery verb as every follow-up. Boot came
# first because a paste into a shell that has not yet exec'd claude is lost with no
# error at all; --wait-box re-proves the input box is drawn immediately before the
# paste, which is a stronger claim than "the banner appeared once".
#
# AFTER the cache heal above, deliberately: which surface the session now lives in
# is true the moment that surface booted and resumed it, whether or not our
# message landed. Leaving the cache pointing at the surface `claude --resume` just
# took over is how a later follow-up types into a REPL nobody is reading
# (claude-plugins-2caw) — so the heal must not be skipped by a delivery failure.
#
# BEFORE step 7, equally deliberately: a delivery failure exits here, so nothing
# gets closed while something is wrong.
#
# A failed delivery is an ERROR, not a fallback: the surface is open and its REPL
# is live, but it was never told anything. Reporting "connected" would leave the
# caller waiting on a response to a message that does not exist.
# ---------------------------------------------------------------------------
if [[ "$TRANSPORT" == "cmux" && -s "$CALL_DIR/pending_paste.md" ]]; then
  DELIVER_SURFACE=""
  DELIVER_WORKSPACE=""
  if [[ -z "$SURFACE_REF" ]]; then
    # Detached placement addresses a workspace, not a surface. Resolve the
    # workspace's current surface so the paste has a target — through the shared
    # reader in repl-state.sh, which is also what cmux-paste.sh uses, so there is
    # one implementation of "read the cmux tree" rather than three.
    DELIVER_ADDR=$(cmux_workspace_current_surface "$(cat "$CALL_DIR/workspace_ref.txt" 2>/dev/null)")
    if [[ $? -eq 0 ]]; then
      DELIVER_WORKSPACE="${DELIVER_ADDR%% *}"
      DELIVER_SURFACE="${DELIVER_ADDR##* }"
    fi
  else
    DELIVER_SURFACE="$SURFACE_REF"
  fi
  if [[ -z "$DELIVER_SURFACE" ]]; then
    emit_error deliver "the callee's REPL booted but no surface could be resolved to paste the prompt into" \
      "Check \$call_dir/workspace_ref.txt against \`cmux tree --all --json --id-format both\`. Retry with the default side placement, or force headless with --headless."
  fi
  DELIVER_ARGS=(--surface "$DELIVER_SURFACE"
                --payload-file "$CALL_DIR/pending_paste.md" --call-id "$CALL_ID_OUT"
                --cwd "$TARGET_PATH" --session "$REMOTE_SESSION_ID"
                --wait-box "$PASTE_BOX_TIMEOUT")
  [[ -n "$DELIVER_WORKSPACE" ]] && DELIVER_ARGS+=(--workspace "$DELIVER_WORKSPACE")
  DELIVERY=$(bash "$DIAL_SCRIPTS/cmux-paste.sh" "${DELIVER_ARGS[@]}" 2>/dev/null)
  if [[ "$(jq -r '.delivered // false' <<<"$DELIVERY" 2>/dev/null)" != "true" ]]; then
    emit_error deliver "the callee's REPL booted but the prompt never landed in it: $(reason_of "$DELIVERY")" \
      "The pane is live and empty; \$call_dir/pending_paste.md still holds the prompt. See references/error-recovery.md § Delivery — NOT § CMUX Failures, which describes the launch. Do NOT silently re-dial — the callee may have received it after the confirmation window."
  fi
  # The callee's transcript is the record now; the vehicle goes.
  rm -f "$CALL_DIR/pending_paste.md"
fi

# --- Step 6b (herdr) — same step, one call instead of a surface hunt. ---------
# herdr addresses the callee by AGENT NAME, so there is no surface to resolve and no
# input box to prove: `agent start` already blocked until the REPL was ready, which
# is the property cmux needs three screen signals to establish. What does NOT change
# is the proof: the nonce has to turn up in the callee's own transcript, or the
# delivery is reported as unconfirmed. herdr-prompt.sh has no screen tier to fall
# back on (alternate-screen TUI), and says so in its reason.
#
# A failed delivery is an ERROR here for the same reason as cmux: the callee is live
# and was told nothing, so reporting "connected" would leave the caller waiting on a
# response to a message that does not exist.
#
# --first-contact, ALWAYS, and it is not a redundant flag: pending_paste.md only
# exists here because herdr-call-async.sh just launched this agent, so every delivery
# reaching this block is an opening one (a follow-up delivers through step 5a). That
# turns on the settle + readiness re-probe and the larger confirmation budget the
# opening payload needs — see FIRST CONTACT in herdr-prompt.sh (claude-plugins-7wze.12).
if [[ "$TRANSPORT" == "herdr" && -s "$CALL_DIR/pending_paste.md" ]]; then
  HERDR_AGENT_REF=$(cat "$CALL_DIR/herdr_agent.txt" 2>/dev/null || true)
  if [[ -z "$HERDR_AGENT_REF" ]]; then
    emit_error deliver "the herdr callee booted but its call dir names no agent to deliver to" \
      "Check \$call_dir/herdr_agent.txt and \`herdr agent list\`. This is a launcher bug, not a transient failure — do not re-dial without looking."
  fi
  DELIVERY=$(bash "$DIAL_SCRIPTS/herdr-prompt.sh" \
    --agent "$HERDR_AGENT_REF" --payload-file "$CALL_DIR/pending_paste.md" \
    --call-id "$CALL_ID_OUT" --cwd "$TARGET_PATH" --session "$REMOTE_SESSION_ID" \
    --first-contact 2>/dev/null)
  if [[ "$(jq -r '.delivered // false' <<<"$DELIVERY" 2>/dev/null)" != "true" ]]; then
    # `sent` FORWARDED, not dropped: it is the difference between "re-dialing is safe"
    # and "re-dialing runs the work order twice", and the recovery below tells the model
    # to read it — which it could not do while this error was the only thing it got back
    # (claude-plugins-zh7p). Normalized to a literal true/false so the field is always
    # present; a delivery result too broken to parse reads as false, and the recovery's
    # unconditional "do NOT re-dial blindly" is what covers that case.
    DELIVERY_SENT=false
    [[ "$(jq -r '.sent // false' <<<"$DELIVERY" 2>/dev/null)" == "true" ]] && DELIVERY_SENT=true
    emit_error deliver "the herdr callee booted but the prompt never landed in it: $(reason_of "$DELIVERY")" \
      "\$call_dir/pending_paste.md still holds the prompt, and the agent is still live — \`herdr agent attach $HERDR_AGENT_REF\` to see its state. This error's own \`sent\` field is $DELIVERY_SENT: when it is true the callee may have received the payload after the confirmation window, so do NOT re-dial blindly — read its transcript for the call_id first. See references/error-recovery.md § herdr Failures, which covers this case (§ Delivery describes the cmux paste)." \
      "{\"sent\": $DELIVERY_SENT}"
  fi
  rm -f "$CALL_DIR/pending_paste.md"
fi

# ---------------------------------------------------------------------------
# Step 7 — Close the surface this follow-up superseded (claude-plugins-n7xo).
#
# Only reached when reuse did NOT apply, so the session was resumed somewhere new
# and the old surface holds a REPL nobody will speak to again. Deliberately after
# the boot wait: the replacement is provably live before anything gets closed.
# The script itself proves the old surface is the right one and is idle, and
# refuses with a reason otherwise — so every outcome is reported, and a refusal
# never fails the dial.
#
# --fresh reaches here too, which is why FIRST_CONTACT alone does not gate it: the
# fresh dial reports first contact, but a cached surface it deliberately ignored is
# superseded in exactly the same sense — a REPL nobody will speak to again. PREV_*
# are empty on a genuine first contact, so the added clause widens nothing else.
# ---------------------------------------------------------------------------
if { ! $FIRST_CONTACT || $FRESH; } && [[ "$TRANSPORT" == "cmux" && -n "$PREV_SURFACE_REF" \
      && "$PREV_SURFACE_REF" != "$SURFACE_REF" ]]; then
  CLEANUP=$(bash "$DIAL_SCRIPTS/close-superseded-surface.sh" \
    --surface "$PREV_SURFACE_REF" --expect-call-id "$PREV_CALL_ID" 2>/dev/null)
  if [[ "$(jq -r '.closed // false' <<<"$CLEANUP" 2>/dev/null)" == "true" ]]; then
    add_fallback "surface-cleanup→closed($PREV_SURFACE_REF)"
  else
    add_fallback "surface-cleanup-skipped($(reason_of "$CLEANUP"))"
  fi
fi

emit_connected true
