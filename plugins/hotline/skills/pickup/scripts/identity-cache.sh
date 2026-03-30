#!/usr/bin/env bash
# =============================================================================
# Identity Cache: Read/write workspace identity JSON
#
# Stores identities in ~/.agents-hotline/identities/<path-hash>.json
# TTL default: 24 hours. Override with HOTLINE_IDENTITY_TTL_HOURS env var.
#
# Usage:
#   identity-cache.sh read [--cwd /path]        # Read cached identity (stdout)
#   identity-cache.sh write [--cwd /path]        # Write identity from stdin
#   identity-cache.sh is-stale [--cwd /path]     # Exit 0 if stale/missing, 1 if fresh
#   identity-cache.sh path [--cwd /path]          # Print cache file path
# =============================================================================
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: identity-cache.sh read [--cwd /path]"
  echo "       identity-cache.sh write [--cwd /path]"
  echo "       identity-cache.sh is-stale [--cwd /path]"
  echo "       identity-cache.sh path [--cwd /path]"
  echo ""
  echo "Read/write workspace identity JSON from ~/.agents-hotline/identities/<hash>.json"
  exit 0
fi

IDENTITIES_DIR="$HOME/.agents-hotline/identities"
TTL_HOURS="${HOTLINE_IDENTITY_TTL_HOURS:-24}"
TTL_SECONDS=$((TTL_HOURS * 3600))

# Parse args
CMD=""
CWD="$(pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd) CWD="$2"; shift 2 ;;
    read|write|is-stale|path) CMD="$1"; shift ;;
    *) shift ;;
  esac
done

# Canonical path — resolve symlinks
CANONICAL=$(realpath "$CWD" 2>/dev/null || echo "$CWD")

# Hash the canonical path for the filename
PATH_HASH=$(echo -n "$CANONICAL" | shasum -a 256 | cut -c1-16)
CACHE_FILE="${IDENTITIES_DIR}/${PATH_HASH}.json"

mkdir -p "$IDENTITIES_DIR"

case "${CMD:-}" in
  read)
    if [[ -f "$CACHE_FILE" ]]; then
      cat "$CACHE_FILE"
    else
      echo "{}"
    fi
    ;;
  write)
    cat > "$CACHE_FILE"
    ;;
  is-stale)
    if [[ ! -f "$CACHE_FILE" ]]; then
      exit 0  # Missing = stale
    fi
    GENERATED=$(jq -r '.identity.generated // 0' "$CACHE_FILE")
    NOW=$(date +%s)
    AGE=$((NOW - GENERATED))
    if [[ $AGE -ge $TTL_SECONDS ]]; then
      exit 0  # Stale
    fi
    exit 1    # Fresh
    ;;
  path)
    echo "$CACHE_FILE"
    ;;
  *)
    echo "Usage: identity-cache.sh <read|write|is-stale|path> [--cwd /path]" >&2
    exit 1
    ;;
esac
