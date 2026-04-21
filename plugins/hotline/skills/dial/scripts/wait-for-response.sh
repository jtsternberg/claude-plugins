#!/usr/bin/env bash
# =============================================================================
# Wait for Response: Poll until an async hotline call completes
#
# Polls call_dir/done at 2s intervals. On completion, prints the response
# JSON to stdout or the error message to stderr.
#
# Output (stdout):
#   {"session_id":"...","response":"..."}
#
# The emitted JSON is compact (single line) and re-validated via jq before
# being written to stdout — so stdout is guaranteed to be parseable JSON on
# exit 0, or the script exits non-zero with an error on stderr.
#
# Caller note: agents running under zsh MUST NOT pipe the captured output
# through `echo` (zsh's echo interprets backslash escapes and will corrupt
# any JSON with escape sequences). Use `<<<"$VAR"` or read from the
# call_dir/response.json file directly. See SKILL.md.
#
# Exit codes:
#   0 — response received (valid JSON on stdout)
#   1 — error (timeout, remote failure, or unparseable response.json;
#       message on stderr)
#
# Usage:
#   wait-for-response.sh <call_dir> [--timeout <seconds>]
# =============================================================================
set -euo pipefail

CALL_DIR="${1:-}"
TIMEOUT=300
POLL_INTERVAL=2

if [[ -z "$CALL_DIR" || ! -d "$CALL_DIR" ]]; then
  echo "Call directory not provided or does not exist" >&2
  exit 1
fi

shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

ELAPSED=0
while [[ ! -f "$CALL_DIR/done" ]]; do
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    echo "Timed out waiting for response (${TIMEOUT}s)" >&2
    exit 1
  fi
  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [[ -f "$CALL_DIR/error.txt" ]]; then
  cat "$CALL_DIR/error.txt" >&2
  exit 1
fi

if [[ ! -f "$CALL_DIR/response.json" ]]; then
  echo "Done but no response.json found" >&2
  exit 1
fi

# Re-emit as compact, validated JSON. If the file is somehow unparseable,
# jq exits non-zero with an error on stderr — we surface that loudly rather
# than hand a caller visibly-valid-but-broken bytes.
#
# Use `-c` (compact) only, not `-ce`: `-e` sets exit status from the
# truthiness of the last output, which would make `jq -ce . <file>` emit
# `null` to stdout AND exit 1 if response.json ever held a literal null —
# a confusing mixed signal. `-c` catches parse errors on its own, which is
# the only invariant this script promises.
if ! jq -c . "$CALL_DIR/response.json"; then
  echo "response.json is not parseable JSON — hotline emission bug" >&2
  exit 1
fi
