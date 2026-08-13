#!/usr/bin/env bash
# =============================================================================
# Wait for Session: Poll until the remote session ID is available.
#
# Two modes, auto-detected from the call_dir contents:
#
#   Headless mode (no workspace_ref.txt): poll call_dir/session_id.txt at
#   1s intervals; cmux-call.sh and headless-call-async.sh write it themselves.
#
#   CMUX mode (workspace_ref.txt present): cmux-call-async.sh wrote
#   session_id_preset.txt but does NOT confirm claude actually booted —
#   under cmux access_mode=cmuxOnly, the script's own background poller
#   can't talk to cmux. This script (running as a child of the caller's
#   cmux-spawned bash) confirms REPL liveness via ANY of three signals:
#     A) `cmux read-screen` matches the Claude Code REPL banner.
#     B) The claude transcript file
#        ~/.claude/projects/<encoded-cwd>/<preset-session-id>.jsonl is non-empty
#        AND has grown since this script started (created, or appended to, the
#        moment claude opens the session). The growth requirement is not
#        pedantry: on a plain resume that file already exists, so a bare
#        existence check fired on the first poll and reported a boot that had not
#        happened yet.
#     C) The REPL has drawn its input box on screen.
#   Any signal promotes session_id_preset.txt → session_id.txt. Signal B
#   exists because banner regex is fragile (scrollback eviction, ANSI weirdness,
#   --resume banner variance can defeat it even when claude DID boot fine).
#
#   Signal C exists because first contact now launches a BARE REPL and delivers
#   its prompt by paste afterwards: a REPL with no prompt yet may write nothing
#   to its transcript until the first turn arrives, so signal B can stay silent
#   for a session that is perfectly up. The input box is the signal that actually
#   matters to the step that follows — a paste into a shell that has not exec'd
#   claude is lost silently — and it is strictly stronger than "the banner is
#   somewhere in scrollback", which stays true long after a REPL has died.
#
# Prints the session ID to stdout on success.
#
# Exit codes:
#   0 — session ID found (printed to stdout)
#   1 — error (timeout, missing call_dir, or early failure)
#
# Usage:
#   wait-for-session.sh <call_dir> [--timeout <seconds>]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../scripts/repl-state.sh
source "$SCRIPT_DIR/../../../scripts/repl-state.sh"

CALL_DIR="${1:-}"
TIMEOUT=""

if [[ -z "$CALL_DIR" || ! -d "$CALL_DIR" ]]; then
  echo '{"error":"Call directory not provided or does not exist"}' >&2
  exit 1
fi

shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Mode detection. cmux mode gets a longer default timeout (60s) because we're
# waiting for the receiver claude REPL to actually boot, not just a file to
# appear. Headless mode keeps its existing 30s default.
#
# Two cmux sub-modes, auto-detected like the launcher signals them:
#   surface mode    — surface_ref.txt present (side-by-side / --window placement).
#                     Poll the cmux SURFACE.
#   workspace mode  — workspace_ref.txt present (--detached placement).
#                     Poll the cmux WORKSPACE.
CMUX_MODE=false
SURFACE_MODE=false
if [[ -f "$CALL_DIR/surface_ref.txt" ]]; then
  CMUX_MODE=true
  SURFACE_MODE=true
elif [[ -f "$CALL_DIR/workspace_ref.txt" ]]; then
  CMUX_MODE=true
fi
# The defaults live in repl-state.sh, not here. dial.sh derives the paste's
# input-box wait from the same numbers — they are waiting for the same event — and
# with two definitions the documented 60 was true of this wait and not of that one.
if [[ -z "$TIMEOUT" ]]; then
  $CMUX_MODE && TIMEOUT="$HOTLINE_BOOT_TIMEOUT_CMUX" || TIMEOUT="$HOTLINE_BOOT_TIMEOUT_HEADLESS"
fi

# Common early-fail check: if the launcher already wrote done+error.txt, bail.
check_early_fail() {
  if [[ -f "$CALL_DIR/done" && -f "$CALL_DIR/error.txt" ]]; then
    cat "$CALL_DIR/error.txt" >&2
    exit 1
  fi
}

