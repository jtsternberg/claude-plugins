#!/usr/bin/env bash
# =============================================================================
# Session Cache: Track Agent A's outgoing connections
#
# Stores session maps in ~/.agents-hotline/sessions/<caller-session>.json
# Keyed by Agent A's session ID to prevent collisions.
#
# Usage:
#   session-cache.sh get <target-path> --caller-session <id>
#   session-cache.sh set <target-path> --caller-session <id> --session <id> --mode <mode> [--surface <ref>] [--call-id <id>]
#   session-cache.sh update <target-path> --caller-session <id> [--session <id>] [--surface <ref> | --clear-surface] [--call-id <id>]
#   session-cache.sh list --caller-session <id>
#
# --surface records the opaque HOST HANDLE the callee's session lives in, so a
# follow-up can re-address that live callee instead of starting a second one. The
# JSON key remains surface_ref for backward compatibility, and the handle is
# per-transport — one field, because every consumer treats it as opaque:
#   cmux  — a surface handle (a stable UUID from side-by-side launchers; older
#           caches may hold a positional surface:N ref).
#   herdr — the agent NAME, which is what `agent prompt` / `agent wait` /
#           `agent get` address and what survives a disconnect.
# Optional — absent for headless calls and for cmux detached placements, neither
# of which leaves a host a follow-up can route into.
#
# --session on `update` RE-KEYS the callee session id. Omitted → untouched, which
# is right for the common follow-up that continued the cached session. It is
# needed when a follow-up ends up on a DIFFERENT session than the cached one: a
# herdr follow-up whose agent has died falls back to a fresh launch, and herdr
# cannot re-host an existing claude session, so the new callee has a new id.
# Leaving the old one there would point the next follow-up at a session nothing is
# listening on, and every answer would be read from a transcript that stopped
# growing.
#
# --clear-surface (update only) REMOVES surface_ref. An empty/omitted --surface
# means "leave it untouched", which is right when a caller simply has nothing
# new to say about the surface — but wrong when the caller KNOWS the session no
# longer occupies one (a follow-up that fell back to headless, or whose side
# placement degraded to detached). Leaving the old ref there sends the next
# follow-up typing into a surface this session has left (claude-plugins-2caw).
#
# --call-id records the per-call nonce of the most recent exchange as
# last_call_id. Cleanup needs it as proof of identity: a superseded surface is
# only safe to close if its scrollback still carries the nonce of the exchange
# it hosted, which distinguishes "the pane hotline used" from "a pane the user
# has since repurposed".
# =============================================================================
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: session-cache.sh get <target-path> --caller-session <id>"
  echo "       session-cache.sh set <target-path> --caller-session <id> --session <id> --mode <mode> [--surface <ref>] [--call-id <id>]"
  echo "       session-cache.sh update <target-path> --caller-session <id> [--session <id>] [--surface <ref> | --clear-surface] [--call-id <id>]"
  echo "       session-cache.sh list --caller-session <id>"
  echo ""
  echo "Tracks Agent A's outgoing connections in ~/.agents-hotline/sessions/<caller-session>.json"
  exit 0
fi

SESSIONS_DIR="$HOME/.agents-hotline/sessions"
mkdir -p "$SESSIONS_DIR"

CMD="${1:-}"
shift || true

# Parse flags
TARGET=""
CALLER_SESSION=""
SESSION_ID=""
MODE=""
SURFACE_REF=""
CALL_ID=""
CLEAR_SURFACE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --caller-session) CALLER_SESSION="$2"; shift 2 ;;
    --session) SESSION_ID="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --surface) SURFACE_REF="$2"; shift 2 ;;
    --call-id) CALL_ID="$2"; shift 2 ;;
    --clear-surface) CLEAR_SURFACE=true; shift ;;
    *) [[ -z "$TARGET" ]] && TARGET="$1"; shift ;;
  esac
done

# Contradictory intent — "point at this surface" and "there is no surface" —
# would resolve by whichever jq clause ran last. Refuse instead of guessing.
if $CLEAR_SURFACE && [[ -n "$SURFACE_REF" ]]; then
  echo "Error: --clear-surface and --surface are mutually exclusive" >&2
  exit 1
fi

