#!/usr/bin/env bash
# =============================================================================
# Session Init: Resolve the caller's session identity
#
# Normal path (Claude Code >= 2.1.132): $CLAUDE_CODE_SESSION_ID is exported
# into every Bash subprocess, so identity resolves in a single call with
# status "cached" and caller_kind "native".
#
# Legacy fallback (older Claude Code, or a stripped environment): the two-step
# fingerprint discovery via session-fingerprint.sh and session-discover.sh.
# The two steps MUST be separate tool calls because the transcript must be
# written (after the first tool call returns) before the fingerprint can be
# found in it. This script does NOT combine them into one step.
#
# Usage:
#   session-init.sh [--expanded]                           # Resolve identity (or plant fingerprint on legacy path)
#   session-init.sh discover <fingerprint> [--expanded]    # Legacy step 2: find session from fingerprint
#   session-init.sh --help
#
# Step 1 output (JSON on stdout):
#   {"status": "cached", "session_id": "..."}        — done, use this ID
#   {"status": "planted", "fingerprint": "..."}       — legacy path: run step 2 in next tool call
#   {"status": "error", "message": "..."}             — something went wrong
#
# Step 2 output (JSON on stdout):
#   {"status": "discovered", "session_id": "..."}     — done, use this ID
#   {"status": "error", "message": "..."}             — discovery failed
#
# "cached" responses may include "caller_kind": "override" | "native" | "codex".
#
# With --expanded, "cached" and "discovered" responses also include:
#   "transcript_path", "claude_pid", "project_dir"
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: session-init.sh [--expanded]                    # Resolve caller session identity"
  echo "       session-init.sh discover <fp> [--expanded]      # Legacy: discover session from fingerprint"
  echo ""
  echo "Resolves the calling agent's session ID. Precedence:"
  echo "  1. HOTLINE_CALLER_SESSION_ID  (explicit override)"
  echo "  2. CLAUDE_CODE_SESSION_ID     (native, Claude Code >= 2.1.132 — one call)"
  echo "  3. CODEX_THREAD_ID            (Codex caller)"
  echo "  4. Legacy fingerprint discovery (two separate tool calls)"
  echo ""
  echo "Options:"
  echo "  --expanded  Include transcript_path, claude_pid, project_dir in JSON output"
  exit 0
fi

# Parse all args — flags can appear anywhere
EXPANDED=false
SUBCOMMAND=""
FINGERPRINT=""
for arg in "$@"; do
  case "$arg" in
    --expanded) EXPANDED=true ;;
    discover) SUBCOMMAND="discover" ;;
    *) FINGERPRINT="$arg" ;;
  esac
done

# Override — highest precedence, environment-agnostic. Lets non-Claude callers
# (Codex, tests, other tools) supply a stable caller ID directly and skip the
# Claude-only fingerprint/discover dance. Returning "cached" here short-circuits
# both Step 1 and Step 2, so it wins regardless of which step was invoked.
if [[ -n "${HOTLINE_CALLER_SESSION_ID:-}" ]]; then
  jq -nc --arg id "$HOTLINE_CALLER_SESSION_ID" \
    '{status:"cached", session_id:$id, caller_kind:"override"}'
  exit 0
fi

# Walk up the process tree to the owning claude process, if any.
find_claude_pid() {
  local cpid=$$ comm
  while [[ "$cpid" != "1" && -n "$cpid" ]]; do
    comm=$(ps -o comm= -p "$cpid" 2>/dev/null | xargs)
    # macOS `ps -o comm=` returns the full executable path, Linux the bare
    # command name. Strip the path prefix so the check works on both.
    if [[ "${comm##*/}" == "claude" ]]; then
      echo "$cpid"
      return 0
    fi
    cpid=$(ps -o ppid= -p "$cpid" 2>/dev/null | tr -d ' ')
  done
  echo ""
}

