#!/usr/bin/env bash
# =============================================================================
# Resolve Workspace: Turn a fuzzy reference into a canonical workspace path
#
# Resolution chain:
#   1. Raw path → validate exists
#   2. UUID → session cache lookup
#   3. Dirmap ID → dirmap get
#   4. Fuzzy → dump candidates JSON on stderr for agent to pick
#
# Exit 0 + stdout = resolved canonical path
# Exit 1 + stderr = candidates or error
#
# Usage:
#   resolve-workspace.sh <reference> [--caller-session <id>]
# =============================================================================
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: resolve-workspace.sh <reference> [--caller-session <id>]"
  echo ""
  echo "Resolves a fuzzy workspace reference to a canonical path."
  echo "Exit 0 + stdout = resolved path. Exit 1 + stderr = candidates or error."
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS="$(cd "$SCRIPT_DIR/../../.." && pwd)/scripts"

REFERENCE="${1:-}"
shift || true

CALLER_SESSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --caller-session) CALLER_SESSION="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$REFERENCE" ]]; then
  echo "Error: No workspace reference provided" >&2
  exit 1
fi

# Helper: resolve and validate a path
resolve_path() {
  local p="$1"
  p="${p/#\~/$HOME}"
  local canonical
  canonical=$(realpath "$p" 2>/dev/null || echo "")
  if [[ -n "$canonical" && -d "$canonical" ]]; then
    echo "$canonical"
    return 0
  fi
  return 1
}

# 1. Raw path?
if [[ "$REFERENCE" == /* || "$REFERENCE" == ~* ]]; then
  if resolve_path "$REFERENCE"; then
    exit 0
  fi
  echo "Error: Path does not exist: $REFERENCE" >&2
  exit 1
fi

# 2. UUID? (session ID lookup)
UUID_REGEX='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
if [[ "$REFERENCE" =~ $UUID_REGEX && -n "$CALLER_SESSION" ]]; then
  SESSIONS_DIR="$HOME/.agents-hotline/sessions"
  if [[ -f "${SESSIONS_DIR}/${CALLER_SESSION}.json" ]]; then
    MATCH=$(jq -r --arg sid "$REFERENCE" \
      '[.connections | to_entries[] | select(.value.session_id == $sid) | .key] | first // empty' \
      "${SESSIONS_DIR}/${CALLER_SESSION}.json")
    if [[ -n "$MATCH" ]]; then
      echo "$MATCH"
      exit 0
    fi
  fi
fi

# 3. Dirmap ID?
DIRMAP_CMD=""
if command -v dirmap &>/dev/null; then
  DIRMAP_CMD="dirmap"
elif [[ -x "$PLUGIN_SCRIPTS/dirmap-fallback.sh" ]]; then
  DIRMAP_CMD="$PLUGIN_SCRIPTS/dirmap-fallback.sh"
fi

if [[ -n "$DIRMAP_CMD" ]]; then
  DIRMAP_RESULT=$($DIRMAP_CMD get "$REFERENCE" 2>/dev/null || true)
  if [[ -n "$DIRMAP_RESULT" ]]; then
    if resolve_path "$DIRMAP_RESULT"; then
      exit 0
    fi
  fi
fi

# 4. Fuzzy match — dump all candidates as JSON for the agent to pick
if [[ -n "$DIRMAP_CMD" ]]; then
  IDENTITIES_DIR="$HOME/.agents-hotline/identities"
  DIRMAP_JSON=$($DIRMAP_CMD list 2>/dev/null || echo "{}")

  CANDIDATES="[]"
  while IFS=$'\t' read -r name path; do
    CANONICAL=$(realpath "$path" 2>/dev/null || echo "$path")
    PATH_HASH=$(echo -n "$CANONICAL" | shasum -a 256 | cut -c1-16)
    IDENTITY_FILE="${IDENTITIES_DIR}/${PATH_HASH}.json"
    IDENTITY="{}"
    if [[ -f "$IDENTITY_FILE" ]]; then
      IDENTITY=$(jq '.identity // {}' "$IDENTITY_FILE")
    fi
    CANDIDATES=$(echo "$CANDIDATES" | jq --arg n "$name" --arg p "$CANONICAL" --argjson id "$IDENTITY" \
      '. + [{id: $n, path: $p, identity: $id}]')
  done < <(echo "$DIRMAP_JSON" | jq -r 'to_entries[] | "\(.key)\t\(.value)"')

  if [[ $(echo "$CANDIDATES" | jq 'length') -gt 0 ]]; then
    echo "$CANDIDATES" >&2
    exit 1
  fi
fi

echo "Error: Could not resolve '$REFERENCE'" >&2
exit 1
