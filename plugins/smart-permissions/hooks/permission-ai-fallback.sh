#!/usr/bin/env bash
# Layer 2: AI-powered permission evaluation (~8-10s)
# Only fires when Layer 1 didn't decide (passthrough) and a permission dialog would appear.
# Uses Claude Haiku to evaluate against permission-policy.md.
# Fail-open: any error → no output → normal permission dialog shown.

set -euo pipefail

# Derive config dir from plugin install path (e.g. ~/.claude/plugins/cache/... → ~/.claude)
# Falls back to ~/.claude if CLAUDE_PLUGIN_ROOT is not set
if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
  CLAUDE_CONFIG_DIR="${CLAUDE_PLUGIN_ROOT%%/plugins/*}"
else
  CLAUDE_CONFIG_DIR="$HOME/.claude"
fi

LOG_DIR="$CLAUDE_CONFIG_DIR/hooks"
LOG_FILE="$LOG_DIR/smart-permissions.log"

log() {
  mkdir -p "$LOG_DIR"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [L2] $1" >> "$LOG_FILE"
}

fail_open() {
  log "FAIL-OPEN: $1"
  # No output = normal permission dialog
  exit 0
}

# --- Recursion guard ---
# CLAUDE_CODE is set when running inside Claude Code's hook context.
# If claude CLI spawns another claude, this prevents infinite loops.
if [[ "${CLAUDECODE:-}" == "1" ]]; then
  fail_open "Recursion detected (CLAUDECODE=1)"
fi

# --- Check dependencies ---
if ! command -v jq &>/dev/null; then
  fail_open "jq not found"
fi

if ! command -v claude &>/dev/null; then
  fail_open "claude CLI not found"
fi

# --- Parse input ---
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "Unknown"')
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}')
CWD=$(echo "$INPUT" | jq -r '.cwd // "unknown"')

log "Evaluating: tool=$TOOL_NAME cwd=$CWD"

# --- Load permission policy ---
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY_FILE="$PLUGIN_DIR/permission-policy.md"

if [[ ! -f "$POLICY_FILE" ]]; then
  fail_open "permission-policy.md not found at $POLICY_FILE"
fi

POLICY=$(cat "$POLICY_FILE")

# --- Build prompt for AI evaluation ---
PROMPT="You are a security evaluator for Claude Code tool calls.

<policy>
$POLICY
</policy>

<tool_call>
Tool: $TOOL_NAME
Working Directory: $CWD
Input: $TOOL_INPUT
</tool_call>

Based on the policy above, should this tool call be allowed?
Respond with EXACTLY one word on the first line: ALLOW or DENY
Then on the second line, a brief reason (one sentence)."

# --- Call Claude Haiku ---
# --no-session-persistence: don't pollute session history
# --tools "": no tools available to the evaluator
# --max-turns 1: single response, no back-and-forth
RESPONSE=$(echo "$PROMPT" | claude --print --model haiku --no-session-persistence --max-turns 1 2>/dev/null) || {
  fail_open "claude CLI failed (exit code $?)"
}

if [[ -z "$RESPONSE" ]]; then
  fail_open "Empty response from claude CLI"
fi

log "AI response: $(echo "$RESPONSE" | head -2 | tr '\n' ' ')"

# --- Parse AI decision ---
FIRST_LINE=$(echo "$RESPONSE" | head -1 | tr -d '[:space:]')
REASON=$(echo "$RESPONSE" | sed -n '2p' | head -c 200)

# Default reason if none provided
if [[ -z "$REASON" ]]; then
  REASON="AI evaluation"
fi

# Escape quotes in reason for JSON
REASON_ESCAPED=$(echo "$REASON" | sed 's/\\/\\\\/g; s/"/\\"/g')

if [[ "$FIRST_LINE" == "ALLOW" ]]; then
  log "DECISION: ALLOW — $REASON"
  echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"allow\",\"message\":\"AI: $REASON_ESCAPED\"}}}"
  exit 0
elif [[ "$FIRST_LINE" == "DENY" ]]; then
  log "DECISION: DENY — $REASON"
  echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"deny\",\"message\":\"AI: $REASON_ESCAPED\"}}}"
  exit 0
else
  # AI response wasn't clear — fail open to normal dialog
  fail_open "Unclear AI response: '$FIRST_LINE'"
fi
