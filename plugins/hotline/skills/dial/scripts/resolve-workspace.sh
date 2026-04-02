#!/usr/bin/env bash
# =============================================================================
# Resolve Workspace: Turn a fuzzy reference into a canonical workspace path
#
# Resolution chain:
#   1. Raw path → validate exists
#   2. UUID → session cache lookup
#   3. Dirmap ID → $DIRMAP_CMD get
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

# Detect dirmap early — needed for UUID reverse lookup and fuzzy matching
DIRMAP_CMD=""
if command -v dirmap &>/dev/null; then
  DIRMAP_CMD="dirmap"
elif [[ -x "$PLUGIN_SCRIPTS/dirmap-fallback.sh" ]]; then
  DIRMAP_CMD="$PLUGIN_SCRIPTS/dirmap-fallback.sh"
fi

# 1. Absolute path?
if [[ "$REFERENCE" == /* || "$REFERENCE" == ~* ]]; then
  if resolve_path "$REFERENCE"; then
    exit 0
  fi
  echo "Error: Path does not exist: $REFERENCE" >&2
  exit 1
fi

# 1b. Relative path? (e.g., "local-frontend/lindris-frontend" from within a monorepo)
# Try prepending $PWD to see if it resolves to a real directory
if [[ "$REFERENCE" == */* ]]; then
  if resolve_path "$(pwd)/$REFERENCE"; then
    exit 0
  fi
fi

# 2. UUID? (session ID lookup)
UUID_REGEX='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
if [[ "$REFERENCE" =~ $UUID_REGEX ]]; then
  # 2a. Check session cache first (fast path)
  if [[ -n "$CALLER_SESSION" ]]; then
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

  # 2b. Reverse lookup: find the transcript file for this session ID
  # The transcript lives at ~/.claude/projects/<encoded-path>/<session-id>.jsonl
  # The parent directory name decodes to the workspace path
  PROJECTS_ROOT="$HOME/.claude/projects"
  TRANSCRIPT=$(find "$PROJECTS_ROOT" -name "${REFERENCE}.jsonl" -type f 2>/dev/null | head -1)
  if [[ -n "$TRANSCRIPT" ]]; then
    ENCODED_DIR=$(basename "$(dirname "$TRANSCRIPT")")
    # Decode: the encoded dir is the path with non-alphanumeric chars replaced by hyphens
    # We can't perfectly reverse this, but we can search for a matching directory
    # Try common prefixes to reconstruct the path
    for prefix in "/Users" "/home" "/private/tmp"; do
      CANDIDATE=$(echo "$ENCODED_DIR" | sed "s|^-|${prefix}/|; s|-|/|g")
      if [[ -d "$CANDIDATE" ]]; then
        echo "$(realpath "$CANDIDATE")"
        exit 0
      fi
    done
    # If simple decode didn't work, try all dirmap entries for a match
    if [[ -n "$DIRMAP_CMD" ]]; then
      DIRMAP_JSON=$($DIRMAP_CMD list --json 2>/dev/null || echo "{}")
      MATCH=$(echo "$DIRMAP_JSON" | jq -r --arg enc "$ENCODED_DIR" \
        'to_entries[] | select((.value | gsub("[^a-zA-Z0-9-]"; "-")) == $enc) | .value' 2>/dev/null | head -1)
      if [[ -n "$MATCH" ]]; then
        if resolve_path "$MATCH"; then
          exit 0
        fi
      fi
    fi
    # Last resort: output what we know
    echo "Error: Found transcript for session $REFERENCE in $ENCODED_DIR but could not decode to a filesystem path" >&2
    exit 1
  fi
fi

# 3. Dirmap ID?
if [[ -n "$DIRMAP_CMD" ]]; then
  DIRMAP_RESULT=$($DIRMAP_CMD get "$REFERENCE" 2>/dev/null || true)
  if [[ -n "$DIRMAP_RESULT" ]]; then
    if resolve_path "$DIRMAP_RESULT"; then
      exit 0
    fi
  fi
fi

# 3b. Strip filler words and retry dirmap lookup
# "the dotfiles workspace" → "dotfiles", "my blog project" → "blog"
if [[ -n "$DIRMAP_CMD" ]]; then
  STRIPPED=$(echo "$REFERENCE" | tr '[:upper:]' '[:lower:]' \
    | sed 's/ the / /g; s/^the //; s/ the$//; s/ my / /g; s/^my //; s/ a / /g; s/^a //; s/ an / /g; s/^an //; s/ its / /g; s/^its //' \
    | sed 's/ workspace//g; s/ project//g; s/ repo$//; s/ repository//g; s/ site//g; s/ app$//; s/ codebase//g; s/ directory//g; s/ dir / /g; s/ folder//g' \
    | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | tr -s ' ')
  if [[ -n "$STRIPPED" && "$STRIPPED" != "$REFERENCE" ]]; then
    # Try each remaining word as a dirmap ID
    for word in $STRIPPED; do
      DIRMAP_RESULT=$($DIRMAP_CMD get "$word" 2>/dev/null || true)
      if [[ -n "$DIRMAP_RESULT" ]]; then
        if resolve_path "$DIRMAP_RESULT"; then
          exit 0
        fi
      fi
    done
  fi
fi

# 4. Fuzzy match — dump all candidates as JSON for the agent to pick
# Both real dirmap and fallback accept `list --json` (fallback ignores the flag)
if [[ -n "$DIRMAP_CMD" ]]; then
  IDENTITIES_DIR="$HOME/.agents-hotline/identities"
  DIRMAP_JSON=$($DIRMAP_CMD list --json 2>/dev/null || echo "{}")

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
