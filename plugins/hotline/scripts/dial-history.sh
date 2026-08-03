#!/usr/bin/env bash
# =============================================================================
# Dial History: Append-only log of incoming calls per workspace
#
# Stored as JSONL at ~/.agents-hotline/identities/<hash>.dial_history.jsonl,
# where <hash> is the first 16 chars of sha256(RECEIVER cwd) — i.e. the log
# answers "who has called THIS workspace". Written by the CALLER's
# register-call.sh (see that script), not by the receiving agent: the receiver
# can't run a script living in the caller's plugin install dir without breaking
# the ringing skill's workspace-isolation rule, and the caller already holds
# every field from the call_dir metadata.
#
# Entry schema (one COMPACT json object per line):
#   session_id       — the CALLER's session id (historical field name; kept for
#                      compatibility with logs written before v0.19)
#   caller           — the caller's workspace path
#   receiver_session — the callee's own session id (added v0.19; absent in
#                      older entries)
#   mode             — quick_call | work_order | conference_call
#   timestamp        — unix seconds
#
# Capped at 100 ENTRIES (not lines) — trims oldest on each write.
#
# Format note: entries used to be written with pretty-printed `jq -n`, so a
# "jsonl" file held ~6 lines per entry and the line-based cap sliced objects in
# half — permanently corrupting the file once it crossed 100 lines. Writes now
# emit compact single-line JSON, and `append` normalizes any legacy or
# half-trimmed file it encounters (salvaging every object that still parses)
# before appending. That makes the fix self-healing per workspace.
#
# Usage:
#   dial-history.sh append --cwd <path> --session <id> --caller <path> --mode <mode>
#                          [--receiver-session <id>]
#   dial-history.sh read [--cwd <path>]
#   dial-history.sh normalize [--cwd <path>]   # repair in place, no append
# =============================================================================
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: dial-history.sh append --cwd <path> --session <id> --caller <path> --mode <mode>"
  echo "                             [--receiver-session <id>]"
  echo "       dial-history.sh read [--cwd <path>]"
  echo "       dial-history.sh normalize [--cwd <path>]"
  echo ""
  echo "Append-only log of incoming calls per workspace (capped at 100 entries)."
  echo "--cwd is the RECEIVER's workspace — it keys the history file."
  exit 0
fi

IDENTITIES_DIR="$HOME/.agents-hotline/identities"
MAX_ENTRIES=100

CMD="${1:-}"
shift || true

CWD="$(pwd)"
SESSION_ID=""
CALLER=""
MODE=""
RECEIVER_SESSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd) CWD="$2"; shift 2 ;;
    --session) SESSION_ID="$2"; shift 2 ;;
    --caller) CALLER="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --receiver-session) RECEIVER_SESSION="$2"; shift 2 ;;
    *) shift ;;
  esac
done

CANONICAL=$(realpath "$CWD" 2>/dev/null || echo "$CWD")
PATH_HASH=$(echo -n "$CANONICAL" | shasum -a 256 | cut -c1-16)
HISTORY_FILE="${IDENTITIES_DIR}/${PATH_HASH}.dial_history.jsonl"

mkdir -p "$IDENTITIES_DIR"

# Rewrite the history file as one compact JSON object per line.
#
# Handles three inputs: already-compact JSONL (no-op in effect), legacy
# pretty-printed entries, and a file whose first entry was sliced in half by the
# old line-based cap. `jq -c .` streams every whole object in a concatenated
# stream onto its own line, but refuses a file that STARTS mid-object — so on
# failure we drop the leading line and retry. Files are capped, so this
# converges in at most MAX_ENTRIES cheap attempts. Salvage is best-effort by
# design: a half-entry at the head is unrecoverable and gets dropped, which is
# strictly better than leaving the whole file unparseable.
normalize_history() {
  local file="$1"
  [[ -s "$file" ]] || return 0

  local work="${file}.norm.$$"
  cp "$file" "$work"

  # Strip-and-retry. Note an empty $work makes `jq -c .` SUCCEED with empty
  # output, so the loop always terminates — the "did we salvage anything?"
  # check below is what distinguishes success from total loss.
  local attempts=0
  while ! jq -c . "$work" > "${work}.out" 2>/dev/null; do
    attempts=$((attempts + 1))
    if [[ $attempts -gt $((MAX_ENTRIES + 10)) ]]; then
      : > "${work}.out"
      break
    fi
    tail -n +2 "$work" > "${work}.trim" && mv "${work}.trim" "$work"
  done

  if [[ -s "${work}.out" ]]; then
    mv "${work}.out" "$file"
  else
    # Nothing parsed out of a non-empty file. Keep the ORIGINAL bytes (not the
    # stripped work copy) for forensics and start the log clean, so a garbage
    # file can't wedge every future append.
    cp "$file" "${file}.corrupt.$(date +%s)" 2>/dev/null || true
    : > "$file"
    rm -f "${work}.out"
  fi
  rm -f "$work" "${work}.trim"
}

# Keep only the newest MAX_ENTRIES *entries*. Safe only on compact JSONL, so
# every caller normalizes first.
trim_history() {
  local file="$1"
  local count
  count=$(wc -l < "$file" | tr -d ' ')
  if [[ "$count" -gt "$MAX_ENTRIES" ]]; then
    tail -n "$MAX_ENTRIES" "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
  fi
}

case "$CMD" in
  append)
    if [[ -z "$SESSION_ID" || -z "$CALLER" || -z "$MODE" ]]; then
      echo "Usage: dial-history.sh append --session <id> --caller <path> --mode <mode>" >&2
      exit 1
    fi
    # Repair legacy/half-trimmed content BEFORE appending, so the entry-based
    # cap below operates on true JSONL.
    [[ -f "$HISTORY_FILE" ]] && normalize_history "$HISTORY_FILE"

    NOW=$(date +%s)
    # -c: compact. One line per entry is what makes this a .jsonl file and what
    # makes the cap safe. receiver_session is omitted when unknown rather than
    # written as null, so older readers see the original four keys.
    ENTRY=$(jq -nc --arg s "$SESSION_ID" --arg c "$CALLER" --arg m "$MODE" \
      --arg r "$RECEIVER_SESSION" --argjson t "$NOW" \
      '{session_id: $s, caller: $c, mode: $m, timestamp: $t}
       + (if $r == "" then {} else {receiver_session: $r} end)')
    echo "$ENTRY" >> "$HISTORY_FILE"

    trim_history "$HISTORY_FILE"
    ;;
  normalize)
    if [[ -f "$HISTORY_FILE" ]]; then
      normalize_history "$HISTORY_FILE"
      trim_history "$HISTORY_FILE"
    fi
    ;;
  read)
    if [[ -f "$HISTORY_FILE" ]]; then
      cat "$HISTORY_FILE"
    fi
    ;;
  *)
    echo "Usage: dial-history.sh <append|read|normalize> [options]" >&2
    exit 1
    ;;
esac