if [[ -z "$CALLER_SESSION" ]]; then
  echo "Error: --caller-session required" >&2
  exit 1
fi

CACHE_FILE="${SESSIONS_DIR}/${CALLER_SESSION}.json"

# Resolve target to canonical path
if [[ -n "$TARGET" ]]; then
  TARGET=$(realpath "$TARGET" 2>/dev/null || echo "$TARGET")
fi

case "$CMD" in
  get)
    if [[ -z "$TARGET" ]]; then
      echo "Usage: session-cache.sh get <target-path> --caller-session <id>" >&2
      exit 1
    fi
    if [[ ! -f "$CACHE_FILE" ]]; then
      exit 1
    fi
    RESULT=$(jq -r --arg t "$TARGET" '.connections[$t] // empty' "$CACHE_FILE")
    if [[ -z "$RESULT" ]]; then
      exit 1
    fi
    echo "$RESULT"
    ;;
  set)
    if [[ -z "$TARGET" || -z "$SESSION_ID" || -z "$MODE" ]]; then
      echo "Usage: session-cache.sh set <target> --caller-session <id> --session <id> --mode <mode>" >&2
      exit 1
    fi
    NOW=$(date +%s)
    CALLER_CWD=$(realpath "$(pwd)" 2>/dev/null || pwd)
    # surface_ref is added only when non-empty so `get`'s `.surface_ref // empty`
    # cleanly signals "no reusable surface" for headless/detached calls.
    if [[ -f "$CACHE_FILE" ]]; then
      jq --arg t "$TARGET" --arg s "$SESSION_ID" --arg m "$MODE" --arg sf "$SURFACE_REF" \
         --arg ci "$CALL_ID" --argjson now "$NOW" \
        '.connections[$t] = ({session_id: $s, started: $now, last_contact: $now, mode: $m, exchange_count: 1}
           + (if $sf == "" then {} else {surface_ref: $sf} end)
           + (if $ci == "" then {} else {last_call_id: $ci} end))' \
        "$CACHE_FILE" > "${CACHE_FILE}.tmp" && mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
    else
      jq -n --arg caller "$CALLER_CWD" --arg cs "$CALLER_SESSION" \
        --arg t "$TARGET" --arg s "$SESSION_ID" --arg m "$MODE" --arg sf "$SURFACE_REF" \
        --arg ci "$CALL_ID" --argjson now "$NOW" \
        '{caller: $caller, caller_session_id: $cs, connections: {($t): ({session_id: $s, started: $now, last_contact: $now, mode: $m, exchange_count: 1}
           + (if $sf == "" then {} else {surface_ref: $sf} end)
           + (if $ci == "" then {} else {last_call_id: $ci} end))}}' \
        > "$CACHE_FILE"
    fi
    ;;
  update)
    if [[ -z "$TARGET" || ! -f "$CACHE_FILE" ]]; then
      exit 1
    fi
    NOW=$(date +%s)
    # Optional --surface refreshes surface_ref (self-heal: a follow-up that had
    # to open a NEW surface after the old one was closed records the new ref so
    # the next follow-up reuses it). Omitted → surface_ref is left untouched.
    # --clear-surface removes it outright, for the follow-up that ended up with
    # no surface at all.
    jq --arg t "$TARGET" --arg sf "$SURFACE_REF" --arg ci "$CALL_ID" --arg sid "$SESSION_ID" \
       --argjson clear "$($CLEAR_SURFACE && echo true || echo false)" --argjson now "$NOW" \
      '.connections[$t].last_contact = $now
       | .connections[$t].exchange_count += 1
       | (if $ci == "" then . else .connections[$t].last_call_id = $ci end)
       | (if $sid == "" then . else .connections[$t].session_id = $sid end)
       | (if $clear then del(.connections[$t].surface_ref)
          elif $sf == "" then .
          else .connections[$t].surface_ref = $sf end)' \
      "$CACHE_FILE" > "${CACHE_FILE}.tmp" && mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
    ;;
  list)
    if [[ -f "$CACHE_FILE" ]]; then
      cat "$CACHE_FILE"
    else
      echo "{}"
    fi
    ;;
  *)
    echo "Usage: session-cache.sh <get|set|update|list> [target] --caller-session <id>" >&2
    exit 1
    ;;
esac
