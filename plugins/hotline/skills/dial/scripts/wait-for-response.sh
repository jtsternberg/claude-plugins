#!/usr/bin/env bash
# =============================================================================
# Wait for Response: poll until an async hotline call completes.
#
# Two modes, auto-detected from the call_dir contents:
#
#   Headless mode (no workspace_ref.txt): poll call_dir/done at 2s intervals.
#   headless-call-async.sh's own poller writes response.json + done.
#
#   CMUX mode (workspace_ref.txt present): cmux-call-async.sh doesn't run a
#   background poller (under cmux access_mode=cmuxOnly, an orphaned subshell
#   gets "Broken pipe" on every cmux call). This script (a child of the
#   caller's cmux-spawned bash, so cmux access works) does the polling
#   itself: reads the cmux screen, finds the latest STATUS line, extracts
#   the response body, writes response.json + done, and closes the workspace
#   unless keep_workspace.txt said otherwise.
#
# Output (stdout, both modes):
#   {"session_id":"...","response":"..."}
#
# The emitted JSON is compact (single line) and re-validated via jq before
# being written to stdout — so stdout is guaranteed to be parseable JSON on
# exit 0, or the script exits non-zero with an error on stderr.
#
# Caller note: agents running under zsh MUST NOT pipe the captured output
# through `echo` (zsh's echo interprets backslash escapes and will corrupt
# any JSON with escape sequences). Use `<<<"$VAR"` or read from the
# call_dir/response.json file directly.
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
TIMEOUT=""
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

CMUX_MODE=false
if [[ -f "$CALL_DIR/workspace_ref.txt" ]]; then
  CMUX_MODE=true
fi
# CMUX mode gets a longer default (30 min) since work orders can run a while.
if [[ -z "$TIMEOUT" ]]; then
  $CMUX_MODE && TIMEOUT=1800 || TIMEOUT=300
fi

emit_response_json() {
  # Re-emit as compact, validated JSON. If response.json is somehow
  # unparseable, jq exits non-zero with an error on stderr — we surface that
  # loudly rather than hand a caller visibly-valid-but-broken bytes.
  if ! jq -c . "$CALL_DIR/response.json"; then
    echo "response.json is not parseable JSON — hotline emission bug" >&2
    exit 1
  fi
}