if $CMUX_MODE; then
  # Resolve the read-screen target: a surface (side-by-side/window) or a
  # workspace (detached). pane_ref (surface mode) lets us re-attach the PTY
  # if a read-screen ever races with PTY detachment.
  if $SURFACE_MODE; then
    REF=$(cat "$CALL_DIR/surface_ref.txt")
    READ_TARGET=(--surface "$REF")
    [[ -f "$CALL_DIR/pane_ref.txt" ]] && \
      cmux focus-pane --pane "$(cat "$CALL_DIR/pane_ref.txt")" >/dev/null 2>&1 || true
  else
    REF=$(cat "$CALL_DIR/workspace_ref.txt")
    READ_TARGET=(--workspace "$REF")
  fi
  WS_REF="$REF"
  if [[ ! -f "$CALL_DIR/session_id_preset.txt" ]]; then
    echo "CMUX call_dir missing session_id_preset.txt — launcher bug" >&2
    exit 1
  fi
  PRESET=$(cat "$CALL_DIR/session_id_preset.txt")
  ESC=$(printf '\x1b')

  # Signal B (transcript-file): claude writes
  # ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl the instant it opens
  # the session, so its existence is a strong REPL-liveness signal that
  # doesn't depend on terminal rendering (banner can scroll out of the read
  # window between polls, ANSI/--resume variance can defeat the regex).
  #
  # This depends on the preset being the id the callee ACTUALLY writes to. The
  # launcher guarantees that: fresh UUID on first contact, fresh UUID handed to
  # `--session-id` on a fork, resume target only on a plain resume. (When forks
  # presetted the resume target instead, this signal matched the ORIGINAL
  # session's long-existing transcript and fired instantly — a false
  # REPL-booted, and the wrong id to hand wait-for-response.sh.)
  # Encoding: Claude Code replaces EVERY non-alphanumeric char (path
  # separators, dots, AND spaces) with '-' when deriving the project-dir
  # name (verified against ~/.claude/projects/; e.g. '/Users/JT/.dotfiles' →
  # '-Users-JT--dotfiles', '/Users/JT/Documents/Southport UDO' →
  # '-Users-JT-Documents-Southport-UDO'). An earlier version only replaced
  # '/' and '.', so cwds containing spaces produced a path that never
  # existed. stat from a cmux-spawned bash child does NOT hit the cmux
  # socket, so the access_mode=cmuxOnly Broken-pipe constraint does not
  # apply here.
  TRANSCRIPT_PATH=""
  if [[ -f "$CALL_DIR/cwd.txt" ]]; then
    RECV_CWD=$(cat "$CALL_DIR/cwd.txt")
    ENCODED_CWD=$(printf '%s' "$RECV_CWD" | sed 's|[^a-zA-Z0-9]|-|g')
    TRANSCRIPT_PATH="${HOME}/.claude/projects/${ENCODED_CWD}/${PRESET}.jsonl"
  fi

  # FRESHNESS BASELINE for signal B. "The transcript file exists and is non-empty"
  # is only evidence of a boot when the file did not exist a moment ago — which is
  # true for a first contact under a brand-new session id, and FALSE for every
  # plain resume, where the file has been sitting there since the session was
  # created. Without this, a resume reported "REPL booted" on the first poll, in
  # the same millisecond the launch command was sent, and everything downstream
  # (including the paste) proceeded against a shell that had not exec'd claude yet.
  #
  # Recording the size rather than the mtime: growth is unambiguous, whereas a
  # comparison against "now" has to reason about clock skew and about a claude that
  # rewrites the file in place.
  TRANSCRIPT_BASE_SIZE=-1
  if [[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]]; then
    TRANSCRIPT_BASE_SIZE=$(wc -c < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ')
    [[ "$TRANSCRIPT_BASE_SIZE" =~ ^[0-9]+$ ]] || TRANSCRIPT_BASE_SIZE=-1
  fi

  SAW_BANNER=false
  SAW_TRANSCRIPT=false
  SAW_BOX=false
  ELAPSED=0
  while [[ ! -f "$CALL_DIR/session_id.txt" ]]; do
    check_early_fail
    if [[ $ELAPSED -ge $TIMEOUT ]]; then
      DIAG=""
      if [[ -n "$TRANSCRIPT_PATH" ]]; then
        if $SAW_TRANSCRIPT; then
          DIAG=" (transcript file appeared at ${TRANSCRIPT_PATH} but logic still failed — investigate)"
        else
          DIAG=" (no banner and no input box matched on screen AND no transcript file at ${TRANSCRIPT_PATH})"
        fi
      else
        DIAG=" (no banner and no input box matched on screen; transcript-file check skipped — cwd.txt absent)"
      fi
      echo "Timed out waiting for Claude REPL to boot in cmux ${REF} (${TIMEOUT}s).${DIAG} Common causes: the launch-script claude invocation is malformed (e.g. --allowedTools split into two argv words instead of --allowedTools=<list>), or the surface/workspace lost its tty." >&2
      exit 1
    fi

    # Signal A: banner on cmux read-screen. Signal C: the input box is drawn.
    SCREEN=$(cmux read-screen "${READ_TARGET[@]}" --scrollback --lines 9999 \
      2>/dev/null || true)
    if [[ -n "$SCREEN" ]]; then
      CLEAN=$(echo "$SCREEN" | sed "s/${ESC}\[[0-9;]*[mGKHFJKsu]//g; s/${ESC}(B//g; s/\r//g")
      if echo "$CLEAN" | grep -qE 'Claude Code v|Welcome back'; then
        SAW_BANNER=true
        echo "$PRESET" > "$CALL_DIR/session_id.txt"
        break
      fi
      # Only the TAIL: the box is drawn at the bottom of the live screen, while
      # this read is a 9999-line scrollback that may still hold `❯`-prefixed
      # echoes from a previous session in the same surface. Matching those would
      # report a REPL booted before it exists, and the paste that follows would
      # go into a bare shell.
      if repl_box_present "$(printf '%s\n' "$CLEAN" | tail -12)"; then
        SAW_BOX=true
        echo "$PRESET" > "$CALL_DIR/session_id.txt"
        break
      fi
    fi

    # Signal B: the transcript file is non-empty AND has grown since we started
    # (or did not exist then). See the baseline above for why growth is required.
    if [[ -n "$TRANSCRIPT_PATH" && -s "$TRANSCRIPT_PATH" ]]; then
      TR_NOW=$(wc -c < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ')
      if [[ "$TR_NOW" =~ ^[0-9]+$ && "$TR_NOW" -gt "$TRANSCRIPT_BASE_SIZE" ]]; then
        SAW_TRANSCRIPT=true
        echo "$PRESET" > "$CALL_DIR/session_id.txt"
        break
      fi
    fi

    sleep 1
    ELAPSED=$((ELAPSED + 1))
  done

  # Register the call in the sessions registry the moment the session ID is
  # known — script-level, so registration no longer depends on the dialing
  # agent remembering the SKILL.md cache step (routinely skipped on visible
  # side-by-side work orders). Silent no-op if launch metadata is absent.
  bash "$(dirname "${BASH_SOURCE[0]}")/register-call.sh" "$CALL_DIR"

  cat "$CALL_DIR/session_id.txt"
  exit 0
fi

# Headless mode — original behavior.
ELAPSED=0
while [[ ! -f "$CALL_DIR/session_id.txt" ]]; do
  check_early_fail
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    echo "Timed out waiting for session ID (${TIMEOUT}s)" >&2
    exit 1
  fi
  sleep 1
  ELAPSED=$((ELAPSED + 1))
done

# Script-level registration — see the cmux-mode comment above.
bash "$(dirname "${BASH_SOURCE[0]}")/register-call.sh" "$CALL_DIR"

cat "$CALL_DIR/session_id.txt"