# Native Claude identity — Claude Code >= 2.1.132 exports the session ID into
# every Bash subprocess, so identity resolves in this single call and the
# fingerprint dance below is unnecessary. Validated as a UUID so an empty or
# malformed value falls through to the legacy path instead of propagating.
# Like the override, this short-circuits both Step 1 and Step 2.
if [[ "${CLAUDE_CODE_SESSION_ID:-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
  if [[ "$EXPANDED" == true ]]; then
    # The transcript lives under the SESSION'S LAUNCH directory, not the
    # current cwd — a session that cd'd away (worktrees) would get a
    # wrong-but-plausible path from the cwd convention alone. Resolve in
    # accuracy order: pid-keyed cache (validated against the known session
    # ID), then a glob for the ID across all project dirs (the filename IS
    # the session ID, so a match is authoritative), then the cwd convention.
    CLAUDE_PID="$(find_claude_pid)"
    TRANSCRIPT_PATH=""
    TRANSCRIPT_CACHE="/tmp/claude-session-${CLAUDE_PID}.transcript"
    if [[ -n "$CLAUDE_PID" && -f "$TRANSCRIPT_CACHE" ]]; then
      CANDIDATE=$(cat "$TRANSCRIPT_CACHE")
      if [[ "${CANDIDATE##*/}" == "${CLAUDE_CODE_SESSION_ID}.jsonl" && -f "$CANDIDATE" ]]; then
        TRANSCRIPT_PATH="$CANDIDATE"
      fi
    fi
    if [[ -z "$TRANSCRIPT_PATH" ]]; then
      for f in "$HOME/.claude/projects"/*/"${CLAUDE_CODE_SESSION_ID}.jsonl"; do
        if [[ -f "$f" ]]; then
          TRANSCRIPT_PATH="$f"
          break
        fi
      done
    fi
    if [[ -z "$TRANSCRIPT_PATH" ]]; then
      PROJECT_HASH=$(pwd | sed 's|[^a-zA-Z0-9-]|-|g')
      TRANSCRIPT_PATH="$HOME/.claude/projects/${PROJECT_HASH}/${CLAUDE_CODE_SESSION_ID}.jsonl"
    fi
    jq -nc --arg id "$CLAUDE_CODE_SESSION_ID" --arg path "$TRANSCRIPT_PATH" \
      --arg pid "$CLAUDE_PID" --arg dir "$(dirname "$TRANSCRIPT_PATH")" \
      '{status:"cached", session_id:$id, caller_kind:"native", transcript_path:$path, claude_pid:$pid, project_dir:$dir}'
  else
    jq -nc --arg id "$CLAUDE_CODE_SESSION_ID" \
      '{status:"cached", session_id:$id, caller_kind:"native"}'
  fi
  exit 0
fi

# Codex caller — Codex sets $CODEX_THREAD_ID in every shell it spawns, and
# that value IS the current session/thread ID: stable across `codex resume`,
# present in all launch modes. Its presence is itself the "this is Codex"
# signal, so no separate detection is needed.
# Known tradeoff: this rung outranks the legacy fingerprint path, so a
# pre-2.1.132 Claude launched FROM a Codex shell (inherited CODEX_THREAD_ID,
# no native var) resolves to the Codex thread instead of the Claude session.
# Accepted: current Claude is covered by the native rung above, and
# HOTLINE_CALLER_SESSION_ID overrides for anyone actually in that corner.
# See skills/dial/references/codex-caller.md.
if [[ -n "${CODEX_THREAD_ID:-}" ]]; then
  jq -nc --arg id "$CODEX_THREAD_ID" \
    '{status:"cached", session_id:$id, caller_kind:"codex"}'
  exit 0
fi

# Legacy step 2: discover from fingerprint
if [[ "$SUBCOMMAND" == "discover" ]]; then
  if [[ -z "$FINGERPRINT" ]]; then
    echo '{"status":"error","message":"No fingerprint provided. Usage: session-init.sh discover <fingerprint>"}'
    exit 1
  fi

  if [[ "$EXPANDED" == true ]]; then
    RESULT=$("$SCRIPT_DIR/session-discover.sh" "$FINGERPRINT" --json 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 0 ]]; then
      echo "$RESULT" | jq '{status: "discovered"} + .'
    else
      jq -n --arg msg "$RESULT" '{"status":"error","message":$msg}'
      exit 1
    fi
  else
    RESULT=$("$SCRIPT_DIR/session-discover.sh" "$FINGERPRINT" 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 0 ]]; then
      jq -n --arg sid "$RESULT" '{"status":"discovered","session_id":$sid}'
    else
      jq -n --arg msg "$RESULT" '{"status":"error","message":$msg}'
      exit 1
    fi
  fi
  exit 0
fi

# Legacy step 1 (pre-2.1.132 Claude, or CLAUDE_CODE_SESSION_ID stripped from
# the environment): check the fingerprint cache or plant a new fingerprint.
STDERR_FILE=$(mktemp)
trap "rm -f $STDERR_FILE" EXIT

RESULT=$("$SCRIPT_DIR/session-fingerprint.sh" 2>"$STDERR_FILE") && EXIT_CODE=0 || EXIT_CODE=$?

case $EXIT_CODE in
  0)
    # Cache hit
    if [[ "$EXPANDED" == true ]]; then
      # Look up cached transcript path, or reconstruct it
      CLAUDE_PID=$(find_claude_pid)

      TRANSCRIPT_CACHE="/tmp/claude-session-${CLAUDE_PID}.transcript"
      if [[ -n "$CLAUDE_PID" && -f "$TRANSCRIPT_CACHE" ]]; then
        TRANSCRIPT_PATH=$(cat "$TRANSCRIPT_CACHE")
      else
        # Reconstruct from convention
        PROJECT_HASH=$(pwd | sed 's|[^a-zA-Z0-9-]|-|g')
        TRANSCRIPT_PATH="$HOME/.claude/projects/${PROJECT_HASH}/${RESULT}.jsonl"
      fi
      PROJECT_DIR=$(dirname "$TRANSCRIPT_PATH")
      jq -n --arg sid "$RESULT" --arg path "$TRANSCRIPT_PATH" --arg pid "${CLAUDE_PID:-}" --arg dir "$PROJECT_DIR" \
        '{"status":"cached","session_id":$sid,"transcript_path":$path,"claude_pid":$pid,"project_dir":$dir}'
    else
      jq -n --arg sid "$RESULT" '{"status":"cached","session_id":$sid}'
    fi
    ;;
  1)
    # Cache miss — fingerprint planted
    FINGERPRINT=$(cat "$STDERR_FILE")
    jq -n --arg fp "$FINGERPRINT" '{"status":"planted","fingerprint":$fp,"next":"Run session-init.sh discover <fingerprint> in a SEPARATE tool call"}'
    ;;
  *)
    # No claude process in ancestry, no native ID, no Codex thread (both were
    # checked above before falling through to this legacy path).
    ERRMSG=$(cat "$STDERR_FILE")
    jq -n --arg msg "$ERRMSG" '{"status":"error","message":$msg}'
    exit 1
    ;;
esac