if $CMUX_MODE; then
  WS_REF=$(cat "$CALL_DIR/workspace_ref.txt")
  KEEP=$(cat "$CALL_DIR/keep_workspace.txt" 2>/dev/null || echo false)
  LAUNCH_SCRIPT=$(cat "$CALL_DIR/launch_script.txt" 2>/dev/null || true)
  SESSION_ID=""
  [[ -f "$CALL_DIR/session_id.txt"        ]] && SESSION_ID=$(cat "$CALL_DIR/session_id.txt")
  [[ -z "$SESSION_ID" && -f "$CALL_DIR/session_id_preset.txt" ]] && \
    SESSION_ID=$(cat "$CALL_DIR/session_id_preset.txt")
  ESC=$(printf '\x1b')

  # Per-call nonce match. When call_id.txt is present (new launcher), we
  # require every STATUS line we accept to carry `call_id=<nonce>`. This
  # makes replayed scrollback from `claude --resume` (which restores the
  # prior transcript including its STATUS markers) impossible to mistake
  # for completion of THIS call. Without the nonce, the bare regex would
  # match the replayed STATUS and return stale response text — see
  # claude-plugins-gkj for the failure mode.
  CALL_ID=""
  [[ -f "$CALL_DIR/call_id.txt" ]] && CALL_ID=$(cat "$CALL_DIR/call_id.txt")
  if [[ -n "$CALL_ID" ]]; then
    STATUS_TAIL=" call_id=${CALL_ID}[[:space:]]*\$"
    STATUS_TAIL_AWK=" call_id=${CALL_ID}[[:space:]]*$"
  else
    STATUS_TAIL="[[:space:]]*\$"
    STATUS_TAIL_AWK="[[:space:]]*$"
  fi

  cleanup_workspace_and_script() {
    rm -f "$LAUNCH_SCRIPT" 2>/dev/null || true
    if [[ "$KEEP" != "true" ]]; then
      # Suppress BOTH stdout and stderr — close-workspace's "OK …" message
      # would otherwise pollute the JSON we emit on stdout, breaking jq
      # parsing in callers.
      cmux close-workspace --workspace "$WS_REF" >/dev/null 2>&1 || true
    fi
  }

  ELAPSED=0
  # If the launcher already wrote done+error.txt, surface that immediately.
  if [[ -f "$CALL_DIR/done" && -f "$CALL_DIR/error.txt" ]]; then
    cat "$CALL_DIR/error.txt" >&2
    exit 1
  fi

  while [[ $ELAPSED -lt $TIMEOUT ]]; do
    sleep "$POLL_INTERVAL"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))

    SCREEN=$(cmux read-screen --workspace "$WS_REF" --scrollback --lines 9999 \
      2>/dev/null || true)
    [[ -z "$SCREEN" ]] && continue

    # Strip ANSI escape sequences and carriage returns. cmux returns
    # colorized terminal output, including colored STATUS lines, and raw
    # matching would miss those completion signals.
    CLEAN=$(echo "$SCREEN" | sed "s/${ESC}\[[0-9;]*[mGKHFJKsu]//g; s/${ESC}(B//g; s/\r//g")

    # Find the LATEST STATUS line anywhere in the screen. Robust against
    # trailing terminal chrome (shell prompts, the claude REPL's `│ > │` box
    # bottom, etc.). Receivers put their real STATUS at message tail — if a
    # response body quotes STATUS strings earlier, the real one still wins
    # because we always take the last occurrence.
    # Match any line that ENDS with `STATUS: <signal>` (allowing trailing
    # whitespace). The "latest such line wins" rule combined with the
    # end-of-line anchor handles every claude REPL rendering variant —
    # column-0, 2-space indent, `⏺ ` assistant marker, future UI tweaks —
    # without needing per-variant regex updates. Quoted STATUS strings
    # inside response prose almost never appear at end-of-line in
    # practice; if they do, "latest wins" still picks the receiver's real
    # terminal STATUS that comes after them.
    #
    # Trim everything before the matched STATUS for the comparison value.
    STATUS_RE="STATUS: [A-Z_]+${STATUS_TAIL_AWK}"
    LATEST_STATUS=$(echo "$CLEAN" | awk -v re="$STATUS_RE" '
      match($0, re) {
        s=substr($0, RSTART)
        sub(/[[:space:]]+$/, "", s)
      }
      END {print s}
    ')

    [[ -z "$LATEST_STATUS" ]] && continue
    [[ "$LATEST_STATUS" =~ ^STATUS:\ WORK_IN_PROGRESS ]] && continue

    if [[ "$LATEST_STATUS" =~ ^STATUS:\ (WORK_COMPLETE|OUT_OF_SCOPE|DONE) ]]; then
      # Strip terminal chrome before extracting the response. Aggressive
      # prefix match strips lines starting with claude's box-drawing
      # characters (the REPL renders its idle prompt as a multi-line box
      # where the middle line `│ > │` carries text; a stricter "pure chrome
      # only" regex leaves that line in the response).
      #
      # Lines we strip:
      #   - the `bash /tmp/hotline-launch-*` command echoed at the prompt
      #   - lines starting with claude's banner / box-drawing characters
      #   - claude's "ℹ ..." info lines (update available / tip banners)
      #   - the bare REPL prompt `> ` on its own line (markdown blockquotes
      #     starting with `> text` survive)
      #
      # Walk lines, reset buffer on every WORK_IN_PROGRESS, save buffer on
      # every terminal STATUS, emit the LAST saved buffer — matches the
      # LATEST_STATUS we chose for detection.
      WIP_RE="STATUS: WORK_IN_PROGRESS${STATUS_TAIL_AWK}"
      TERM_RE="STATUS: (WORK_COMPLETE|OUT_OF_SCOPE|DONE)${STATUS_TAIL_AWK}"
      RESPONSE=$(echo "$CLEAN" \
        | grep -v "^bash /tmp/hotline-launch" \
        | grep -vE "^[╭│╰─└┌┘┐ℹ]" \
        | grep -vE "^>[[:space:]]*$" \
        | awk -v wip="$WIP_RE" -v term="$TERM_RE" '
            $0 ~ wip  {buf=""; next}
            $0 ~ term {result=buf; buf=""; next}
            {buf = buf $0 ORS}
            END {printf "%s", result}
          ')

      jq -n --arg sid "$SESSION_ID" --arg resp "$RESPONSE" \
        '{session_id: $sid, response: $resp}' > "$CALL_DIR/response.json"
      touch "$CALL_DIR/done"
      cleanup_workspace_and_script

      emit_response_json
      exit 0
    fi
  done

  # Timeout: write error.txt and done so future callers see the failure
  # without re-polling.
  echo "Timed out waiting for STATUS in cmux workspace ${WS_REF} (${TIMEOUT}s)" \
    > "$CALL_DIR/error.txt"
  touch "$CALL_DIR/done"
  cleanup_workspace_and_script
  cat "$CALL_DIR/error.txt" >&2
  exit 1
fi

# Headless mode — original file-watch behavior.
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

emit_response_json
